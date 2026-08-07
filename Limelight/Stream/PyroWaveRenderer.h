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
// Starts the decode/present pull loop on a background thread. All frame
// submission, copying, decoding and completion happens off the main thread so
// the main thread is always free to deliver controller input immediately.
- (void)start;
- (void)stop;
// Invoked (on the render thread) when an IDR frame is successfully shown, so
// the loading indicator can be hidden.
@property (nonatomic, copy) void (^videoContentShownHandler)(void);
- (void)setHdrMode:(BOOL)enabled;
- (int)decoderColorspace;
- (int)decoderColorRange;
- (BOOL)isReady;

@end
