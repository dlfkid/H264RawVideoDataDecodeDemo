//
//  StreamDecoder.m
//  E1TutkDemo
//
//  Created by LeonDeng on 2020/3/2.
//  Copyright © 2020 HongHuLab. All rights reserved.
//

#import "VideoToolsDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import "StreamFilmer.h"

@interface VideoToolsDecoder()

{
    CGSize _bufferSize;
    NSData *_spsData;
    NSData *_ppsData;
    NSData *_idrData;
    NSData *_seiData;
    VTDecompressionSessionRef _decompressionSession;
    CMVideoFormatDescriptionRef _formatDescription; // 视频格式描述结构体，每个新来的帧被解码后会将信息储存在这里
}

@property (nonatomic, strong) NSMutableData *frameData;

@end

static void decompressionOutputCallback(void * CM_NULLABLE decompressionOutputRefCon,
                                        void * CM_NULLABLE sourceFrameRefCon,
                                        OSStatus status,
                                        VTDecodeInfoFlags infoFlags,
                                        CM_NULLABLE CVImageBufferRef imageBuffer,
                                        CMTime presentationTimeStamp,
                                        CMTime presentationDuration) {
    if (noErr != status) {
        NSLog(@"SampleBuffer解码失败: %d", (int)status);
        return;
    }
    
    // 需要查找某一帧的数据的时候使用下面的代码
//    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
//    uint8_t *buffer = CVPixelBufferGetBaseAddress(imageBuffer);
//    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
//    size_t size = CVPixelBufferGetHeight(imageBuffer) * bytesPerRow;
//    NSData *data = [NSData dataWithBytes:buffer length:size];
//    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    [[StreamFilmer sharedFilmer] gatherVideoBuffer:imageBuffer];
    
    VideoToolsDecoder *videoDecoder = (__bridge VideoToolsDecoder *)(decompressionOutputRefCon);
  
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    UIImage *image = [UIImage imageWithCIImage:ciImage];
    
    if ([videoDecoder.delegate respondsToSelector:@selector(videoToolsDecoder:RenderedFrameImage:)]) {
        [videoDecoder.delegate videoToolsDecoder:videoDecoder RenderedFrameImage:image];
    }
}

@implementation VideoToolsDecoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameData = [[NSMutableData alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self freeDecompressionSession];
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
}

#pragma mark - Public

- (BOOL)decodeVideoFrameImageWithBuffer:(uint8_t *)imageBuffer ReadSize:(NSUInteger)readSize {
    
    if (![self isImageBufferValid:imageBuffer size:readSize]) {
        return NO;
    }
    
    if ([self isAppResignActive]) {
        // APP 处于非激活状态，不做渲染节省性能
        [self freeDecompressionSession];
        return NO;
    }
    
    /// 获取这包数据的第一个 NALU 类型.
    uint8_t bufferPrefix = imageBuffer[kNALUPrefixLength];
    NALUType naluType = bufferPrefix & kNALURestoreBuffer;
    
    // 判断是否是可以添加到码流中的数据
    if (naluType == NALUTypeSPS || naluType == NALUTypeSEI || naluType == NALUTypePPS || naluType == NALUTypeIDR) {
        [self.frameData appendBytes:imageBuffer length:readSize];
    }
    
    //判断SPS时是否带了IDR
    if (naluType == NALUTypeSPS) {
        @autoreleasepool {
            NSData *tempData = [NSData dataWithBytes:imageBuffer length:readSize];
            NSRange range = [tempData rangeOfData:[NSData dataWithBytes:kBufferPrefix length:kNALUPrefixLength] options:NSDataSearchBackwards range:NSMakeRange(0, tempData.length)];
            if (range.location != NSNotFound) {
                tempData = [tempData subdataWithRange:NSMakeRange(range.location + range.length, 1)];
                uint8_t *tempBufferPrefix = (uint8_t *)[tempData bytes];
                NALUType tempNaluType = tempBufferPrefix[0] & kNALURestoreBuffer;
                //从后查询如果包含idr则认为是一个完整包
                if (tempNaluType == NALUTypeIDR) {
                    naluType = NALUTypeIDR;
                }
            }
        }
    }
    return [self initalizeSmapleBufferAndDecompressionSessionWithNALUType:naluType buffer:imageBuffer size:readSize];
}

#pragma mark - Private

