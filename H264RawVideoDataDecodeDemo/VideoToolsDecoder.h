//
//  StreamDecoder.h
//  E1TutkDemo
//
//  Created by LeonDeng on 2020/3/2.
//  Copyright © 2020 HongHuLab. All rights reserved.
//

@class VideoToolsDecoder;

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "H264NALUType.h"

NS_ASSUME_NONNULL_BEGIN

@protocol VideoToolsDecoderDelegate<NSObject>
@required
- (void)videoToolsDecoder:(VideoToolsDecoder *)decoder RenderedFrameImage:(UIImage *)frameImage;

@end

@interface VideoToolsDecoder : NSObject

@property (nonatomic, weak) id <VideoToolsDecoderDelegate> delegate;

- (BOOL)decodeVideoFrameImageWithBuffer:(uint8_t *)imageBuffer ReadSize:(NSUInteger)readSize;

@end

NS_ASSUME_NONNULL_END
