// Optional, on-device test of the actual capture implementation. This executable
// does not install a tweak, connect to a daemon, or inject into another process.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <vector>
#include <algorithm>
#include <arpa/inet.h>
#import "../tweak/Encoder.h"

static const char *fault = "none";
static unsigned snapshotCalls = 0, legacyCalls = 0;
static bool (*realSnapshot)(uint32_t, CFDictionaryRef);
static void (*realLegacy)(uint32_t, CFStringRef, IOSurfaceRef, int, int);
static bool injectedLockFailure = false;
static bool injectedUnlockFailure = false;
static bool countedSnapshot(uint32_t client, CFDictionaryRef options) {
    ++snapshotCalls;
    if (!strcmp(fault, "render")) return false;
    return realSnapshot(client, options);
}
static void countedLegacy(uint32_t client, CFStringRef display, IOSurfaceRef surface, int x, int y) {
    ++legacyCalls;
    realLegacy(client, display, surface, x, y);
}
static void *probeDlsym(void *handle, const char *name) {
    if (!strcmp(fault, "symbol") && !strcmp(name, "CARenderServerSnapshot")) return NULL;
    if (!strcmp(fault, "constant") && !strcmp(name, "kCASnapshotTransform")) return NULL;
    void *value = dlsym(handle, name);
    if (!strcmp(name, "CARenderServerSnapshot") && value) {
        realSnapshot = (decltype(realSnapshot))value;
        return (void *)&countedSnapshot;
    }
    if (!strcmp(name, "CARenderServerRenderDisplay") && value) {
        realLegacy = (decltype(realLegacy))value;
        return (void *)&countedLegacy;
    }
    return value;
}
static kern_return_t probeLock(IOSurfaceRef surface, IOSurfaceLockOptions options, uint32_t *seed) {
    if (!strcmp(fault, "lock") && snapshotCalls && !injectedLockFailure) {
        injectedLockFailure = true;
        return KERN_FAILURE;
    }
    return IOSurfaceLock(surface, options, seed);
}
static kern_return_t probeUnlock(IOSurfaceRef surface, IOSurfaceLockOptions options, uint32_t *seed) {
    kern_return_t result = IOSurfaceUnlock(surface, options, seed);
    if (!strcmp(fault, "unlock") && snapshotCalls && !injectedUnlockFailure) {
        injectedUnlockFailure = true;
        return KERN_FAILURE;
    }
    return result;
}

#define dlsym probeDlsym
#define IOSurfaceLock probeLock
#define IOSurfaceUnlock probeUnlock
#ifndef CAPTURE_SOURCE
#define CAPTURE_SOURCE "../tweak/Capture.mm"
#endif
#include CAPTURE_SOURCE
#undef IOSurfaceUnlock
#undef IOSurfaceLock
#undef dlsym

static double monotonicMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
static double cpuMs() {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000.0 +
           (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000.0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // maxDimension, frame count, target FPS, fault, optional output PNG,
        // optional "encode", optional output Annex-B H.264 path.
        double cap = argc > 1 ? atof(argv[1]) : 1600;
        int count = argc > 2 ? atoi(argv[2]) : 1;
        double fps = argc > 3 ? atof(argv[3]) : 30;
        if (argc > 4) fault = argv[4];
        if (count < 1 || count > 18000 || !isfinite(fps) || fps < 1 || fps > 120 ||
            !isfinite(cap) || cap < 0 || cap > 8192) return 2;
        if (strcmp(fault, "none") && strcmp(fault, "symbol") && strcmp(fault, "constant") &&
            strcmp(fault, "render") && strcmp(fault, "lock") && strcmp(fault, "unlock")) return 2;
        std::vector<double> elapsed;
        IOSPYH264Encoder *encoder = argc > 6 && !strcmp(argv[6], "encode") ? [IOSPYH264Encoder new] : nil;
        unsigned encodedFrames = 0, keyframes = 0;
        unsigned long encodedBytes = 0;
        NSMutableData *annexB = argc > 7 ? [NSMutableData data] : nil;
        int width = 0, height = 0, failures = 0;
        IOSurfaceRef surface = NULL;
        // Warm caches and exclude initialization from the measurements.
        for (int i = 0; i < 10; ++i) IOSPYCaptureScreenSurface(cap, &width, &height);
        snapshotCalls = legacyCalls = 0;
        injectedLockFailure = injectedUnlockFailure = false;
        double start = monotonicMs(), cpuStart = cpuMs();
        for (int i = 0; i < count; ++i) {
            double t = monotonicMs();
            surface = IOSPYCaptureScreenSurface(cap, &width, &height);
            elapsed.push_back(monotonicMs() - t);
            if (!surface || width < 2 || height < 2 || width % 2 || height % 2 ||
                IOSurfaceGetWidth(surface) != (size_t)width || IOSurfaceGetHeight(surface) != (size_t)height) ++failures;
            if (encoder && surface) {
                BOOL key = NO;
                NSData *encoded = [encoder encodeSurface:surface width:width height:height fps:(int)fps
                    forceKeyframe:i == 0 keyframe:&key];
                if (!encoded) ++failures;
                if (encoded.length) {
                    ++encodedFrames;
                    if (key) ++keyframes;
                    encodedBytes += encoded.length;
                    const uint8_t *bytes = (const uint8_t *)encoded.bytes;
                    for (NSUInteger pos = 0; annexB && pos + 4 <= encoded.length;) {
                        uint32_t length;
                        memcpy(&length, bytes + pos, 4);
                        length = ntohl(length);
                        pos += 4;
                        if (length > encoded.length - pos) { ++failures; break; }
                        const uint8_t prefix[] = {0,0,0,1};
                        [annexB appendBytes:prefix length:4];
                        [annexB appendBytes:bytes + pos length:length];
                        pos += length;
                    }
                }
            }
            double wait = start + (i + 1) * 1000.0 / fps - monotonicMs();
            if (wait > 0) usleep((useconds_t)(wait * 1000));
        }
        double cpu = cpuMs() - cpuStart, wall = monotonicMs() - start;
        [encoder invalidate];
        if (annexB) [annexB writeToFile:[NSString stringWithUTF8String:argv[7]] atomically:YES];
        std::sort(elapsed.begin(), elapsed.end());
        double sum = 0;
        for (double value : elapsed) sum += value;
        // A PNG is optional local evidence, never needed for metrics. It can
        // contain personal screen content and should not be committed.
        if (surface && argc > 5) {
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), width, height,
                8, IOSurfaceGetBytesPerRow(surface), space,
                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            if (context) {
                CGImageRef image = CGBitmapContextCreateImage(context);
                NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
                [png writeToFile:[NSString stringWithUTF8String:argv[5]] atomically:YES];
                CGImageRelease(image);
                CGContextRelease(context);
            }
            CGColorSpaceRelease(space);
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        }
        printf("{\"frames\":%d,\"failures\":%d,\"width\":%d,\"height\":%d,"
               "\"snapshot_calls\":%u,\"legacy_calls\":%u,\"fault\":\"%s\","
               "\"encoded_frames\":%u,\"encoded_bytes\":%lu,\"keyframes\":%u,"
               "\"wall_ms\":%.3f,\"cpu_ms\":%.3f,\"mean_ms\":%.3f,\"p50_ms\":%.3f,\"p95_ms\":%.3f}\n",
               count, failures, width, height, snapshotCalls, legacyCalls, fault,
               encodedFrames, encodedBytes, keyframes,
               wall, cpu, sum/count, elapsed[count/2], elapsed[(count-1)*95/100]);
        return failures ? 1 : 0;
    }
}
