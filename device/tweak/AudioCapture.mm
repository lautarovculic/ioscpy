#import "AudioCapture.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <ReplayKit/ReplayKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <arpa/inet.h>

@implementation IOSPYAudioCapture {
    IOSPYAudioPacketHandler _handler;
    BOOL _running;
    BOOL _starting;
    float _savedVolume;
    BOOL _haveSavedVolume;
}

- (BOOL)isRunning { return _running; }

static void appendBE32(NSMutableData *data, uint32_t value) {
    uint32_t encoded = htonl(value);
    [data appendBytes:&encoded length:sizeof(encoded)];
}

static float readSample(const AudioBufferList *list, const AudioStreamBasicDescription *asbd,
                        UInt32 frame, UInt32 channel) {
    if (!list || list->mNumberBuffers == 0) return 0;
    BOOL nonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bufferIndex = nonInterleaved ? MIN(channel, list->mNumberBuffers - 1) : 0;
    UInt32 sourceChannel = nonInterleaved ? 0 : channel;
    const AudioBuffer *buffer = &list->mBuffers[bufferIndex];
    if (!buffer->mData) return 0;
    UInt32 channelsInBuffer = nonInterleaved ? 1 : MAX(asbd->mChannelsPerFrame, 1u);
    UInt32 sampleIndex = frame * channelsInBuffer + sourceChannel;
    UInt32 bits = asbd->mBitsPerChannel;
    if ((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0 && bits == 32) {
        return ((const float *)buffer->mData)[sampleIndex];
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && bits == 16) {
        return (float)((const int16_t *)buffer->mData)[sampleIndex] / 32768.0f;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && bits == 32) {
        return (float)((const int32_t *)buffer->mData)[sampleIndex] / 2147483648.0f;
    }
    return 0;
}

- (NSData *)packetFromSample:(CMSampleBufferRef)sample {
    if (!sample) return nil;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    const AudioStreamBasicDescription *asbd = format
        ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM || asbd->mSampleRate <= 0) {
        return nil;
    }
    CMItemCount frameCount = CMSampleBufferGetNumSamples(sample);
    if (frameCount <= 0 || frameCount > 8192) return nil;
    UInt32 sourceChannels = MAX(asbd->mChannelsPerFrame, 1u);
    UInt16 outputChannels = sourceChannels == 1 ? 1 : 2;

    size_t listSize = offsetof(AudioBufferList, mBuffers) +
        sizeof(AudioBuffer) * MAX(sourceChannels, 1u);
    AudioBufferList *list = (AudioBufferList *)calloc(1, listSize);
    if (!list) return nil;
    CMBlockBufferRef retained = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, NULL, list, listSize, kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained);
    if (status != noErr) {
        free(list);
        return nil;
    }

    NSMutableData *packet = [NSMutableData dataWithCapacity:16 + frameCount * outputChannels * 4];
    appendBE32(packet, 0x4150434d); // "APCM"
    appendBE32(packet, (uint32_t)llround(asbd->mSampleRate));
    uint16_t channelsBE = htons(outputChannels);
    uint16_t reserved = 0;
    [packet appendBytes:&channelsBE length:2];
    [packet appendBytes:&reserved length:2];
    appendBE32(packet, (uint32_t)frameCount);

    for (CMItemCount frame = 0; frame < frameCount; frame++) {
        for (UInt32 channel = 0; channel < outputChannels; channel++) {
            UInt32 source = MIN(channel, sourceChannels - 1);
            float sampleValue = readSample(list, asbd, (UInt32)frame, source);
            sampleValue = fminf(1.0f, fmaxf(-1.0f, sampleValue));
            uint32_t bits;
            memcpy(&bits, &sampleValue, sizeof(bits));
            bits = htonl(bits);
            [packet appendBytes:&bits length:sizeof(bits)];
        }
    }
    if (retained) CFRelease(retained);
    free(list);
    return packet;
}

- (void)setPhoneOutputMuted:(BOOL)muted {
    Class cls = objc_getClass("AVSystemController");
    SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
    if (!cls || ![(id)cls respondsToSelector:sharedSel]) return;
    id controller = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSel);
    NSString *category = @"Audio/Video";
    if (muted) {
        SEL getSel = NSSelectorFromString(@"getVolume:forCategory:");
        if ([controller respondsToSelector:getSel]) {
            float value = 0;
            BOOL ok = ((BOOL (*)(id, SEL, float *, id))objc_msgSend)(controller, getSel,
                                                                     &value, category);
            if (ok) {
                _savedVolume = value;
                _haveSavedVolume = YES;
            }
        }
    }
    SEL setSel = NSSelectorFromString(@"setVolumeTo:forCategory:");
    if ([controller respondsToSelector:setSel]) {
        float value = muted ? 0.0f : (_haveSavedVolume ? _savedVolume : 0.5f);
        ((BOOL (*)(id, SEL, float, id))objc_msgSend)(controller, setSel, value, category);
    }
    if (!muted) _haveSavedVolume = NO;
}

- (void)startWithHandler:(IOSPYAudioPacketHandler)handler {
    if (_running || _starting) return;
    _starting = YES;
    _handler = [handler copy];
    RPScreenRecorder *recorder = [RPScreenRecorder sharedRecorder];
    if (!recorder.isAvailable) {
        NSLog(@"[ioscpyhook] ReplayKit audio capture unavailable");
        _starting = NO;
        _handler = nil;
        return;
    }
    recorder.microphoneEnabled = NO;
    __weak typeof(self) weakSelf = self;
    [recorder startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer,
                                        RPSampleBufferType bufferType,
                                        NSError *error) {
        if (error) {
            NSLog(@"[ioscpyhook] ReplayKit sample error: %@", error);
            return;
        }
        if (bufferType != RPSampleBufferTypeAudioApp) return;
        typeof(self) selfRef = weakSelf;
        NSData *packet = [selfRef packetFromSample:sampleBuffer];
        if (packet.length > 16 && selfRef->_handler) {
            selfRef->_handler(packet);
        }
    } completionHandler:^(NSError *error) {
        typeof(self) selfRef = weakSelf;
        if (error) {
            NSLog(@"[ioscpyhook] ReplayKit audio start failed: %@", error);
            selfRef->_starting = NO;
            selfRef->_running = NO;
            selfRef->_handler = nil;
            return;
        }
        selfRef->_starting = NO;
        selfRef->_running = YES;
        [selfRef setPhoneOutputMuted:YES];
        NSLog(@"[ioscpyhook] system playback audio capture started");
    }];
}

- (void)stop {
    if (!_running && !_starting && !_handler) return;
    _handler = nil;
    _starting = NO;
    _running = NO;
    [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:^(NSError *error) {
        if (error) NSLog(@"[ioscpyhook] ReplayKit audio stop: %@", error);
    }];
    [self setPhoneOutputMuted:NO];
    NSLog(@"[ioscpyhook] system playback audio capture stopped");
}

- (void)dealloc { [self stop]; }

@end
