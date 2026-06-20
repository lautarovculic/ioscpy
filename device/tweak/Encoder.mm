#import "Encoder.h"

#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <arpa/inet.h>

BOOL IOSPYH264Available(void) {
    // VideoToolbox is present on every device we target; the real gate is whether
    // a session can actually be created, which encodeSurface: reports per-frame
    // (returning nil so the caller falls back to MJPEG). Keep this as the single
    // place to add a stricter probe if a future layout ever needs one.
    return YES;
}

@implementation IOSPYH264Encoder {
    VTCompressionSessionRef _session;
    int _w, _h, _fps;
    int64_t _pts;          // monotonic frame index for presentation timestamps
}

- (void)invalidate {
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _w = _h = _fps = 0;
}

- (void)dealloc {
    [self invalidate];
}

// Best-effort property set. An OS that doesn't know a key just keeps its default
// rather than failing the whole session, which keeps us portable across versions.
- (void)setProp:(CFStringRef)key number:(int)value {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &value);
    VTSessionSetProperty(_session, key, n);
    CFRelease(n);
}

- (void)setProp:(CFStringRef)key real:(double)value {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &value);
    VTSessionSetProperty(_session, key, n);
    CFRelease(n);
}

- (BOOL)ensureSessionForWidth:(int)width height:(int)height fps:(int)fps {
    if (_session && _w == width && _h == height && _fps == fps) {
        return YES;
    }
    [self invalidate];

    // Ask the encoder to vend BGRA IOSurface-backed buffers so wrapping the
    // capture surface is zero-copy.
    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };

    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
                                            kCMVideoCodecType_H264, NULL,
                                            (__bridge CFDictionaryRef)srcAttrs, NULL,
                                            NULL, NULL, &_session);
    if (s != noErr || !_session) {
        NSLog(@"[ioscpyhook] VTCompressionSessionCreate failed (%d)", (int)s);
        _session = NULL;
        return NO;
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);

    // Refresh a keyframe at least every few seconds (and bound by frame count) so
    // a host that joins mid-stream recovers quickly.
    [self setProp:kVTCompressionPropertyKey_MaxKeyFrameInterval number:fps * 4];
    [self setProp:kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration real:4.0];
    [self setProp:kVTCompressionPropertyKey_ExpectedFrameRate number:fps];

    // Cap bandwidth well under the MJPEG path; screen content stays far below it.
    int avgBitrate = 8 * 1000 * 1000;
    [self setProp:kVTCompressionPropertyKey_AverageBitRate number:avgBitrate];
    int byteCap = (int)((double)avgBitrate / 8.0 * 1.5);
    NSArray *limits = @[ @(byteCap), @(1.0) ]; // bytes per 1-second window
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits,
                         (__bridge CFArrayRef)limits);

    VTCompressionSessionPrepareToEncodeFrames(_session);

    _w = width;
    _h = height;
    _fps = fps;
    _pts = 0;
    NSLog(@"[ioscpyhook] H.264 session ready %dx%d @%dfps", width, height, fps);
    return YES;
}

// Append one NAL in AVCC framing (4-byte big-endian length prefix) to dst.
static void appendAVCC(NSMutableData *dst, const uint8_t *nal, size_t len) {
    uint32_t be = htonl((uint32_t)len);
    [dst appendBytes:&be length:4];
    [dst appendBytes:nal length:len];
}

- (NSData *)encodeSurface:(IOSurfaceRef)surface
                    width:(int)width
                   height:(int)height
                      fps:(int)fps
            forceKeyframe:(BOOL)forceKeyframe
                 keyframe:(BOOL *)outKeyframe {
    if (outKeyframe) {
        *outKeyframe = NO;
    }
    if (!surface || width < 2 || height < 2) {
        return nil;
    }
    if (![self ensureSessionForWidth:width height:height fps:fps]) {
        return nil;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pixelBuffer);
    if (cr != kCVReturnSuccess || !pixelBuffer) {
        return nil;
    }

    CMTime pts = CMTimeMake(_pts++, fps);
    NSDictionary *frameProps =
        forceKeyframe ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;

    __block NSData *result = nil;
    __block BOOL isKey = NO;
    __block BOOL hardError = NO;

    OSStatus es = VTCompressionSessionEncodeFrameWithOutputHandler(
        _session, pixelBuffer, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)frameProps, NULL,
        ^(OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sample) {
            if (status != noErr) {
                hardError = YES;
                return;
            }
            if (!sample || (infoFlags & kVTEncodeInfo_FrameDropped)) {
                return; // dropped this tick, not an error
            }

            // A sample is a keyframe unless it's explicitly marked not-sync.
            BOOL key = YES;
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFDictionaryRef d =
                    (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                CFBooleanRef notSync = NULL;
                if (CFDictionaryGetValueIfPresent(d, kCMSampleAttachmentKey_NotSync,
                                                  (const void **)&notSync) &&
                    notSync && CFBooleanGetValue(notSync)) {
                    key = NO;
                }
            }
            isKey = key;

            NSMutableData *out = [NSMutableData data];

            // On a keyframe, lead with the parameter sets so the stream is
            // self-describing for a host that just connected. If we can't pull all
            // of them, drop this frame (don't mark it a keyframe) so the next one
            // retries rather than shipping a config the host can't decode from.
            if (key) {
                size_t count = 0, appended = 0;
                int nalHeaderLen = 0;
                CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
                if (fmt &&
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, 0, NULL, NULL, &count, &nalHeaderLen) == noErr) {
                    for (size_t i = 0; i < count; i++) {
                        const uint8_t *ps = NULL;
                        size_t psLen = 0;
                        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                                fmt, i, &ps, &psLen, NULL, NULL) == noErr && ps) {
                            appendAVCC(out, ps, psLen);
                            appended++;
                        }
                    }
                }
                if (count == 0 || appended != count) {
                    NSLog(@"[ioscpyhook] incomplete H.264 parameter sets; retrying keyframe");
                    isKey = NO;
                    return; // leaves result nil, caller treats it as a dropped tick
                }
            }

            // The sample data is already AVCC (length-prefixed) coming out of
            // VideoToolbox, so copy it across verbatim.
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sample);
            if (bb) {
                size_t total = CMBlockBufferGetDataLength(bb);
                NSMutableData *nalData = [NSMutableData dataWithLength:total];
                if (CMBlockBufferCopyDataBytes(bb, 0, total, nalData.mutableBytes) == noErr) {
                    [out appendData:nalData];
                }
            }
            result = out;
        });

    if (es != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        NSLog(@"[ioscpyhook] H.264 encode enqueue failed (%d)", (int)es);
        return nil;
    }

    // Flush so the handler has run and order is preserved before we return. Only
    // then are hardError and result settled.
    VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
    CVPixelBufferRelease(pixelBuffer);

    if (hardError) {
        NSLog(@"[ioscpyhook] H.264 encode failed");
        return nil;
    }
    if (outKeyframe) {
        *outKeyframe = isKey;
    }
    // No data this tick is a drop, not a failure. Hand back empty so the caller
    // skips the frame but keeps using H.264.
    return result ?: [NSData data];
}

@end
