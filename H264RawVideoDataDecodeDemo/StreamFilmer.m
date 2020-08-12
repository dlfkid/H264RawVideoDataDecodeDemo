//
//  VideoRecorder.m
//  E1TutkDemo
//
//  Created by LeonDeng on 2020/3/16.
//  Copyright © 2020 HongHuLab. All rights reserved.
//

#import "StreamFilmer.h"

#import <AVFoundation/AVFoundation.h>

#import "AudioConstant.h"

@interface StreamFilmer()

@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *videoInputAdaptor;
@property (nonatomic, strong) NSLock *streamFilmerLock;
@property (nonatomic, assign) CMTime currentTime;
@property (nonatomic, assign) CMAudioFormatDescriptionRef audioFormatDescription;
@property (nonatomic, assign) BOOL recording;
@property (nonatomic, assign) BOOL audioStopped;
@property (nonatomic, copy) StreamFilmedCallback filmedCompletion;

@end

NSString * const kStreamFilmerErrorDomain = @"com.tutk.streamFilmer.errorDomain";

static CGSize const kDefaultVideoSize = {1280, 720};

@implementation StreamFilmer

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentTime = kCMTimeZero;
    }
    return self;
}

+ (instancetype)sharedFilmer {
    static dispatch_once_t onceToken;
    static StreamFilmer *_sharedFilmer = nil;
    dispatch_once(&onceToken, ^{
        _sharedFilmer = [[StreamFilmer alloc] init];
    });
    return _sharedFilmer;
}

#pragma mark - Public

- (BOOL)reconfigureAssetWriterWithURL:(NSURL *)url error:(NSError **)error {
    [self.streamFilmerLock lock];
    // 重新构成AssetWriter
    self.assetWriter = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:error];
    /// 我们目前的帧率是 15
    /// 设置此属性防止写入不全导致无法播放.
    self.assetWriter.movieFragmentInterval = CMTimeMake(1, 20);
    if (!self.assetWriter) { // 如果无法实例化新的AssetWrite将返回错误
        [self.streamFilmerLock unlock];
        return NO;
    }
    
    // 配置输出的视频参数
    NSDictionary *videoOutputSettings = @{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(kDefaultVideoSize.width), AVVideoHeightKey: @(kDefaultVideoSize.height)};
    // 设置视频输入源
    self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoOutputSettings];
    self.videoInput.expectsMediaDataInRealTime = YES;
    // 设置像素源参数
    NSDictionary *sourcePixelBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB), (NSString *)kCVPixelBufferWidthKey: videoOutputSettings[AVVideoWidthKey], (NSString *)kCVPixelBufferHeightKey: videoOutputSettings[AVVideoHeightKey]};
    // 实例化视频适配器，用于将输入源的数据转换成视频
    self.videoInputAdaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:self.videoInput sourcePixelBufferAttributes:sourcePixelBufferAttributes];
    
    if (![self.assetWriter canAddInput:self.videoInput]) { // 如果写入器添加视频输入源失败
        *error = [NSError errorWithDomain:kStreamFilmerErrorDomain
                                     code:StreamFilmerErrorUnableAddVideoInput
                                 userInfo:@{NSLocalizedDescriptionKey: @"无法添加视频输入源"}];
        [self.streamFilmerLock unlock];
        return NO;
    }
    
    [self.assetWriter addInput:self.videoInput];
    
    /// 因为我们目前是单声道的, 如果未来更改了. 这里也需要更改.
    AudioChannelLayout currentChannelLayout;
    bzero(&currentChannelLayout, sizeof(currentChannelLayout));
    currentChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    
    AudioStreamBasicDescription asbd = audioFormat8k;
    
    // 设置音频输出参数
    NSDictionary *audioOutputSettings = @{AVFormatIDKey: @(kAudioFormatLinearPCM),
    AVSampleRateKey: @(asbd.mSampleRate),
    AVNumberOfChannelsKey: @(asbd.mChannelsPerFrame),
    AVChannelLayoutKey: [NSData dataWithBytes:&currentChannelLayout length: sizeof(currentChannelLayout)],
    AVLinearPCMBitDepthKey: @16,
    AVLinearPCMIsBigEndianKey: @NO,
    AVLinearPCMIsFloatKey: @NO,
    AVLinearPCMIsNonInterleaved: @NO
    };
    // 实例化音频输入源
    self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioOutputSettings];
    self.audioInput.expectsMediaDataInRealTime = YES;
    
    if (![self.assetWriter canAddInput:self.audioInput]) {
        *error = [NSError errorWithDomain:kStreamFilmerErrorDomain
                                     code:StreamFilmerErrorUnableAddAudioInput
                                 userInfo:@{NSLocalizedDescriptionKey: @"无法添加音频输入源"}];
        [self.streamFilmerLock unlock];
        return NO;
    }
    [self.assetWriter addInput:self.audioInput];
    [self.streamFilmerLock unlock];
    return YES;
}

- (void)markAudioStopped {
    self.audioStopped = YES;
}

