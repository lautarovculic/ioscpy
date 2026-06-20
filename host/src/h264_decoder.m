// VideoToolbox H.264 decode shim with a small C ABI for the Rust side.
//
// Keeping the CoreMedia/VideoToolbox calls here instead of in Rust FFI is just
// easier to read and works the same on every macOS. Rust hands us one AVCC
// frame at a time and gets back tightly packed BGRA.

#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct IoscpyH264Decoder {
    CMVideoFormatDescriptionRef format;
    VTDecompressionSessionRef session;
    // last parameter sets, so we only rebuild the session when they actually
    // change (a rotation or resolution change re-sends SPS/PPS)
    uint8_t *sps;
    size_t spsLen;
    uint8_t *pps;
    size_t ppsLen;
    // reusable tightly packed BGRA output buffer
    uint8_t *out;
    size_t outCap;
    int outW;
    int outH;
    // set after a decode error so the next keyframe forces a fresh session
    int needRebuild;
    // the frame the output callback captured for the in-flight decode
    CVPixelBufferRef decoded;
};

typedef struct IoscpyH264Decoder IoscpyH264Decoder;

static void decodeOutput(void *decoderRefCon, void *frameRefCon, OSStatus status,
                         VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                         CMTime pts, CMTime dur) {
    (void)frameRefCon;
    (void)infoFlags;
    (void)pts;
    (void)dur;
    IoscpyH264Decoder *dec = (IoscpyH264Decoder *)decoderRefCon;
    if (status != noErr || imageBuffer == NULL) {
        return;
    }
    if (dec->decoded) {
        CVPixelBufferRelease(dec->decoded);
    }
    dec->decoded = (CVPixelBufferRef)CVPixelBufferRetain(imageBuffer);
}

IoscpyH264Decoder *ioscpy_h264_decoder_new(void) {
    IoscpyH264Decoder *dec = (IoscpyH264Decoder *)calloc(1, sizeof(IoscpyH264Decoder));
    return dec;
}

static void teardownSession(IoscpyH264Decoder *dec) {
    if (dec->session) {
        VTDecompressionSessionInvalidate(dec->session);
        CFRelease(dec->session);
        dec->session = NULL;
    }
    if (dec->format) {
        CFRelease(dec->format);
        dec->format = NULL;
    }
}

void ioscpy_h264_decoder_free(IoscpyH264Decoder *dec) {
    if (!dec) {
        return;
    }
    teardownSession(dec);
    if (dec->decoded) {
        CVPixelBufferRelease(dec->decoded);
    }
    free(dec->sps);
    free(dec->pps);
    free(dec->out);
    free(dec);
}

// rebuild the format description and session from fresh SPS/PPS
static int rebuildSession(IoscpyH264Decoder *dec) {
    teardownSession(dec);

    const uint8_t *params[2] = {dec->sps, dec->pps};
    const size_t sizes[2] = {dec->spsLen, dec->ppsLen};
    OSStatus s = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, params, sizes, 4, &dec->format);
    if (s != noErr || !dec->format) {
        dec->format = NULL;
        return 0;
    }

    // ask for BGRA output so Rust can pack pixels directly
    CFMutableDictionaryRef destAttrs =
        CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    int32_t fmt = kCVPixelFormatType_32BGRA;
    CFNumberRef fmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fmt);
    CFDictionarySetValue(destAttrs, kCVPixelBufferPixelFormatTypeKey, fmtNum);
    CFRelease(fmtNum);

    VTDecompressionOutputCallbackRecord cb;
    cb.decompressionOutputCallback = decodeOutput;
    cb.decompressionOutputRefCon = dec;

    s = VTDecompressionSessionCreate(kCFAllocatorDefault, dec->format, NULL, destAttrs, &cb,
                                     &dec->session);
    CFRelease(destAttrs);
    if (s != noErr || !dec->session) {
        dec->session = NULL;
        teardownSession(dec);
        return 0;
    }
    return 1;
}

static void storeParam(uint8_t **dst, size_t *dstLen, const uint8_t *src, size_t len) {
    uint8_t *buf = (uint8_t *)malloc(len);
    if (buf) {
        memcpy(buf, src, len);
    }
    free(*dst);
    *dst = buf;
    *dstLen = buf ? len : 0;
}

