#import "Encoder.h"

#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <arpa/inet.h>
#import <limits.h>

BOOL IOSPYHardwareVideoAvailable(uint8_t codec) {
    // VideoToolbox is present on every device we target; the real gate is whether
    // a session can actually be created, which encodeSurface: reports per-frame
    // (returning nil so the caller falls back to MJPEG). Keep this as the single
    // place to add a stricter probe if a future layout ever needs one.
    return codec == 1 || codec == 2;
}

@implementation IOSPYVideoEncoder {
    VTCompressionSessionRef _session;
    int _w, _h, _fps;
    uint8_t _codec;
    uint32_t _bitrate;
    int _keyframeInterval;
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
    _codec = 0;
    _bitrate = 0;
    _keyframeInterval = 0;
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

- (BOOL)ensureSessionForWidth:(int)width
                       height:(int)height
                          fps:(int)fps
                        codec:(uint8_t)codec
                      bitrate:(uint32_t)bitrate
             keyframeInterval:(int)keyframeInterval {
    if (_session && _w == width && _h == height && _fps == fps && _codec == codec && _bitrate == bitrate &&
        _keyframeInterval == keyframeInterval) {
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

    CMVideoCodecType codecType = codec == 2 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
                                            codecType, NULL,
                                            (__bridge CFDictionaryRef)srcAttrs, NULL,
                                            NULL, NULL, &_session);
    if (s != noErr || !_session) {
        NSLog(@"[ioscpyhook] VTCompressionSessionCreate failed (%d)", (int)s);
        _session = NULL;
        return NO;
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    // External in-flight surfaces keep the hardware pipeline full. Allowing
    // VideoToolbox to retain another 4-6 frames internally created a second,
    // invisible queue and made glass-to-glass latency vary dramatically under
    // transient load. Keep the encoder's own reorder/delay queue minimal.
    // One-frame delay was extremely responsive but left too little scheduling
    // slack for native-resolution 120 FPS when the hardware encoder had a brief
    // service-time spike. Two frames is still only ~16.7 ms at 120 Hz, while it
    // avoids throughput oscillation between a full pipeline and starvation.
    [self setProp:kVTCompressionPropertyKey_MaxFrameDelayCount number:2];
    // These newer hints are passed by their stable VideoToolbox property names
    // so the iOS 16 deployment target remains buildable. Unsupported builds just
    // ignore them (best-effort VTSessionSetProperty behavior).
    [self setProp:CFSTR("SuggestedLookAheadFrameCount") number:0];
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaximizePowerEfficiency,
                         kCFBooleanFalse);
    // High profile gives screen text and gradients better quality per bit than
    // Baseline. All supported host decoders use VideoToolbox/OpenH264 and accept
    // it; AutoLevel lets the hardware choose the level required by 120 FPS.
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         codec == 2 ? kVTProfileLevel_HEVC_Main_AutoLevel
                                    : kVTProfileLevel_H264_High_AutoLevel);
    // Keep the proven 0.2.0-dream.3 real-time path for high-refresh USB. The
    // first native-App build forced VideoToolbox to prioritize quality over
    // encoding speed; at 120 FPS that cut actual throughput roughly in half and
    // accumulated visible control latency. Bitrate/Profile already preserve
    // screen quality, so do not override the hardware's real-time scheduler.
    if (codec == 2 && fps < 90) {
        [self setProp:kVTCompressionPropertyKey_Quality real:0.90];
    } else if (fps >= 90) {
        CFStringRef speedKey = CFSTR("PrioritizeEncodingSpeedOverQuality");
        VTSessionSetProperty(_session, speedKey, kCFBooleanTrue);
    }

    // Refresh a keyframe at least every few seconds (and bound by frame count) so
    // a host that joins mid-stream recovers quickly.
    [self setProp:kVTCompressionPropertyKey_MaxKeyFrameInterval number:keyframeInterval];
    [self setProp:kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration
             real:(double)keyframeInterval / MAX(fps, 1)];
    [self setProp:kVTCompressionPropertyKey_ExpectedFrameRate number:fps];
    [self setProp:CFSTR("MaximumRealTimeFrameRate") number:fps];

    // Cap bandwidth well under the MJPEG path; screen content stays far below it.
    int avgBitrate = (int)MIN(bitrate, (uint32_t)INT_MAX);
    [self setProp:kVTCompressionPropertyKey_AverageBitRate number:avgBitrate];
    int byteCap = (int)((double)avgBitrate / 8.0 * 1.5);
    NSArray *limits = @[ @(byteCap), @(1.0) ]; // bytes per 1-second window
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits,
                         (__bridge CFArrayRef)limits);

    VTCompressionSessionPrepareToEncodeFrames(_session);

    _w = width;
    _h = height;
    _fps = fps;
    _codec = codec;
    _bitrate = bitrate;
    _keyframeInterval = keyframeInterval;
    _pts = 0;
    NSLog(@"[ioscpyhook] %@ session ready %dx%d @%dfps",
          codec == 2 ? @"HEVC" : @"H.264", width, height, fps);
    return YES;
}

