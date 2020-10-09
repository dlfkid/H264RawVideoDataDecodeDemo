//
//  ViewController.m
//  H264RawVideoDataDecodeDemo
//
//  Created by ravendeng on 2020/8/11.
//  Copyright © 2020 ravendeng. All rights reserved.
//

#import "ViewController.h"

#import "VideoToolsDecoder.h"

@interface ViewController () <VideoToolsDecoderDelegate>

@property (nonatomic, strong) VideoToolsDecoder *videoDecoder;
@property (nonatomic, strong) UIImageView *playerView;
@property (nonatomic, strong) UIButton *playButton;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    CGFloat buttonHeight = 44;
    CGFloat screenWidth = CGRectGetWidth(self.view.frame);
    CGFloat screenHeight = CGRectGetHeight(self.view.frame);
    
    // 初始化播放窗口
    _playerView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, screenHeight - buttonHeight)];
    self.playerView.backgroundColor = [UIColor blackColor];
    self.playerView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:self.playerView];
    // 初始化播放器
    VideoToolsDecoder *hardDecoder = [[VideoToolsDecoder alloc] init];
    _videoDecoder = hardDecoder; // 选择软解还是硬解
    _videoDecoder.delegate = self;
    // 按钮
    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    
    self.playButton.frame = CGRectMake(0, screenHeight - buttonHeight, screenWidth, buttonHeight);
    [self.playButton setTitle:@"PlayVideo" forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playSampleVideo:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.playButton];
}

- (void)playSampleVideo:(id)sender {
    NSData *videoData = [self sampleDataFromBundle];
    [self readVideoData2:videoData];
}

- (NSData *)sampleDataFromBundle {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *path = [mainBundle pathForResource:@"camer" ofType:@"h264"];
    NSError *permissionError = nil;
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:path error:&permissionError];
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data;
}

- (void)readVideoData2:(NSData *)data {
    static uint const kNALUPrefixLength = 4;
    static uint8_t const kBufferPrefix[4] = {0x00, 0x00, 0x00, 0x01};
  
    uint8_t *buffer = (uint8_t *)[data bytes];
    __block size_t bufferBegin = 0;
    __block size_t bufferEnd = data.length;
    __block int fn = 1;
    int fps = 60;
  
    NSUInteger (^calculateDataLength)(size_t) = ^NSUInteger(size_t begin) {
        for (NSUInteger i = begin; i < data.length; i++) {
            if (0 == memcmp(buffer + i, kBufferPrefix, kNALUPrefixLength)) {
                NSUInteger offset = MIN(i + kNALUPrefixLength, data.length);
                return offset - begin;
            }
        }
        return 0;
    };
  
    static dispatch_source_t _timer;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 1.0/fps * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(_timer, ^{
        if (bufferBegin != bufferEnd) {
            if (0 == memcmp(buffer + bufferBegin, kBufferPrefix, kNALUPrefixLength)) {
                size_t length = calculateDataLength(bufferBegin+kNALUPrefixLength);
                if (length == 0) {
                    NSLog(@"Done2!!");
                    dispatch_source_cancel(_timer);
                    return;
                }
                NSData *dd = [NSData dataWithBytes:&buffer[bufferBegin] length:length];
                const uint8_t *d = dd.bytes;
                printf("FrameInfo: %#hhx, length: %zu, index: %zu\n", d[4], length, bufferBegin);
                [self.videoDecoder decodeVideoFrameImageWithBuffer:(uint8_t *)[dd bytes] ReadSize:length];
                fn++;
                bufferBegin+=length;
                return;
            }
            ++bufferBegin;
        } else {
            NSLog(@"Done1!!");
            dispatch_source_cancel(_timer);
        }
    });
  
    dispatch_resume(_timer);
}

#pragma mark - VideoToolsDecoderDelegate

- (void)videoToolsDecoder:(VideoToolsDecoder *)decoder RenderedFrameImage:(UIImage *)frameImage {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.playerView.image = frameImage;
    });
}

@end
