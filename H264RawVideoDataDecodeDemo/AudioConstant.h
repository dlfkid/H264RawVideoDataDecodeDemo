//
//  AudioConstant.h
//  E1TutkDemo
//
//  Created by LeonDeng on 2020/3/16.
//  Copyright © 2020 HongHuLab. All rights reserved.
//

#ifndef AudioConstant_h
#define AudioConstant_h

#import <CoreAudio/CoreAudioTypes.h>

static AudioStreamBasicDescription const audioFormat8k = (AudioStreamBasicDescription) {
  .mSampleRate       = 8000,
  .mFormatID         = kAudioFormatLinearPCM,
  .mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
  .mBytesPerPacket   = 2,
  .mFramesPerPacket  = 1,
  .mBytesPerFrame    = 2,
  .mChannelsPerFrame = 1,
  .mBitsPerChannel   = 16,
};

static AudioStreamBasicDescription const audioFormat16k = (AudioStreamBasicDescription) {
  .mSampleRate       = 16000,
  .mFormatID         = kAudioFormatLinearPCM,
  .mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
  .mBytesPerPacket   = 2,
  .mFramesPerPacket  = 1,
  .mBytesPerFrame    = 2,
  .mChannelsPerFrame = 1,
  .mBitsPerChannel   = 16,
};


static UInt32 const IBLAudioDefaultBufferSize = 1280;

#endif /* AudioConstant_h */