// Append one NAL in AVCC framing (4-byte big-endian length prefix) to dst.
static void appendAVCC(NSMutableData *dst, const uint8_t *nal, size_t len) {
    uint32_t be = htonl((uint32_t)len);
    [dst appendBytes:&be length:4];
    [dst appendBytes:nal length:len];
}

- (BOOL)submitSurface:(IOSurfaceRef)surface
                 width:(int)width
                height:(int)height
                   fps:(int)fps
                 codec:(uint8_t)codec
               bitrate:(uint32_t)bitrate
      keyframeInterval:(int)keyframeInterval
         forceKeyframe:(BOOL)forceKeyframe
            completion:(IOSPYVideoCompletion)completion {
    if (!surface || width < 2 || height < 2) {
        return NO;
    }
    if (![self ensureSessionForWidth:width
                              height:height
                                 fps:fps
                               codec:codec
                             bitrate:bitrate
                    keyframeInterval:keyframeInterval]) {
        return NO;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pixelBuffer);
    if (cr != kCVReturnSuccess || !pixelBuffer) {
        return NO;
    }

    CMTime pts = CMTimeMake(_pts++, fps);
    NSDictionary *frameProps =
        forceKeyframe ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;

    IOSPYVideoCompletion done = [completion copy];

    OSStatus es = VTCompressionSessionEncodeFrameWithOutputHandler(
        _session, pixelBuffer, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)frameProps, NULL,
        ^(OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sample) {
          @autoreleasepool {
            if (status != noErr) {
                if (done) done(nil, NO, YES);
                return;
            }
            if (!sample || (infoFlags & kVTEncodeInfo_FrameDropped)) {
                if (done) done([NSData data], NO, NO);
                return;
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
            NSMutableData *out = [NSMutableData data];

            // On a keyframe, lead with the parameter sets so the stream is
            // self-describing for a host that just connected. If we can't pull all
            // of them, drop this frame (don't mark it a keyframe) so the next one
            // retries rather than shipping a config the host can't decode from.
            if (key) {
                size_t count = 0, appended = 0;
                int nalHeaderLen = 0;
                CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
                OSStatus psStatus = fmt ? (codec == 2
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                          fmt, 0, NULL, NULL, &count, &nalHeaderLen)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                          fmt, 0, NULL, NULL, &count, &nalHeaderLen)) : -1;
                if (fmt && psStatus == noErr) {
                    for (size_t i = 0; i < count; i++) {
                        const uint8_t *ps = NULL;
                        size_t psLen = 0;
                        OSStatus oneStatus = codec == 2
                            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                                  fmt, i, &ps, &psLen, NULL, NULL)
                            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                                  fmt, i, &ps, &psLen, NULL, NULL);
                        if (oneStatus == noErr && ps) {
                            appendAVCC(out, ps, psLen);
                            appended++;
                        }
                    }
                }
                if (count == 0 || appended != count) {
                    NSLog(@"[ioscpyhook] incomplete %@ parameter sets; retrying keyframe",
                          codec == 2 ? @"HEVC" : @"H.264");
                    if (done) done([NSData data], NO, NO);
                    return;
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
            if (done) done(out, key, NO);
          }
        });

    // VideoToolbox retains the image buffer until the asynchronous encode is
    // complete, so the caller can release its reference immediately.
    CVPixelBufferRelease(pixelBuffer);

    if (es != noErr) {
        NSLog(@"[ioscpyhook] %@ encode enqueue failed (%d)",
              codec == 2 ? @"HEVC" : @"H.264", (int)es);
        return NO;
    }
    return YES;
}

@end
