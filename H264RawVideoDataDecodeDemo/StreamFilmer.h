//
//  VideoRecorder.h
//  E1TutkDemo
//
//  Created by LeonDeng on 2020/3/16.
//  Copyright © 2020 HongHuLab. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CMSampleBuffer.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^StreamFilmedCallback)(NSError * _Nullable error);

extern NSString * const kStreamFilmerErrorDomain;

typedef NS_ENUM(NSInteger, StreamFilmerError) {
  StreamFilmerErrorSavedPathInvalid = -99,
  StreamFilmerErrorUnableAddVideoInput  = -98,
  StreamFilmerErrorUnableAddAudioInput  = -97,
  StreamFilmerErrorUnableToWrite   = -96,
};

@interface StreamFilmer : NSObject

/// 暂时先做单例
+ (instancetype)sharedFilmer;

/// 标记音频停止，当采集不到音频的时候需要插入静音帧到视频中，否则视频无法播放
- (void)markAudioStopped;

/// 开始录制视频
/// @param videoPath 视频目录
/// @param completion 结果回调
- (void)startWithPath:(NSString *)videoPath completion:(nullable StreamFilmedCallback)completion;

/// 终止录制视频
- (void)stop;


/// 采集视频帧
/// @param videoBuffer 视频帧
- (BOOL)gatherVideoBuffer:(CVImageBufferRef)videoBuffer;


/// 采集音频帧
/// @param audioBuffer 音频帧
/// @param length 数据大小
- (BOOL)gatherAudioBuffer:(uint8_t *)audioBuffer Length:(uint)length;

@end

NS_ASSUME_NONNULL_END