- (BOOL)initalizeSmapleBufferAndDecompressionSessionWithNALUType:(NALUType)type buffer:(uint8_t *)buffer size:(NSUInteger)size {
    if (type == NALUTypeIDR || type == NALUTypeCodedSlice) {
        // 生成SampleBuffer
        CMSampleBufferRef sampleBuffer = NULL;
        if (type == NALUTypeIDR) {
            // 是纯视频数据, 沿用之前的格式描述
            NSUInteger nalLen = [self.frameData length];
            sampleBuffer = [self sampleH264BufferWithBuffer:(uint8_t *)[self.frameData bytes] Length:nalLen NALUType:NALUTypeSPS];
        } else {
            // 是新的关键帧
            sampleBuffer = [self sampleH264BufferWithBuffer:buffer Length:size NALUType:type];
        }
        if (NULL == sampleBuffer) {
            // 生成SampleBuffer失败
            return NO;
        }
        
        if (!_decompressionSession && ![self initializeDecompressionSession]) {
            // 生成解压Session失败
            CFRelease(sampleBuffer);
            return NO;
        }
        
        // 将SampleBuffer扔到解压Session中执行解压
        OSStatus status = VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, 0, NULL, NULL);
        if (noErr != status) {
            // 帧解码失败
            return NO;
        }
        
        // 别忘记释放sampleBuffer,它是结构体的指针，不会ARC
        CFRelease(sampleBuffer);
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)isImageBufferValid:(uint8_t *)buffer size:(NSUInteger)size {
    if (!buffer || size == 0) {
      // 视频流数据为空
      return NO;
    }
    
    /// H264规定每一帧的前4位必须以 00 00 00 01 开头,  在这里比较数据流的前四位是不是00 00 00 01，如果不是就废弃此帧
    if (memcmp(buffer, kBufferPrefix, kNALUPrefixLength) != 0) {
        // NSData *dataOC = [NSData dataWithBytes:buffer length:size];
        // NSLog(@"数据流前缀不符合H264要求, dataOC:\n%@", dataOC);
      return NO;
    }
    
    return YES;
}

- (BOOL)isAppResignActive {
    __block BOOL isAppResignActive = NO;
    
    if ([NSThread currentThread].isMainThread) {
        isAppResignActive = UIApplicationStateActive != [UIApplication sharedApplication].applicationState;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            isAppResignActive = UIApplicationStateActive != [UIApplication sharedApplication].applicationState;
        });
    }
    
    return isAppResignActive;
}

