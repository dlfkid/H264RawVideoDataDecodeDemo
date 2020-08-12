//
//  H264NALUType.h
//  E1TutkDemo
//
//  Created by LeonDeng on 2020/3/11.
//  Copyright © 2020 HongHuLab. All rights reserved.
//

#ifndef H264NALUType_h
#define H264NALUType_h

typedef NS_ENUM(uint8_t, NALUType) {
  NALUTypeUndefined           = 0x00,
  
  /// P 帧
  NALUTypeCodedSlice          = 0x01,
  
  NALUTypeDataPartitionA      = 0x02,
  NALUTypeDataPartitionB      = 0x03,
  NALUTypeDataPartitionC      = 0x04,
  
  /// I 帧
  NALUTypeIDR                 = 0x05,
  
  NALUTypeSEI                 = 0x06,
  NALUTypeSPS                 = 0x07, // 储存码流格式数据
  NALUTypePPS                 = 0x08,
  NALUTypeAccessUnitDelimiter = 0x09,
  NALUTypeEndOfSequence       = 0x0A,
  NALUTypeEndOfStream         = 0x0B,
  NALUTypeFilterData          = 0x0C
  // 13-23 [extended]
  // 24-31 [unspecified]
};

typedef NSUInteger (^DataLengthCalculationBlock)(size_t);

static uint const kNALUPrefixLength = 4;
static uint8_t const kBufferPrefix[4] = {0x00, 0x00, 0x00, 0x01};
static uint8_t const kNALURestoreBuffer = 0x1F;

#endif /* H264NALUType_h */
