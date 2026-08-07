#import "Capture.h"
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import <os/lock.h>

// The render server can blit the live display straight into an IOSurface. It's
// a long-standing private QuartzCore entry point; we resolve it at runtime so a
// build of iOS that lacks it just reports "unavailable" instead of failing to
// load.
typedef void (*CARenderServerRenderDisplayFn)(uint32_t client, CFStringRef display,
                                               IOSurfaceRef surface, int x, int y);

static CARenderServerRenderDisplayFn renderDisplayFn(void) {
    static CARenderServerRenderDisplayFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (CARenderServerRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    });
    return fn;
}

BOOL IOSPYCaptureAvailable(void) {
    return renderDisplayFn() != NULL;
}

static double nowMs(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

// Native screen size in pixels (cached; doesn't change at runtime).
static CGSize nativeScreenSize(void) {
    static CGSize size = {0, 0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([NSThread isMainThread]) {
            size = [UIScreen mainScreen].nativeBounds.size;
        } else {
            __block CGSize s = CGSizeZero;
            dispatch_sync(dispatch_get_main_queue(), ^{
                s = [UIScreen mainScreen].nativeBounds.size;
            });
            size = s;
        }
    });
    return size;
}

// The render server addresses displays by name; the main display's name varies
// by device, so read it rather than hardcoding "LCD".
static CFStringRef mainDisplayName(void) {
    static CFStringRef name = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *resolved = nil;
        Class displayClass = NSClassFromString(@"CADisplay");
        if (displayClass && [displayClass respondsToSelector:@selector(mainDisplay)]) {
            id display = [displayClass performSelector:@selector(mainDisplay)];
            if ([display respondsToSelector:@selector(name)]) {
                resolved = [display performSelector:@selector(name)];
            }
        }
        if (resolved.length == 0) {
            resolved = @"LCD";
        }
        name = (CFStringRef)CFBridgingRetain(resolved);
    });
    return name;
}

// Reusable destination surface, recreated only when the target size changes.
static IOSurfaceRef surfaceForSize(int width, int height) {
    static IOSurfaceRef surface = NULL;
    static int cachedW = 0, cachedH = 0;
    if (surface && cachedW == width && cachedH == height) {
        return surface;
    }
    if (surface) {
        CFRelease(surface);
        surface = NULL;
    }
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    };
    surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    cachedW = width;
    cachedH = height;
    return surface;
}

static IOSurfaceRef createBGRASurface(int width, int height) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

// Native-resolution HEVC can hold roughly six surfaces for ~45-50 ms while still
// sustaining 120 submissions/s. A six-slot pool therefore had zero scheduling
// margin and telemetry showed it pinning at 6/6 under motion, dropping 14-17
// capture opportunities/s. Keep two bounded spare surfaces so transient encoder
// service-time jitter does not turn into a hard ~100 FPS ceiling.
static const int kCaptureSlotCount = 8;
typedef struct {
    IOSurfaceRef source;
    IOSurfaceRef scaled;
    int sourceW;
    int sourceH;
    int scaledW;
    int scaledH;
    BOOL busy;
} IOSPYCaptureSlot;

static IOSPYCaptureSlot gCaptureSlots[kCaptureSlotCount] = {};
static os_unfair_lock gCapturePoolLock = OS_UNFAIR_LOCK_INIT;

static int acquireCaptureSlot(int sourceW, int sourceH, int targetW, int targetH) {
    os_unfair_lock_lock(&gCapturePoolLock);
    int token = -1;
    for (int i = 0; i < kCaptureSlotCount; i++) {
        IOSPYCaptureSlot *slot = &gCaptureSlots[i];
        if (slot->busy) {
            continue;
        }
        if (!slot->source || slot->sourceW != sourceW || slot->sourceH != sourceH) {
            if (slot->source) {
                CFRelease(slot->source);
            }
            slot->source = createBGRASurface(sourceW, sourceH);
            slot->sourceW = sourceW;
            slot->sourceH = sourceH;
        }
        if (targetW != sourceW || targetH != sourceH) {
            if (!slot->scaled || slot->scaledW != targetW || slot->scaledH != targetH) {
                if (slot->scaled) {
                    CFRelease(slot->scaled);
                }
                slot->scaled = createBGRASurface(targetW, targetH);
                slot->scaledW = targetW;
                slot->scaledH = targetH;
            }
        }
        if (slot->source &&
            ((targetW == sourceW && targetH == sourceH) || slot->scaled)) {
            slot->busy = YES;
            token = i;
        }
        break;
    }
    os_unfair_lock_unlock(&gCapturePoolLock);
    return token;
}

void IOSPYReleaseCaptureSurface(int token) {
    if (token < 0 || token >= kCaptureSlotCount) {
        return;
    }
    os_unfair_lock_lock(&gCapturePoolLock);
    gCaptureSlots[token].busy = NO;
    os_unfair_lock_unlock(&gCapturePoolLock);
}

static BOOL transferSurface(IOSurfaceRef source, IOSurfaceRef destination) {
    static VTPixelTransferSessionRef transfer = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &transfer) == noErr && transfer) {
            VTSessionSetProperty(transfer, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_Normal);
        }
    });
    if (!transfer || !source || !destination) {
        return NO;
    }
    CVPixelBufferRef sourceBuffer = NULL;
    CVPixelBufferRef destinationBuffer = NULL;
    CVReturn sourceStatus =
        CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, source, NULL, &sourceBuffer);
    CVReturn destinationStatus =
        CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, destination, NULL,
                                         &destinationBuffer);
    if (sourceStatus != kCVReturnSuccess || destinationStatus != kCVReturnSuccess ||
        !sourceBuffer || !destinationBuffer) {
        if (sourceBuffer) CVPixelBufferRelease(sourceBuffer);
        if (destinationBuffer) CVPixelBufferRelease(destinationBuffer);
        return NO;
    }
    OSStatus status =
        VTPixelTransferSessionTransferImage(transfer, sourceBuffer, destinationBuffer);
    CVPixelBufferRelease(sourceBuffer);
    CVPixelBufferRelease(destinationBuffer);
    return status == noErr;
}