/// 将传过来的数据流格式化成可以被CoreMedia识别的数据
/// @param buffer 原始数据
/// @param length 长度
/// @param naluType 帧类型
- (nullable CMSampleBufferRef)sampleH264BufferWithBuffer:(uint8_t *)buffer Length:(NSUInteger)length NALUType:(NALUType)naluType {
    /// 对于 H.264 的基本知识, 请看 http://stackoverflow.com/a/24890903/1644934
    
    /// 固件传输过来的视频数据包只有两种:
    /// 1. 信息包(I 帧). 同时包含 SPS、PPS、IDR 三个 NALU.
    /// 2. 数据包(P 帧). 只包含 CodedSlice(0x01) 一个 NALU.
    /// 通常是先发过来一个信息包, 然后接着若干数据包, 以此循环.
    
    /// iOS 中视频数据使用 `CMSampleBufferRef` 表示, 创建它需要两个必要参数:
    /// 1. 视频格式信息, 使用 `CMVideo_formatDescriptionRef` 表示.
    /// 2. 视频内容, 使用 `CMBlockBufferRef` 表示.

    /// 我们的处理步骤如下:
    /// 1. 提取 SPS 和 PPS, 检测是否需要重新创建 `CMVideoFormatDescriptionRef` 对象.
    /// 2. 分离出 IDR 数据创建 `CMBlockBuffer` 对象.
    /// 3. 对数据转换格式. 固件传过来的是 Annex B 格式, 而 iOS 要求 AVCC 格式. 替换掉 Header 即可.
    /// 4. 使用这两个对象创建 `CMSampleBufferRef` 对象.
    /// 5. 解码回调 `CVImageBufferRef` 对象.
    OSStatus status = noErr;
    /// 如果第一个 NALU 是 SPS 类型, 我们需要找出后面跟着的 PPS 和 IDR.
    if (naluType == NALUTypeSPS) { // 取到了I帧开头的NALU类型
        for (NSUInteger i = 0; i < length; i++) {
            if (memcmp(buffer + i, kBufferPrefix, kNALUPrefixLength) == 0) {
                size_t offset = MIN(i+kNALUPrefixLength, length - 1);
                NALUType nalu = buffer[offset] & kNALURestoreBuffer;
                switch (nalu) {
                    case NALUTypeCodedSlice:/// 如果是 P 帧, 那么整个包都是 P 帧数据.
                        _idrData = [NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:NO];
                        break;
                    case NALUTypeSPS: {
                        NSUInteger tempLength = [self calculateDataLength:offset length:length buffer:buffer];
                        _spsData = [NSData dataWithBytes:&buffer[offset] length:tempLength];
                  }
                        break;
                    case NALUTypePPS: {
                        NSUInteger tempLength = [self calculateDataLength:offset length:length buffer:buffer];
                        _ppsData = [NSData dataWithBytes:&buffer[offset] length:tempLength];
                  }
                        break;
                    case NALUTypeSEI: {
                        NSUInteger tempLength = [self calculateDataLength:offset length:length buffer:buffer];
                        _seiData = [NSData dataWithBytes:&buffer[offset] length:tempLength];
                  }
                        break;
                    case NALUTypeIDR:
                        _idrData = [NSData dataWithBytesNoCopy:&buffer[offset - kNALUPrefixLength] length:length - offset + kNALUPrefixLength freeWhenDone:NO];
                        break;
                  
                    default:
                        NSAssert(NO, @"未识别的Nalu类型: %hhud", nalu);
                        break;
                  }
            }
        }
        
        /// 如果我们没有得到格式数据, 输出视频数据方便 Debug.
        if (!_spsData || !_ppsData) {
            NSMutableString *string  = [NSMutableString string];
            for (NSUInteger i = 0; i < 30; i++) {
                [string appendFormat:@"%02X", buffer[i]];
            }
            NSLog(@"I帧数据不全 spsData is %@, ppsData is %@, header is %@", _spsData, _ppsData, string);
            return NULL;
        }
        
        /// 检查格式是否有变化(例如码流等参数变了), 如果有变化需要重新创建 `VTDecompressionSessionRef`.
        
        NSUInteger naluChanges = 0; // 检查SPS和PPS是否变化
        
        NSUInteger const parameterCount = 2;
        
        const uint8_t * const parameterSetPointers[parameterCount] = {[_spsData bytes], [_ppsData bytes]};
        const size_t parameterSetSizes[parameterCount] = {_spsData.length, _ppsData.length};
        
        for (int i = 0; _formatDescription && i < parameterCount; i++) {
            size_t oldLength = 0;
            const uint8_t *oldData = NULL;
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(_formatDescription, i, &oldData, &oldLength, NULL, NULL);
            
            if (status != noErr) {
                _formatDescription = NULL;
                NSLog(@"无法获取视频格式描述: %d", (int)status);
                return NULL;
            }
            
            if (memcmp(parameterSetPointers[i], oldData, oldLength) !=0 || oldLength != parameterSetSizes[i]) {
                naluChanges ++;
            }
        }
        
        BOOL isVideoFormatChanged = naluChanges == parameterCount;
        
        if (_decompressionSession) { // 如果已有解压Session，只需要按照现有Session进行解码
            size_t oldSPSLength;
            const uint8_t *oldSPSData = NULL;
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(_formatDescription, 0, &oldSPSData, &oldSPSLength, NULL, NULL); // 将刚才得到的SPS信息生成格式描述
            if (status != noErr) {
                _formatDescription = NULL;
                NSLog(@"无法获取视频SPS格式描述: %d", (int)status);
                return NULL;
            }
            // 和上一帧的SPS进行对比，检查码流格式是否变化
            isVideoFormatChanged = ((0 != memcmp([_spsData bytes], oldSPSData, oldSPSLength)) || oldSPSLength != _spsData.length);

            if (!isVideoFormatChanged) { // 码流格式没变，读取PPS格式描述
                size_t oldPPSLength;
                const uint8_t *oldPPSData = NULL;
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(_formatDescription, 1, &oldPPSData, &oldPPSLength, NULL, NULL);

                if (noErr != status) {
                    _formatDescription = NULL;
                    NSLog(@"无法获取视频PPS格式描述: %d", (int)status);
                    return NULL;
              }

              isVideoFormatChanged = ((0 != memcmp([_ppsData bytes], oldPPSData, oldPPSLength)) || oldPPSLength != _ppsData.length);
            } else {
                NSLog(@"视频码流格式发生变化");
            }
        }
        if (!_decompressionSession || isVideoFormatChanged) { // 没有解压Session或视频码流格式已经变化
            NSLog(@"生成新的格式描述");
            // 生成用于H264的格式描述
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, parameterCount, parameterSetPointers, parameterSetSizes, kNALUPrefixLength, &_formatDescription);
            if (status != noErr) {
                NSLog(@"生成视频码流格式描述失败: %d", (int)status);
                _formatDescription = NULL;
                return NULL;
            }
            [self freeDecompressionSession]; // 释放解压Session
            if (![self initializeDecompressionSession]) { // 尝试根据视频解码格式生成新的解码Session
                return NULL;
            };
        }
    } else if (naluType == NALUTypeCodedSlice) { // 截取到的是P帧, 可以直接使用
        _idrData = [NSData dataWithBytes:buffer length:length];
    }
    
    void *blockData = (void *)[_idrData bytes];
    size_t blockDataLength = (size_t)_idrData.length;
    CMBlockBufferRef blockBuffer = NULL;
    // 将视频数据封装进解码所需的数据块中
    status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, blockData, blockDataLength, kCFAllocatorNull, NULL, 0, blockDataLength, 0, &blockBuffer);
    if (kCMBlockBufferNoErr != status) {
        NSLog(@"无法创建解码数据块: %d", (int)status);
        CFRelease(blockBuffer);
        blockBuffer = NULL;
        return NULL;
    }
    /// 转换 Header 为 Length.
    size_t removeHeaderSize = blockDataLength - kNALUPrefixLength;
    const uint8_t lengthBytes[kNALUPrefixLength] = {(uint8_t)(removeHeaderSize >> 24),
                                                    (uint8_t)(removeHeaderSize >> 16),
                                                    (uint8_t)(removeHeaderSize >> 8),
                                                    (uint8_t) removeHeaderSize};
    // 清空头部内容
    status = CMBlockBufferReplaceDataBytes(lengthBytes, blockBuffer, 0, kNALUPrefixLength);
    if (kCMBlockBufferNoErr != status) {
        NSLog(@"清空数据块头部失败，释放数据块: %d", (int)status);
        CFRelease(blockBuffer);
        return NULL;
    }
    const size_t sampleSizeArray[] = {length};
    CMSampleBufferRef sampleBuffer = NULL;
    
    // 生成一个CMSampleBuffer
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, _formatDescription, 1, 0, NULL, 1, sampleSizeArray, &sampleBuffer);
    if (noErr != status) {
        NSLog(@"CMSampleBuffer生成失败: %d", (int)status);
        CFRelease(blockBuffer);
        return NULL;
    }
    
    CFRelease(blockBuffer);
    
    /// 调用者需要负责释放返回的对象.
    return sampleBuffer;
}

