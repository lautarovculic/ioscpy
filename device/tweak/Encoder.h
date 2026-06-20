// Hardware H.264 encoder built on VideoToolbox. Lives in the tweak next to the
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
BOOL IOSPYH264Available(void);

#ifdef __cplusplus
}
#endif

@interface IOSPYH264Encoder : NSObject

// Encode a BGRA IOSurface to H.264. The session is created lazily and recreated
// when the frame size or rate changes. Output is AVCC (4-byte length-prefixed
// NAL units); on a keyframe the SPS/PPS parameter sets are prepended (also AVCC
// framed) so the host can build its decoder from the stream alone.
//
// Returns:
//   nil          the session could not be created or the encode errored, so the
//                caller should fall back to MJPEG.
//   empty data   the frame was dropped by the encoder this tick (skip it).
//   data         the encoded frame; *outKeyframe says whether it's a keyframe.
- (NSData *)encodeSurface:(IOSurfaceRef)surface
                    width:(int)width
                   height:(int)height
                      fps:(int)fps
            forceKeyframe:(BOOL)forceKeyframe
                 keyframe:(BOOL *)outKeyframe;

// Tear down the underlying session (e.g. when the stream stops).
- (void)invalidate;

@end