int ioscpy_h264_decoder_decode(IoscpyH264Decoder *dec, const uint8_t *avcc, size_t len,
                               const uint8_t **out_bgra, int *out_w, int *out_h) {
    if (!dec || !avcc) {
        return -1;
    }

    // walk the AVCC NAL units. SPS/PPS configure the session, the rest become
    // the picture sample data.
    const uint8_t *newSps = NULL, *newPps = NULL;
    size_t newSpsLen = 0, newPpsLen = 0;
    uint8_t *sample = (uint8_t *)malloc(len);
    if (!sample) {
        return -1;
    }
    size_t sampleLen = 0;

    size_t i = 0;
    while (i + 4 <= len) {
        uint32_t nalLen = ((uint32_t)avcc[i] << 24) | ((uint32_t)avcc[i + 1] << 16) |
                          ((uint32_t)avcc[i + 2] << 8) | (uint32_t)avcc[i + 3];
        i += 4;
        if (nalLen == 0 || i + nalLen > len) {
            break; // malformed, decode whatever we got so far
        }
        uint8_t nalType = avcc[i] & 0x1F;
        if (nalType == 7) { // SPS
            newSps = avcc + i;
            newSpsLen = nalLen;
        } else if (nalType == 8) { // PPS
            newPps = avcc + i;
            newPpsLen = nalLen;
        } else {
            // keep the NAL in AVCC framing for the sample buffer
            sample[sampleLen++] = avcc[i - 4];
            sample[sampleLen++] = avcc[i - 3];
            sample[sampleLen++] = avcc[i - 2];
            sample[sampleLen++] = avcc[i - 1];
            memcpy(sample + sampleLen, avcc + i, nalLen);
            sampleLen += nalLen;
        }
        i += nalLen;
    }

    // only rebuild the session when the parameter sets change, when we have none
    // yet, or after a decode error asked for a reset. A steady stream shouldn't
    // pay to rebuild on every keyframe.
    if (newSps && newPps) {
        int changed = !dec->sps || !dec->pps || dec->spsLen != newSpsLen ||
                      dec->ppsLen != newPpsLen ||
                      memcmp(dec->sps, newSps, newSpsLen) != 0 ||
                      memcmp(dec->pps, newPps, newPpsLen) != 0;
        if (changed || !dec->session || dec->needRebuild) {
            storeParam(&dec->sps, &dec->spsLen, newSps, newSpsLen);
            storeParam(&dec->pps, &dec->ppsLen, newPps, newPpsLen);
            if (!rebuildSession(dec)) {
                free(sample);
                return -1;
            }
            dec->needRebuild = 0;
        }
    }

    if (!dec->session || sampleLen == 0) {
        free(sample);
        return 0; // nothing decodable yet, still waiting for a keyframe
    }

    CMBlockBufferRef bb = NULL;
    OSStatus s = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, sampleLen, NULL,
                                                    NULL, 0, sampleLen,
                                                    kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (s != noErr || !bb) {
        free(sample);
        return -1;
    }
    s = CMBlockBufferReplaceDataBytes(sample, bb, 0, sampleLen);
    free(sample);
    if (s != noErr) {
        CFRelease(bb);
        return -1;
    }

    CMSampleBufferRef sampleBuf = NULL;
    const size_t sizes[1] = {sampleLen};
    s = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, dec->format, 1, 0, NULL, 1, sizes,
                                  &sampleBuf);
    CFRelease(bb);
    if (s != noErr || !sampleBuf) {
        return -1;
    }

    if (dec->decoded) {
        CVPixelBufferRelease(dec->decoded);
        dec->decoded = NULL;
    }

    VTDecodeInfoFlags infoOut = 0;
    s = VTDecompressionSessionDecodeFrame(dec->session, sampleBuf, 0, NULL, &infoOut);
    if (s == noErr) {
        VTDecompressionSessionWaitForAsynchronousFrames(dec->session);
    }
    CFRelease(sampleBuf);
    if (s != noErr) {
        dec->needRebuild = 1; // rebuild on the next keyframe
        return -1;
    }
    if (!dec->decoded) {
        return 0; // decoded but no image this time
    }

    CVPixelBufferRef pb = dec->decoded;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidth(pb);
    int h = (int)CVPixelBufferGetHeight(pb);
    size_t srcStride = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);

    int ok = 0;
    if (w > 0 && h > 0 && base) {
        size_t need = (size_t)w * (size_t)h * 4;
        if (dec->outCap < need) {
            uint8_t *grown = (uint8_t *)realloc(dec->out, need);
            if (grown) {
                dec->out = grown;
                dec->outCap = need;
            }
        }
        if (dec->outCap >= need) {
            size_t dstStride = (size_t)w * 4;
            for (int y = 0; y < h; y++) {
                memcpy(dec->out + (size_t)y * dstStride, base + (size_t)y * srcStride, dstStride);
            }
            dec->outW = w;
            dec->outH = h;
            ok = 1;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(dec->decoded);
    dec->decoded = NULL;

    if (!ok) {
        return -1;
    }
    if (out_bgra) {
        *out_bgra = dec->out;
    }
    if (out_w) {
        *out_w = dec->outW;
    }
    if (out_h) {
        *out_h = dec->outH;
    }
    return 1;
}
