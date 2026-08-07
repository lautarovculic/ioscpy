// Hardware H.264/HEVC encoder built on VideoToolbox. Lives in the tweak next to the
// capture path so the screen pixels never leave SpringBoard uncompressed.
//
// Everything here is public VideoToolbox/CoreMedia/CoreVideo, so it works on any
// iPhone with a hardware H.264 encoder (every model we target). If a session
// can't be created on a given device/OS, encoding reports failure and the caller
// drops back to the JPEG path. Nothing is assumed about availability.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Whether the VideoToolbox encode path is plausibly present. The real test is
// creating a session, which the encoder reports per-frame.
BOOL IOSPYHardwareVideoAvailable(uint8_t codec);

#ifdef __cplusplus
}
#endif

typedef void (^IOSPYVideoCompletion)(NSData *data, BOOL keyframe, BOOL hardError);

@interface IOSPYVideoEncoder : NSObject

// Encode a BGRA IOSurface to H.264. The session is created lazily and recreated
// when the frame size or rate changes. Output is AVCC (4-byte length-prefixed
// NAL units); on a keyframe the SPS/PPS parameter sets are prepended (also AVCC
// framed) so the host can build its decoder from the stream alone.
//
// The frame is submitted without waiting for the hardware encoder. Returns NO
// only when submission/session creation failed synchronously. `completion` runs
// later with encoded AVCC bytes, an empty buffer for an encoder drop, or
// `hardError=YES` when the session should be rebuilt/fallen back.
- (BOOL)submitSurface:(IOSurfaceRef)surface
                 width:(int)width
                height:(int)height
                   fps:(int)fps
                 codec:(uint8_t)codec
               bitrate:(uint32_t)bitrate
      keyframeInterval:(int)keyframeInterval
         forceKeyframe:(BOOL)forceKeyframe
            completion:(IOSPYVideoCompletion)completion;

// Tear down the underlying session (e.g. when the stream stops).
- (void)invalidate;

@end