- (BOOL)initializeDecompressionSession { // 初始化解压Session
    if (_decompressionSession) {
      NSLog(@"已有解压Session了");
      return YES;
    }
    VTDecompressionOutputCallbackRecord outPutCallBack; // 声明解码后输出图像时的回调结构体
    outPutCallBack.decompressionOutputCallback = decompressionOutputCallback; // 定义一帧图片解码完成后的回调函数
    outPutCallBack.decompressionOutputRefCon = (__bridge void * _Nullable)(self); // 定义回调函数中携带的对象,此处指解码器本身
    
    NSMutableDictionary *destinationPixelBufferAttributes = [NSMutableDictionary dictionary]; // 生成解码需要的参数
    
    /// 硬解必须使用 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange 或者 kCVPixelFormatType_420YpCbCr8Planar.
    /// 因为 iOS 是  nv12  其他是 nv21.
    destinationPixelBufferAttributes[(NSString *)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange); // 我也不知道这是啥，照抄的
    destinationPixelBufferAttributes[(NSString *)kCVPixelFormatOpenGLCompatibility] = @YES; // 兼容OpenGL
    
    if (_bufferSize.width > 0 && _bufferSize.height > 0) { // 如果定义过图像宽高，则也将之作为特征传入
        destinationPixelBufferAttributes[(NSString *)kCVPixelBufferWidthKey] = @(_bufferSize.width);
        destinationPixelBufferAttributes[(NSString *)kCVPixelBufferHeightKey] = @(_bufferSize.height);
    }
    
    // 生成解码Session, 需要的参数是内存分配方式, 格式描述，解码细节，目标像素解码参数，输出回调，Session指针
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, _formatDescription, NULL, (__bridge CFDictionaryRef _Nullable)(destinationPixelBufferAttributes), &outPutCallBack, &_decompressionSession);
    
    if (noErr != status) {
        _decompressionSession = NULL;
        NSLog(@"生成视频流解码Session失败: %d", (int)status);
        return NO;
    }
    
    NSLog(@"生成视频解码流成功");
    
    return YES;
}

- (void)freeDecompressionSession {
    if (NULL != _decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
}

- (NSUInteger)calculateDataLength:(size_t)begin length:(NSUInteger)length buffer:(uint8_t *)buffer {
    for (NSUInteger i = begin; i < length; i++) {
        if (1 == memcmp(buffer + i, kBufferPrefix, kNALUPrefixLength)) {
            NSUInteger offset = MIN(i + kNALUPrefixLength, length - 1);
            return offset - begin;
        }
    }
    return length - begin;
}



@end