IOSurfaceRef IOSPYCaptureScreenSurface(CGFloat maxDimension, int *outWidth, int *outHeight,
                                       int *outToken) {
    @autoreleasepool {
        if (outToken) {
            *outToken = -1;
        }
        CARenderServerRenderDisplayFn render = renderDisplayFn();
        if (!render) {
            return NULL;
        }
        CGSize native = nativeScreenSize();
        if (native.width < 1 || native.height < 1) {
            return NULL;
        }
        int nw = (int)native.width;
        int nh = (int)native.height;

        CGSize target = native;
        if (maxDimension > 0) {
            CGFloat longest = MAX(native.width, native.height);
            if (longest > maxDimension) {
                CGFloat factor = maxDimension / longest;
                target = CGSizeMake(round(native.width * factor), round(native.height * factor));
            }
        }
        // Round down to even dimensions for 4:2:0 H.264.
        int tw = ((int)target.width) & ~1;
        int th = ((int)target.height) & ~1;
        if (tw < 2) tw = 2;
        if (th < 2) th = 2;

        int token = acquireCaptureSlot(nw, nh, tw, th);
        if (token < 0) {
            return NULL;
        }
        IOSPYCaptureSlot *slot = &gCaptureSlots[token];
        IOSurfaceRef src = slot->source;
        IOSurfaceRef output = (tw == nw && th == nh) ? src : slot->scaled;
        if (!src || !output) {
            IOSPYReleaseCaptureSurface(token);
            return NULL;
        }

        render(0, mainDisplayName(), src, 0, 0);
        if (output != src && !transferSurface(src, output)) {
            IOSPYReleaseCaptureSurface(token);
            return NULL;
        }
        if (outWidth) {
            *outWidth = tw;
        }
        if (outHeight) {
            *outHeight = th;
        }
        if (outToken) {
            *outToken = token;
        }
        return output;
    }
}

NSData *IOSPYCaptureScreenJPEG(CGFloat maxDimension, CGFloat quality,
                               int *outWidth, int *outHeight,
                               double *outRenderMs, double *outEncodeMs) {
    @autoreleasepool {
        CARenderServerRenderDisplayFn render = renderDisplayFn();
        if (!render) {
            return nil;
        }

        CGSize native = nativeScreenSize();
        if (native.width < 1 || native.height < 1) {
            return nil;
        }
        int nw = (int)native.width;
        int nh = (int)native.height;

        // The render server blits 1:1 and clips to the surface, so capture the
        // whole screen at native size, then downscale the concrete pixels.
        CGSize target = native;
        if (maxDimension > 0) {
            CGFloat longest = MAX(native.width, native.height);
            if (longest > maxDimension) {
                CGFloat factor = maxDimension / longest;
                target = CGSizeMake(round(native.width * factor), round(native.height * factor));
            }
        }
        int tw = (int)target.width;
        int th = (int)target.height;

        IOSurfaceRef surface = surfaceForSize(nw, nh);
        if (!surface) {
            return nil;
        }

        const uint32_t bgra = kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

        double renderStart = nowMs();
        render(0, mainDisplayName(), surface, 0, 0);

        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        void *base = IOSurfaceGetBaseAddress(surface);
        size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);

        // Wrap the surface memory without copying, then draw it (downscaled, cheap
        // interpolation) into the target bitmap.
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, base, bytesPerRow * nh, NULL);
        CGImageRef nativeImage = CGImageCreate(nw, nh, 8, 32, bytesPerRow, space, bgra, provider,
                                               NULL, false, kCGRenderingIntentDefault);
        CGContextRef ctx = CGBitmapContextCreate(NULL, tw, th, 8, 0, space, bgra);
        CGImageRef image = NULL;
        if (ctx && nativeImage) {
            CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
            CGContextDrawImage(ctx, CGRectMake(0, 0, tw, th), nativeImage);
            image = CGBitmapContextCreateImage(ctx);
        }
        if (ctx) {
            CGContextRelease(ctx);
        }
        CGImageRelease(nativeImage);
        CGDataProviderRelease(provider);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        CGColorSpaceRelease(space);
        if (outRenderMs) {
            *outRenderMs = nowMs() - renderStart;
        }
        if (!image) {
            return nil;
        }

        double encodeStart = nowMs();
        NSMutableData *data = [NSMutableData data];
        // ImageIO expects a UTI string here. kUTTypeJPEG lived in the legacy
        // MobileCoreServices headers and is no longer exposed by current Apple
        // SDKs used by GitHub's macOS runners. "public.jpeg" is the canonical
        // JPEG UTI and keeps the tweak buildable across old and new SDKs.
        CFStringRef jpegType = CFSTR("public.jpeg");
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, jpegType, 1, NULL);
        BOOL ok = NO;
        if (dest) {
            NSDictionary *options = @{(__bridge id)kCGImageDestinationLossyCompressionQuality: @(quality)};
            CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)options);
            ok = CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        CGImageRelease(image);
        if (outEncodeMs) {
            *outEncodeMs = nowMs() - encodeStart;
        }

        if (!ok) {
            return nil;
        }
        if (outWidth) {
            *outWidth = tw;
        }
        if (outHeight) {
            *outHeight = th;
        }
        return data;
    }
}
