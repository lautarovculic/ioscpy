// Fast full-screen capture. The render server blits the live display into an
// IOSurface; H.264 frames use pooled surfaces and VideoToolbox pixel transfer
// for hardware scaling, while the MJPEG fallback uses CoreGraphics/ImageIO.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Whether a working capture backend is available on this device/OS.
BOOL IOSPYCaptureAvailable(void);

// Capture the screen, downscaled (longest side capped by maxDimension, 0 =
// native), into a pooled BGRA IOSurface with even dimensions. `outToken` receives
// the pool slot that must be returned with IOSPYReleaseCaptureSurface after the
// asynchronous encoder has finished reading it. Returns NULL with token -1 when
// no slot is available or capture fails. Safe to call off the main thread.
IOSurfaceRef IOSPYCaptureScreenSurface(CGFloat maxDimension, int *outWidth, int *outHeight,
                                       int *outToken);

// Return a surface acquired by IOSPYCaptureScreenSurface to the two-frame pool.
void IOSPYReleaseCaptureSurface(int token);

// Capture the current screen as JPEG. maxDimension caps the longest side
// (0 = native), quality runs 0.0 to 1.0. Writes the encoded pixel size to
// outWidth/outHeight and, if non-NULL, the render and encode times in ms.
// Safe to call off the main thread.
NSData *IOSPYCaptureScreenJPEG(CGFloat maxDimension, CGFloat quality,
                               int *outWidth, int *outHeight,
                               double *outRenderMs, double *outEncodeMs);

#ifdef __cplusplus
}
#endif
