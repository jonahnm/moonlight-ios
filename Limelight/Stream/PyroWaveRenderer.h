#import <UIKit/UIKit.h>
#include "Limelight.h"

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
