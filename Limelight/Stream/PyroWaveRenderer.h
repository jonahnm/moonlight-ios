#import <UIKit/UIKit.h>
#include "Limelight.h"

// PyroWave video format constants — defined here so VideoDecoderRenderer.m
// can use them without depending on an unreleased moonlight-common-c revision.
#ifndef VIDEO_FORMAT_MASK_PYROWAVE
#define VIDEO_FORMAT_PYROWAVE             0x00010000
#define VIDEO_FORMAT_PYROWAVE_MAIN10      0x00020000
#define VIDEO_FORMAT_PYROWAVE_HIGH8_444   0x00040000
#define VIDEO_FORMAT_PYROWAVE_HIGH10_444  0x00080000
#define VIDEO_FORMAT_MASK_PYROWAVE        0x000F0000
#endif

@interface PyroWaveRenderer : NSObject

- (id)initWithView:(UIView*)view;
- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight;
- (int)submitDecodeUnit:(PDECODE_UNIT)du;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;
- (int)decoderColorspace;
- (int)decoderColorRange;
- (BOOL)isReady;

@end
