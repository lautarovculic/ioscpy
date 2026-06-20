// Fast full-screen capture. The render server blits the live display into an
// IOSurface on the GPU; we then downscale cheaply and JPEG-encode. Works on
// whatever screen the device has. Size and scale are read at runtime.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Whether a working capture backend is available on this device/OS.
BOOL IOSPYCaptureAvailable(void);

// Capture the screen, downscaled (longest side capped by maxDimension, 0 =
// native), into a reusable BGRA IOSurface with even dimensions (the H.264
// encoder needs even width/height). Writes the surface size to outWidth/outHeight
// and returns the surface (owned internally, valid until the next call) or NULL.
// Safe to call off the main thread.
IOSurfaceRef IOSPYCaptureScreenSurface(CGFloat maxDimension, int *outWidth, int *outHeight);

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