- (BOOL)gatherAudioBuffer:(uint8_t *)audioBuffer Length:(uint)length Silent:(BOOL)isSilent {
    if (!self.assetWriter) {
        return NO;
    }
    if (!isSilent && (audioBuffer == NULL || length == 0)) {
        return NO;
    }
    
    if (self.assetWriter.status == AVAssetWriterStatusWriting  && self.audioInput.isReadyForMoreMediaData) {
        CMBlockBufferRef blockBuffer = NULL;
        CMSampleBufferRef sampleBuffer = NULL;
        size_t audioBufferLength = isSilent ? IBLAudioDefaultBufferSize : (size_t)length;
        OSStatus status = noErr;
        if (!self.audioFormatDescription) {
            AudioStreamBasicDescription asbd = audioFormat8k;
            status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &_audioFormatDescription);
            if (noErr != status) {
                NSLog(@"实例化音频描述文件失败");
                return NO;
            }
        }
        
        status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, audioBufferLength, kCFAllocatorDefault, NULL, 0, audioBufferLength, 0, &blockBuffer);
        
        if (status != kCMBlockBufferNoErr) {
            NSLog(@"实例化音频数据块失败");
            return NO;
        }

        if (isSilent) { // 这里要根据是否静音判断是将采集到的音频帧数据传入视频还是填入静音帧
            status = CMBlockBufferFillDataBytes(0, blockBuffer, 0, audioBufferLength);
            if (kCMBlockBufferNoErr != status) {
                NSLog(@"无法填充静音数据块");
                return NO;
            }
        } else {
            status = CMBlockBufferReplaceDataBytes(audioBuffer, blockBuffer, 0, audioBufferLength);
            if (kCMBlockBufferNoErr != status) {
              NSLog(@"无法将采集到的音频数据拷贝到音频数据块中");
              return NO;
            }
        }
        
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, blockBuffer, self.audioFormatDescription, audioBufferLength / 2, self.currentTime, NULL, &sampleBuffer);
        
        if (noErr != status) {
            NSLog(@"无法生成视频数据块");
            return NO;
        }
        
        BOOL result = [self.audioInput appendSampleBuffer:sampleBuffer];
        
        if (!result) {
            NSLog(@"无法将采集到的音频拼接到视频中");
        }
        
        CFRelease(blockBuffer);
        CFRelease(sampleBuffer);
        
        return result;
    }
    return NO;
}

#pragma mark - Public

- (BOOL)gatherVideoBuffer:(CVImageBufferRef)videoBuffer {
    if (NULL == videoBuffer || !self.assetWriter) {
        return NO;
    }
    
    if (AVAssetWriterStatusWriting == self.assetWriter.status && self.videoInputAdaptor.assetWriterInput.isReadyForMoreMediaData) {
        if (![self.videoInputAdaptor appendPixelBuffer:videoBuffer withPresentationTime:self.currentTime]) {
            NSLog(@"无法拼接视频数据到视频中");
            return NO;
        }
        
        /// 如果声音停止了, 插入静音.
        if (self.audioStopped) {
            [self gatherAudioBuffer:NULL Length:0 Silent:YES];
        }
        
        self.currentTime = CMTimeAdd(self.currentTime, self.assetWriter.movieFragmentInterval);
        return YES;
    }
    
    return NO;
}

- (BOOL)gatherAudioBuffer:(uint8_t *)audioBuffer Length:(uint)length {
    return [self gatherAudioBuffer:audioBuffer Length:length Silent:NO];
}

- (void)startWithPath:(NSString *)videoPath completion:(StreamFilmedCallback)completion {
    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
    if (!videoURL) {
        NSError *pathError = [NSError errorWithDomain:kStreamFilmerErrorDomain code:StreamFilmerErrorSavedPathInvalid userInfo:@{NSLocalizedDescriptionKey: @"无效的视频保存目录"}];
        !completion ?: completion(pathError);
    }
    if (self.recording) {
        [self stop];
    }
    NSError *error = nil;
    if (![self reconfigureAssetWriterWithURL:videoURL error:&error]) {
        !completion ?: completion(error);
        return;
    }
    if (![self.assetWriter startWriting]) {
        error = [NSError errorWithDomain:kStreamFilmerErrorDomain
            code:StreamFilmerErrorUnableToWrite
        userInfo:@{NSLocalizedDescriptionKey: @"视频流无法开始写入"}];
        !completion ?: completion(error);
        return;
    }
    self.filmedCompletion = completion;
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    self.recording = YES;
    NSLog(@"Start video recording at path: %@", videoPath);
}

- (void)stop {
    if (!self.recording) {
        return;
    }
    [self.videoInput markAsFinished];
    [self.audioInput markAsFinished];
    [self.assetWriter finishWritingWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (self.assetWriter.status) {
                case AVAssetWriterStatusCancelled:
                case AVAssetWriterStatusFailed:{
                    NSLog(@"无法录制视频: %@", self.assetWriter.error);
                    [[NSFileManager defaultManager] removeItemAtURL:self.assetWriter.outputURL error:nil];
                    !self.filmedCompletion ?: self.filmedCompletion(self.assetWriter.error);
                    self.filmedCompletion = nil;
                }
                    break;
                
                case AVAssetWriterStatusCompleted: {
                    !self.filmedCompletion ?: self.filmedCompletion(nil);
                    self.filmedCompletion = nil;
                }
                    break;
                    
                default:
                    NSLog(@"录制视频未知错误: %@", @(self.assetWriter.status));
                    break;
            }
        });
        self.currentTime = kCMTimeZero;
        self.recording = NO;
    }];
}

#pragma mark - LazyLoads

- (NSLock *)streamFilmerLock {
    if (!_streamFilmerLock) {
        _streamFilmerLock = [[NSLock alloc] init];
    }
    return _streamFilmerLock;
}

@end
