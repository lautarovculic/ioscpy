#import "Capture.h"
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <CoreServices/UTCoreTypes.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#include <math.h>

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

// Snapshot can render at the encoder's size, avoiding a full-resolution source
// and the CPU downscale below. All private symbols are optional: older systems
// keep using RenderDisplay when the entry point or any option is unavailable.
struct SnapshotAPI {
    bool (*render)(uint32_t, CFDictionaryRef);
    CFStringRef mode, displayMode, displayName, destination, originX, originY, transform;
};

static CFStringRef snapshotConstant(const char *name) {
    const CFStringRef *value = (const CFStringRef *)dlsym(RTLD_DEFAULT, name);
    return value ? *value : NULL;
}

static const SnapshotAPI *snapshotAPI(void) {
    static SnapshotAPI api = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api.render = (bool (*)(uint32_t, CFDictionaryRef))dlsym(RTLD_DEFAULT, "CARenderServerSnapshot");
        api.mode = snapshotConstant("kCASnapshotMode");
        api.displayMode = snapshotConstant("kCASnapshotModeDisplay");
        api.displayName = snapshotConstant("kCASnapshotDisplayName");
        api.destination = snapshotConstant("kCASnapshotDestination");
        api.originX = snapshotConstant("kCASnapshotOriginX");
        api.originY = snapshotConstant("kCASnapshotOriginY");
        api.transform = snapshotConstant("kCASnapshotTransform");
    });
    return api.render && api.mode && api.displayMode && api.displayName &&
           api.destination && api.originX && api.originY && api.transform ? &api : NULL;
}

static BOOL snapshotIntoSurface(IOSurfaceRef surface, CGSize native, int width, int height) {
    const SnapshotAPI *api = snapshotAPI();
    if (!api) return NO;

    static CGFloat scale = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([NSThread isMainThread]) {
            scale = [UIScreen mainScreen].nativeScale;
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                scale = [UIScreen mainScreen].nativeScale;
            });
        }
    });
    if (!isfinite(scale) || scale <= 0) return NO;

    // Snapshot's transform is in logical display coordinates. nativeScale also
    // handles devices whose physical pixel size differs from UIKit's scale.
    CATransform3D transform = CATransform3DMakeScale(
        width * scale / native.width, height * scale / native.height, 1);
    NSDictionary *options = @{
        (__bridge id)api->mode: (__bridge id)api->displayMode,
        (__bridge id)api->displayName: (__bridge id)mainDisplayName(),
        (__bridge id)api->destination: (__bridge id)surface,
        (__bridge id)api->originX: @0, (__bridge id)api->originY: @0,
        (__bridge id)api->transform: [NSValue valueWithCATransform3D:transform],
    };
    // Use the exported display-mode object, not a reconstructed string: some
    // versions of the render server compare this value by identity.
    if (!api->render(0, (__bridge CFDictionaryRef)options)) return NO;

    // Wait for the producer before returning the surface to VideoToolbox.
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) return NO;
    return IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS;
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

// Destination surface for the H.264 path, recreated only when the target size
// changes. Kept separate from the native source surface above.
static IOSurfaceRef destSurfaceForSize(int width, int height) {
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

IOSurfaceRef IOSPYCaptureScreenSurface(CGFloat maxDimension, int *outWidth, int *outHeight) {
    @autoreleasepool {
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

        IOSurfaceRef dst = destSurfaceForSize(tw, th);
        if (!dst) {
            return NULL;
        }
        if (snapshotIntoSurface(dst, native, tw, th)) {
            if (outWidth) *outWidth = tw;
            if (outHeight) *outHeight = th;
            return dst;
        }

        IOSurfaceRef src = surfaceForSize(nw, nh);
        if (!src) {
            return NULL;
        }

        const uint32_t bgra = kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        render(0, mainDisplayName(), src, 0, 0);

        IOSurfaceLock(src, kIOSurfaceLockReadOnly, NULL);
        void *base = IOSurfaceGetBaseAddress(src);
        size_t bytesPerRow = IOSurfaceGetBytesPerRow(src);
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, base, bytesPerRow * nh, NULL);
        CGImageRef nativeImage = CGImageCreate(nw, nh, 8, 32, bytesPerRow, space, bgra, provider,
                                               NULL, false, kCGRenderingIntentDefault);

        BOOL ok = NO;
        if (nativeImage) {
            IOSurfaceLock(dst, 0, NULL);
            void *dbase = IOSurfaceGetBaseAddress(dst);
            size_t dbpr = IOSurfaceGetBytesPerRow(dst);
            CGContextRef ctx = CGBitmapContextCreate(dbase, tw, th, 8, dbpr, space, bgra);
            if (ctx) {
                CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
                CGContextDrawImage(ctx, CGRectMake(0, 0, tw, th), nativeImage);
                CGContextRelease(ctx);
                ok = YES;
            }
            IOSurfaceUnlock(dst, 0, NULL);
        }

        CGImageRelease(nativeImage);
        CGDataProviderRelease(provider);
        IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, NULL);
        CGColorSpaceRelease(space);

        if (!ok) {
            return NULL;
        }
        if (outWidth) {
            *outWidth = tw;
        }
        if (outHeight) {
            *outHeight = th;
        }
        return dst;
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
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kUTTypeJPEG, 1, NULL);
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
