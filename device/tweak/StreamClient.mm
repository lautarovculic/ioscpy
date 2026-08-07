#import "StreamClient.h"
#import "Capture.h"
#import "Encoder.h"
#import "Protocol.h"
#import "InputInjector.h"
#import "KeyboardSuppression.h"
#import "PairingOverlay.h"
#import "DisplayController.h"
#import "AudioCapture.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <UIKit/UIKit.h>
#import <stdlib.h>
#import <math.h>

// JPEG fallback quality. Frame rate, dimensions, H.264 bitrate, and keyframe
// interval are negotiated per stream through IOSPYStreamConfig.
static const CGFloat kQuality = 0.72;

static double streamNowMs(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

static const NSUInteger kMetricSampleCapacity = 256;

static void recordMetricSample(double *samples, NSUInteger *writes, double value) {
    if (!samples || !writes || !isfinite(value) || value < 0) return;
    samples[*writes % kMetricSampleCapacity] = value;
    (*writes)++;
}

static int compareMetricDouble(const void *a, const void *b) {
    double lhs = *(const double *)a;
    double rhs = *(const double *)b;
    return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
}

static double metricPercentile(const double *samples, NSUInteger writes, double q) {
    NSUInteger count = MIN(writes, kMetricSampleCapacity);
    if (!samples || count == 0) return 0;
    double copy[kMetricSampleCapacity];
    memcpy(copy, samples, sizeof(double) * count);
    qsort(copy, count, sizeof(double), compareMetricDouble);
    q = fmin(1.0, fmax(0.0, q));
    NSUInteger index = (NSUInteger)llround((double)(count - 1) * q);
    return copy[MIN(index, count - 1)];
}

// clipboard sync bookkeeping (must hash byte-identically to the host)
static uint64_t gLastSyncedHash = 0;
static BOOL gHaveHash = NO;
static NSInteger gLastSeenChangeCount = -1;
static NSInteger gSuppressUntilChangeCount = -1;

static uint64_t clipHash(NSString *t) {
    NSData *d = [t dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint64_t h = 1469598103934665603ULL;
    const uint8_t *b = (const uint8_t *)d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        h ^= b[i];
        h *= 1099511628211ULL;
    }
    return h;
}

@interface IOSPYStreamClient ()
- (void)startClipboardObserver;
- (void)checkClipboard;
- (void)applyRemoteClipboard:(NSString *)text paste:(BOOL)paste;
- (void)sendClipboardChanged:(NSString *)text;
- (void)resetStreamStats;
- (void)emitStatsIfNeeded;
- (void)setAudioEnabled:(BOOL)enabled;
@end

@implementation IOSPYStreamClient {
    int _fd;
    dispatch_queue_t _captureQueue;
    dispatch_queue_t _sendQueue;
    dispatch_source_t _timer;
    dispatch_queue_t _clipQueue;   // ALL UIPasteboard access happens here, off-main
    dispatch_source_t _clipTimer;
    IOSPYVideoEncoder *_encoder;   // created lazily on the capture queue
    IOSPYAudioCapture *_audioCapture;
    NSLock *_socketWriteLock;      // prevents frame/control write interleaving
    uint8_t _codec;                // 0 = MJPEG, 1 = H.264, 2 = HEVC
    BOOL _needKeyframe;            // force a hardware-codec keyframe on the next frame
    BOOL _dropUntilKeyframe;       // suppress dependent frames after an encoded frame is lost
    NSUInteger _h264InFlight;
    NSUInteger _sendBacklog;
    uint64_t _encoderEpoch;
    IOSPYStreamConfig _config;
    uint16_t _effectiveMaxDimension;
    uint32_t _effectiveBitrate;
    NSUInteger _healthyStatsWindows;
    NSUInteger _pressureStatsWindows;

    double _streamStartMs;
    double _lastStatsMs;
    uint64_t _captureTicks;
    uint64_t _capturedFrames;
    uint64_t _encodedFrames;
    uint64_t _sentFrames;
    uint64_t _droppedFrames;
    uint64_t _dropCapturePressure;
    uint64_t _dropEncoderPressure;
    uint64_t _dropSendPressure;
    uint64_t _dropTransport;
    uint64_t _dropReferenceChain;
    double _captureMsTotal;
    double _encodeMsTotal;
    double _sendMsTotal;
    double _captureMsMax;
    double _encodeMsMax;
    double _sendMsMax;
    double _captureMsSamples[kMetricSampleCapacity];
    double _encodeMsSamples[kMetricSampleCapacity];
    double _sendMsSamples[kMetricSampleCapacity];
    double _captureGapMsSamples[kMetricSampleCapacity];
    NSUInteger _captureMsWrites;
    NSUInteger _encodeMsWrites;
    NSUInteger _sendMsWrites;
    NSUInteger _captureGapMsWrites;
    double _lastCaptureTickMs;
    double _captureGapMsMax;
    NSUInteger _encodeInFlightMax;
    NSUInteger _sendBacklogMax;
    NSLock *_inputStatsLock;
    double _inputMainWaitSamples[kMetricSampleCapacity];
    double _inputInjectMsSamples[kMetricSampleCapacity];
    NSUInteger _inputMainWaitWrites;
    NSUInteger _inputInjectMsWrites;
    uint64_t _inputTouchEvents;
    BOOL _audioRequested;
    BOOL _blackScreen;
}

+ (instancetype)shared {
    static IOSPYStreamClient *client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = [[IOSPYStreamClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _config = IOSPYParseStreamConfig(nil);
        _codec = _config.codec;
        _effectiveMaxDimension = _config.max_dimension;
        _effectiveBitrate = _config.bitrate_bps;
        dispatch_queue_attr_t realtimeAttr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _captureQueue = dispatch_queue_create("com.ioscpy.capture", realtimeAttr);
        _sendQueue = dispatch_queue_create("com.ioscpy.send", realtimeAttr);
        _clipQueue = dispatch_queue_create("com.ioscpy.clip", DISPATCH_QUEUE_SERIAL);
        _socketWriteLock = [[NSLock alloc] init];
        _inputStatsLock = [[NSLock alloc] init];
        [self startClipboardObserver];
    }
    return self;
}

// Watch the device pasteboard and push changes to the Mac. ALL UIPasteboard
// access runs on _clipQueue (a dispatch-source timer, no main runloop) so a
// Handoff or Universal Clipboard stall on .string can never wedge SpringBoard.
- (void)startClipboardObserver {
    _clipTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _clipQueue);
    dispatch_source_set_timer(_clipTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_clipTimer, ^{
        [self checkClipboard];
    });
    dispatch_resume(_clipTimer);
}

// Runs on _clipQueue (off the main thread).
- (void)checkClipboard {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger cc = pb.changeCount;
    if (cc <= gSuppressUntilChangeCount) {
        gLastSeenChangeCount = cc; // our own write, swallow it
        return;
    }
    if (cc == gLastSeenChangeCount) {
        return;
    }
    gLastSeenChangeCount = cc;
    if (!pb.hasStrings) {
        return;
    }
    NSString *t = pb.string; // may block on Handoff, fine since we're off-main
    if (t.length == 0) {
        return;
    }
    uint64_t h = clipHash(t);
    if (gHaveHash && h == gLastSyncedHash) {
        return; // echo of what the host just pushed to us
    }
    gLastSyncedHash = h;
    gHaveHash = YES;
    [self sendClipboardChanged:t];
}

- (void)sendClipboardChanged:(NSString *)text {
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) {
        return;
    }
    uint8_t flags = 0;
    NSMutableData *body = [NSMutableData dataWithCapacity:1 + utf8.length];
    [body appendBytes:&flags length:1];
    [body appendData:utf8];
    // NEVER write the socket on the main thread. A stalled write would wedge
    // SpringBoard and trip the watchdog. Serialize with capture writes to _fd.
    dispatch_async(_sendQueue, ^{
        int fd = self->_fd;
        if (fd >= 0) {
            [self->_socketWriteLock lock];
            IOSPYWriteFrame(fd, IOSPYMsgClipboardChanged, IOSPY_CHANNEL_CONTROL, 0, body);
            [self->_socketWriteLock unlock];
        }
    });
}

- (void)applyRemoteClipboard:(NSString *)text paste:(BOOL)paste {
    dispatch_async(_clipQueue, ^{
        uint64_t h = clipHash(text);
        if (!(gHaveHash && h == gLastSyncedHash)) {
            gLastSyncedHash = h;
            gHaveHash = YES;
            UIPasteboard *pb = [UIPasteboard generalPasteboard];
            gSuppressUntilChangeCount = pb.changeCount + 1; // arm before write
            pb.string = text;
        }
        if (paste) {
            IOSPYKeyAction(12); // Cmd+V; IOSPYKeyAction hops to the main queue itself
        }
    });
}

- (void)start {
    [NSThread detachNewThreadSelector:@selector(connectLoop) toTarget:self withObject:nil];
}

- (void)connectLoop {
    while (1) {
        int fd = [self connectToDaemon];
        if (fd < 0) {
            sleep(1);
            continue;
        }
        _fd = fd;
        NSLog(@"[ioscpyhook] attached to daemon frame channel");
        [self readCommandsFrom:fd]; // blocks until the channel drops

        // Link to the daemon dropped (restart or crash). Never leave the device's
        // keyboard hidden behind a dead session.
        dispatch_async(dispatch_get_main_queue(), ^{ IOSPYSetKeyboardSuppressed(NO); });
        dispatch_async(_captureQueue, ^{ [self stopCapture]; });
        [self setAudioEnabled:NO];
        IOSPYSetRemoteBlackScreen(NO);
        _fd = -1;
        close(fd);
        sleep(1);
    }
}

- (int)connectToDaemon {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(IOSPY_FRAME_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    int yes = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    return fd;
}

- (void)readCommandsFrom:(int)fd {
    IOSPYFrameHeader header;
    BOOL connected = YES;
    while (connected) {
      @autoreleasepool {
        NSData *payload = nil;
        if (!IOSPYReadFrame(fd, &header, &payload)) {
            connected = NO;
            continue;
        }
        if (header.type == IOSPYMsgStartStream) {
            IOSPYStreamConfig config = IOSPYParseStreamConfig(payload);
            dispatch_async(_captureQueue, ^{
                [self stopCapture];
                self->_config = config;
                self->_codec = config.codec;
                self->_needKeyframe = YES;
                [self resetStreamStats];
                [self startCapture];
            });
        } else if (header.type == IOSPYMsgStopStream) {
            dispatch_async(_captureQueue, ^{ [self stopCapture]; });
        } else if (header.type == IOSPYMsgRequestKeyframe) {
            dispatch_async(_captureQueue, ^{
                self->_needKeyframe = YES;
                // A remote loss request does not mean our local encoded chain is
                // broken. Keep sending current P-frames while the forced IDR is
                // being produced; suppressing them here turned minor Wi-Fi loss
                // into a visible freeze and keyframe storm.
            });
        } else if (header.type == IOSPYMsgInputTouch && payload.length >= 10) {
            const uint8_t *b = (const uint8_t *)payload.bytes;
            uint8_t phase = b[0];
            uint8_t fingerID = b[1];
            uint32_t xb, yb;
            memcpy(&xb, b + 2, 4);
            memcpy(&yb, b + 6, 4);
            xb = ntohl(xb);
            yb = ntohl(yb);
            float x, y;
            memcpy(&x, &xb, 4);
            memcpy(&y, &yb, 4);
            double queuedAtMs = streamNowMs();
            dispatch_async(IOSPYInputRealtimeQueue(), ^{
                double dispatchAtMs = streamNowMs();
                double injectStartMs = dispatchAtMs;
                IOSPYInjectTouch((IOSPYTouchPhase)phase, fingerID, x, y);
                double injectMs = streamNowMs() - injectStartMs;
                [self->_inputStatsLock lock];
                recordMetricSample(self->_inputMainWaitSamples,
                                   &self->_inputMainWaitWrites,
                                   dispatchAtMs - queuedAtMs);
                recordMetricSample(self->_inputInjectMsSamples,
                                   &self->_inputInjectMsWrites,
                                   injectMs);
                self->_inputTouchEvents++;
                [self->_inputStatsLock unlock];
            });
        } else if (header.type == IOSPYMsgInputScroll && payload.length >= 28) {
            const uint8_t *b = (const uint8_t *)payload.bytes;
            uint8_t phase = b[0];
            uint8_t momentum = b[1];
            BOOL precise = b[2] != 0;
            float values[4];
            for (int i = 0; i < 4; i++) {
                uint32_t bits;
                memcpy(&bits, b + 4 + i * 4, 4);
                bits = ntohl(bits);
                memcpy(&values[i], &bits, 4);
            }
            IOSPYInjectScroll(phase, momentum, precise,
                              values[0], values[1], values[2], values[3]);
        } else if (header.type == IOSPYMsgSystemAction && payload.length >= 2) {
            const uint8_t *b = (const uint8_t *)payload.bytes;
            uint16_t action;
            memcpy(&action, b, 2);
            action = ntohs(action);
            dispatch_async(dispatch_get_main_queue(), ^{ IOSPYSystemAction(action); });
        } else if (header.type == IOSPYMsgInputText && payload.length > 0) {
            NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
            if (text) {
                IOSPYTypeText(text);
            }
        } else if (header.type == IOSPYMsgInputKey && payload.length >= 1) {
            uint8_t code = ((const uint8_t *)payload.bytes)[0];
            IOSPYKeyAction(code);
        } else if (header.type == IOSPYMsgClipboardSet && payload.length >= 1) {
            // [flags:u8][utf8 text]; flags bit0 = paste after set.
            uint8_t flags = ((const uint8_t *)payload.bytes)[0];
            NSData *body = [payload subdataWithRange:NSMakeRange(1, payload.length - 1)];
            NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (text) {
                [self applyRemoteClipboard:text paste:(flags & 0x01) != 0];
            }
        } else if (header.type == IOSPYMsgKeyboardMode && payload.length >= 1) {
            // Hide/restore the on-screen keyboard. On the main thread (UIKit reads
            // the flag there) and only touched from main, so no races.
            BOOL on = ((const uint8_t *)payload.bytes)[0] != 0;
            dispatch_async(dispatch_get_main_queue(), ^{ IOSPYSetKeyboardSuppressed(on); });
        } else if (header.type == IOSPYMsgDisplayMode && payload.length >= 1) {
            BOOL black = ((const uint8_t *)payload.bytes)[0] != 0;
            _blackScreen = black;
            if (black) {
                [self setAudioEnabled:YES];
            }
            IOSPYSetRemoteBlackScreen(black);
            if (!black && !_audioRequested) {
                [self setAudioEnabled:NO];
            }
        } else if (header.type == IOSPYMsgAudioMode && payload.length >= 1) {
            BOOL enabled = ((const uint8_t *)payload.bytes)[0] != 0;
            _audioRequested = enabled;
            [self setAudioEnabled:(enabled || _blackScreen)];
        } else if (header.type == IOSPYMsgUnlock && payload.length > 0) {
            NSString *passcode = [[NSString alloc] initWithData:payload
                                                       encoding:NSUTF8StringEncoding];
            if (passcode.length > 0) {
                IOSPYUnlockWithPasscode(passcode);
            }
        } else if (header.type == IOSPYMsgPairResult && payload.length > 0) {
            NSDictionary *pair = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
            if ([pair[@"hide"] boolValue]) {
                IOSPYHidePairingCode();
            } else {
                NSString *code = [pair[@"code"] isKindOfClass:[NSString class]] ? pair[@"code"] : nil;
                NSString *hostName = [pair[@"host_name"] isKindOfClass:[NSString class]]
                    ? pair[@"host_name"] : @"Mac";
                NSTimeInterval expires = [pair[@"expires_in"] doubleValue];
                if (code.length == 4) {
                    IOSPYShowPairingCode(code, hostName, expires > 0 ? expires : 120);
                }
            }
        }
      }
    }
}

- (void)setAudioEnabled:(BOOL)enabled {
    if (enabled) {
        if (!_audioCapture) {
            _audioCapture = [[IOSPYAudioCapture alloc] init];
        }
        if (_audioCapture.isRunning) return;
        __weak typeof(self) weakSelf = self;
        [_audioCapture startWithHandler:^(NSData *packet) {
            typeof(self) selfRef = weakSelf;
            if (!selfRef || packet.length == 0) return;
            dispatch_async(selfRef->_sendQueue, ^{
                int fd = selfRef->_fd;
                if (fd < 0) return;
                [selfRef->_socketWriteLock lock];
                BOOL sent = IOSPYWriteFrame(fd, IOSPYMsgAudioFrame,
                                             IOSPY_CHANNEL_AUDIO, 0, packet);
                [selfRef->_socketWriteLock unlock];
                if (!sent) {
                    NSLog(@"[ioscpyhook] audio frame send failed");
                }
            });
        }];
    } else {
        [_audioCapture stop];
    }
}

// everything below runs on _captureQueue

- (void)startCapture {
    if (_timer) {
        return;
    }
    if (!IOSPYCaptureAvailable()) {
        NSLog(@"[ioscpyhook] no capture backend available");
        return;
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
    uint16_t fps = MAX(_config.target_fps, 1);
    uint64_t interval = NSEC_PER_SEC / fps;
    // At 120 FPS the former interval/4 leeway was large enough to permit visible
    // timer coalescing. Keep only a small scheduling tolerance while an active
    // remote-control session explicitly requests high refresh.
    uint64_t leeway = MIN(interval / 20, 200 * NSEC_PER_USEC);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, leeway);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf captureAndSend]; });
    dispatch_resume(_timer);
    NSLog(@"[ioscpyhook] capture started codec=%u fps=%u max=%u bitrate=%u mode=%u",
          _config.codec, fps, _config.max_dimension, _config.bitrate_bps,
          _config.latency_mode);
}

- (void)stopCapture {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
        NSLog(@"[ioscpyhook] capture stopped");
    }
    // Release the encoder's hardware session while idle; it lazily rebuilds.
    _encoderEpoch++;
    [_encoder invalidate];
    _h264InFlight = 0;
    _sendBacklog = 0;
    _dropUntilKeyframe = NO;
}

- (void)resetStreamStats {
    _streamStartMs = streamNowMs();
    _lastStatsMs = _streamStartMs;
    _captureTicks = 0;
    _capturedFrames = 0;
    _encodedFrames = 0;
    _sentFrames = 0;
    _droppedFrames = 0;
    _dropCapturePressure = 0;
    _dropEncoderPressure = 0;
    _dropSendPressure = 0;
    _dropTransport = 0;
    _dropReferenceChain = 0;
    _captureMsTotal = 0;
    _encodeMsTotal = 0;
    _sendMsTotal = 0;
    _captureMsMax = 0;
    _encodeMsMax = 0;
    _sendMsMax = 0;
    _captureMsWrites = 0;
    _encodeMsWrites = 0;
    _sendMsWrites = 0;
    _captureGapMsWrites = 0;
    _lastCaptureTickMs = 0;
    _captureGapMsMax = 0;
    _encodeInFlightMax = 0;
    _sendBacklogMax = 0;
    [_inputStatsLock lock];
    _inputMainWaitWrites = 0;
    _inputInjectMsWrites = 0;
    _inputTouchEvents = 0;
    [_inputStatsLock unlock];
    _effectiveMaxDimension = _config.max_dimension;
    _effectiveBitrate = _config.bitrate_bps;
    _healthyStatsWindows = 0;
    _pressureStatsWindows = 0;
}

- (void)emitStatsIfNeeded {
    double now = streamNowMs();
    double windowMs = now - _lastStatsMs;
    if (_fd < 0 || windowMs < 1000.0) {
        return;
    }
    double captureAvg = _capturedFrames ? _captureMsTotal / _capturedFrames : 0;
    double encodeAvg = _encodedFrames ? _encodeMsTotal / _encodedFrames : 0;
    double sendAvg = _sentFrames ? _sendMsTotal / _sentFrames : 0;
    double captureP50 = metricPercentile(_captureMsSamples, _captureMsWrites, 0.50);
    double captureP95 = metricPercentile(_captureMsSamples, _captureMsWrites, 0.95);
    double captureP99 = metricPercentile(_captureMsSamples, _captureMsWrites, 0.99);
    double encodeP50 = metricPercentile(_encodeMsSamples, _encodeMsWrites, 0.50);
    double encodeP95 = metricPercentile(_encodeMsSamples, _encodeMsWrites, 0.95);
    double encodeP99 = metricPercentile(_encodeMsSamples, _encodeMsWrites, 0.99);
    double sendP50 = metricPercentile(_sendMsSamples, _sendMsWrites, 0.50);
    double sendP95 = metricPercentile(_sendMsSamples, _sendMsWrites, 0.95);
    double sendP99 = metricPercentile(_sendMsSamples, _sendMsWrites, 0.99);
    double captureGapP50 = metricPercentile(_captureGapMsSamples, _captureGapMsWrites, 0.50);
    double captureGapP95 = metricPercentile(_captureGapMsSamples, _captureGapMsWrites, 0.95);
    double captureGapP99 = metricPercentile(_captureGapMsSamples, _captureGapMsWrites, 0.99);
    double inputMainWaitP50 = 0;
    double inputMainWaitP95 = 0;
    double inputMainWaitP99 = 0;
    double inputInjectP50 = 0;
    double inputInjectP95 = 0;
    double inputInjectP99 = 0;
    uint64_t inputTouchEvents = 0;
    [_inputStatsLock lock];
    inputMainWaitP50 = metricPercentile(_inputMainWaitSamples, _inputMainWaitWrites, 0.50);
    inputMainWaitP95 = metricPercentile(_inputMainWaitSamples, _inputMainWaitWrites, 0.95);
    inputMainWaitP99 = metricPercentile(_inputMainWaitSamples, _inputMainWaitWrites, 0.99);
    inputInjectP50 = metricPercentile(_inputInjectMsSamples, _inputInjectMsWrites, 0.50);
    inputInjectP95 = metricPercentile(_inputInjectMsSamples, _inputInjectMsWrites, 0.95);
    inputInjectP99 = metricPercentile(_inputInjectMsSamples, _inputInjectMsWrites, 0.99);
    inputTouchEvents = _inputTouchEvents;
    _inputMainWaitWrites = 0;
    _inputInjectMsWrites = 0;
    _inputTouchEvents = 0;
    [_inputStatsLock unlock];
    double frameBudget = 1000.0 / MAX(_config.target_fps, 1);
    double dropRatio = _captureTicks ? (double)_droppedFrames / _captureTicks : 0;

    // High-refresh and explicit low-latency modes trade resolution for freshness.
    // Capture and VideoToolbox encode are pipelined, so summing their average
    // durations incorrectly treats healthy 120 FPS operation as overloaded. Use
    // the slower stage plus actual queue/drop signals, and require two pressured
    // windows before reducing resolution to avoid one-second oscillations.
    if (_config.latency_mode >= IOSPYLatencyLow) {
        double slowestStage = MAX(captureAvg, encodeAvg);
        BOOL pressured = dropRatio > 0.08 || slowestStage > frameBudget * 1.10 ||
                         _h264InFlight >= 2 || _sendBacklog >= 2;
        if (pressured) {
            _pressureStatsWindows++;
            _healthyStatsWindows = 0;
        } else {
            _pressureStatsWindows = 0;
        }

        if (_pressureStatsWindows >= 2 && _effectiveMaxDimension > 640) {
            uint16_t next = MAX((uint16_t)640,
                                (uint16_t)((double)_effectiveMaxDimension * 0.90));
            next &= ~1u;
            _effectiveMaxDimension = next;
            _healthyStatsWindows = 0;
            _pressureStatsWindows = 0;
        } else if (!pressured && dropRatio < 0.02 && slowestStage < frameBudget * 0.80) {
            _healthyStatsWindows++;
            if (_healthyStatsWindows >= 2 && _effectiveMaxDimension < _config.max_dimension) {
                uint16_t next = MIN(_config.max_dimension,
                                    (uint16_t)((double)_effectiveMaxDimension * 1.08));
                _effectiveMaxDimension = next & ~1u;
                _healthyStatsWindows = 0;
            }
        } else if (!pressured) {
            _healthyStatsWindows = 0;
        }

        double ratio = (double)_effectiveMaxDimension / MAX(_config.max_dimension, 1);
        uint32_t scaled = (uint32_t)((double)_config.bitrate_bps * ratio * ratio);
        _effectiveBitrate = MAX((uint32_t)2000000, MIN(_config.bitrate_bps, scaled));
    }
    NSDictionary *stats = @{
        @"uptime_ms": @((uint64_t)MAX(now - _streamStartMs, 0)),
        @"window_ms": @(windowMs),
        @"requested_fps": @(_config.target_fps),
        @"configured_max_dimension": @(_config.max_dimension),
        @"max_dimension": @(_effectiveMaxDimension),
        @"bitrate_bps": @(_effectiveBitrate),
        @"encode_inflight": @(_h264InFlight),
        @"send_backlog": @(_sendBacklog),
        @"capture_ticks": @(_captureTicks),
        @"captured_frames": @(_capturedFrames),
        @"encoded_frames": @(_encodedFrames),
        @"sent_frames": @(_sentFrames),
        @"dropped_frames": @(_droppedFrames),
        @"drop_capture_pressure": @(_dropCapturePressure),
        @"drop_encoder_pressure": @(_dropEncoderPressure),
        @"drop_send_pressure": @(_dropSendPressure),
        @"drop_transport": @(_dropTransport),
        @"drop_reference_chain": @(_dropReferenceChain),
        @"capture_ms_avg": @(captureAvg),
        @"capture_ms_p50": @(captureP50),
        @"capture_ms_p95": @(captureP95),
        @"capture_ms_p99": @(captureP99),
        @"encode_ms_avg": @(encodeAvg),
        @"encode_ms_p50": @(encodeP50),
        @"encode_ms_p95": @(encodeP95),
        @"encode_ms_p99": @(encodeP99),
        @"send_ms_avg": @(sendAvg),
        @"send_ms_p50": @(sendP50),
        @"send_ms_p95": @(sendP95),
        @"send_ms_p99": @(sendP99),
        @"capture_ms_max": @(_captureMsMax),
        @"encode_ms_max": @(_encodeMsMax),
        @"send_ms_max": @(_sendMsMax),
        @"capture_gap_ms_p50": @(captureGapP50),
        @"capture_gap_ms_p95": @(captureGapP95),
        @"capture_gap_ms_p99": @(captureGapP99),
        @"capture_gap_ms_max": @(_captureGapMsMax),
        @"encode_inflight_max": @(_encodeInFlightMax),
        @"send_backlog_max": @(_sendBacklogMax),
        @"input_touch_events": @(inputTouchEvents),
        @"input_queue_wait_ms_p50": @(inputMainWaitP50),
        @"input_queue_wait_ms_p95": @(inputMainWaitP95),
        @"input_queue_wait_ms_p99": @(inputMainWaitP99),
        // Legacy keys retained for one release so older log parsers still work.
        @"input_main_wait_ms_p50": @(inputMainWaitP50),
        @"input_main_wait_ms_p95": @(inputMainWaitP95),
        @"input_main_wait_ms_p99": @(inputMainWaitP99),
        @"input_inject_ms_p50": @(inputInjectP50),
        @"input_inject_ms_p95": @(inputInjectP95),
        @"input_inject_ms_p99": @(inputInjectP99),
        @"input": IOSPYInputDiagnostics() ?: @{},
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:stats options:0 error:nil];
    if (body) {
        int fd = _fd;
        dispatch_async(_sendQueue, ^{
            if (fd >= 0 && fd == self->_fd) {
                [self->_socketWriteLock lock];
                IOSPYTryWriteFrame(fd, IOSPYMsgStats, IOSPY_CHANNEL_CONTROL, 0, body);
                [self->_socketWriteLock unlock];
            }
        });
    }
    _lastStatsMs = now;
    _captureTicks = 0;
    _capturedFrames = 0;
    _encodedFrames = 0;
    _sentFrames = 0;
    _droppedFrames = 0;
    _dropCapturePressure = 0;
    _dropEncoderPressure = 0;
    _dropSendPressure = 0;
    _dropTransport = 0;
    _dropReferenceChain = 0;
    _captureMsTotal = 0;
    _encodeMsTotal = 0;
    _sendMsTotal = 0;
    _captureMsMax = 0;
    _encodeMsMax = 0;
    _sendMsMax = 0;
    _captureMsWrites = 0;
    _encodeMsWrites = 0;
    _sendMsWrites = 0;
    _captureGapMsWrites = 0;
    _captureGapMsMax = 0;
    _encodeInFlightMax = _h264InFlight;
    _sendBacklogMax = _sendBacklog;
}

- (void)captureAndSend {
    int fd = _fd;
    if (fd < 0) {
        return;
    }
    double tickNow = streamNowMs();
    if (_lastCaptureTickMs > 0) {
        double gapMs = tickNow - _lastCaptureTickMs;
        _captureGapMsMax = MAX(_captureGapMsMax, gapMs);
        recordMetricSample(_captureGapMsSamples, &_captureGapMsWrites, gapMs);
    }
    _lastCaptureTickMs = tickNow;
    _captureTicks++;
    BOOL handled = NO;
    if (_codec == IOSPY_VIDEO_CODEC_H264 || _codec == IOSPY_VIDEO_CODEC_HEVC) {
        if ([self captureAndSendVideo:fd]) {
            handled = YES;
        } else {
            // Preserve resolution/FPS when HEVC cannot initialize by falling
            // back to H.264. Only H.264 failure reaches the MJPEG safety path.
            [_encoder invalidate];
            _encoder = nil;
            if (_codec == IOSPY_VIDEO_CODEC_HEVC) {
                _codec = IOSPY_VIDEO_CODEC_H264;
                _needKeyframe = YES;
                NSLog(@"[ioscpyhook] HEVC unavailable; retrying with H.264");
            } else {
                _codec = IOSPY_VIDEO_CODEC_MJPEG;
                NSLog(@"[ioscpyhook] H.264 unavailable; using MJPEG");
            }
        }
    }
    if (!handled) {
        [self captureAndSendJPEG:fd];
    }
    [self emitStatsIfNeeded];
}

// Current capture orientation packed into the VIDEO_FRAME flag bits, so the host
// can rotate the (always-portrait) framebuffer upright.
static uint32_t orientationFlags(void) {
    int o = IOSPYCurrentOrientation();
    return (uint32_t)(((o - 1) & 0x3) << IOSPY_VIDEO_ORIENT_SHIFT);
}

// Build and send a VIDEO_FRAME: 16-byte header (width, height, flags, data
// length, all big-endian) then the encoded bytes.
static NSData *makeVideoFrame(int width, int height, uint32_t flags, NSData *data) {
    NSMutableData *body = [NSMutableData dataWithCapacity:16 + data.length];
    uint32_t w = htonl((uint32_t)width);
    uint32_t h = htonl((uint32_t)height);
    uint32_t fl = htonl(flags);
    uint32_t len = htonl((uint32_t)data.length);
    [body appendBytes:&w length:4];
    [body appendBytes:&h length:4];
    [body appendBytes:&fl length:4];
    [body appendBytes:&len length:4];
    [body appendData:data];
    return body;
}

- (void)captureAndSendJPEG:(int)fd {
    int width = 0, height = 0;
    double captureMs = 0, encodeMs = 0;
    NSData *jpeg = IOSPYCaptureScreenJPEG(_effectiveMaxDimension, kQuality, &width, &height,
                                          &captureMs, &encodeMs);
    if (!jpeg) {
        _droppedFrames++;
        return;
    }
    _capturedFrames++;
    _encodedFrames++;
    _captureMsTotal += captureMs;
    _encodeMsTotal += encodeMs;

    double sendStart = streamNowMs();
    [_socketWriteLock lock];
    BOOL sent = IOSPYWriteFrame(fd, IOSPYMsgVideoFrame, IOSPY_CHANNEL_VIDEO, 0,
                                makeVideoFrame(width, height, orientationFlags(), jpeg));
    [_socketWriteLock unlock];
    _sendMsTotal += streamNowMs() - sendStart;
    if (sent) {
        _sentFrames++;
    } else {
        _droppedFrames++;
    }
}

- (BOOL)captureAndSendVideo:(int)fd {
    if (!IOSPYHardwareVideoAvailable(_codec)) {
        return NO;
    }
    // Allow a very short burst on the SpringBoard->daemon loopback link. dream.5
    // capped this at two frames, so UDP fragmentation work in the daemon could
    // momentarily backpressure the loopback socket and repeatedly break the
    // reference chain. Four frames is ~33 ms at 120 Hz and remains bounded.
    NSUInteger maxSendBacklog = _config.target_fps >= 100 ? 4 : 2;
    if (_sendBacklog >= maxSendBacklog) {
        _droppedFrames++;
        _dropSendPressure++;
        return YES;
    }
    // Compression latency is not the same as throughput. At 2160p the hardware
    // callback may arrive ~35-45 ms later while still accepting a new frame every
    // 8.3 ms. Two in-flight frames therefore capped throughput near 50 FPS.
    // Keep enough slots to fill the pipeline, but never allow an unbounded queue.
    // Seven slots sustain 120 Hz with the measured ~45-50 ms hardware callback
    // latency while avoiding the extra queue age observed when all eight dream.8
    // slots filled and callback latency stretched into the 60-70 ms range.
    NSUInteger maxInFlight = _config.target_fps >= 100 ? 7 :
                             (_config.target_fps >= 80 ? 5 : 4);
    if (_h264InFlight >= maxInFlight) {
        _droppedFrames++;
        _dropEncoderPressure++;
        return YES;
    }
    if (!_encoder) {
        _encoder = [[IOSPYVideoEncoder alloc] init];
    }
    int width = 0, height = 0;
    int captureToken = -1;
    double captureStart = streamNowMs();
    IOSurfaceRef surface = IOSPYCaptureScreenSurface(_effectiveMaxDimension, &width, &height,
                                                      &captureToken);
    double captureMs = streamNowMs() - captureStart;
    if (!surface || width < 2 || height < 2) {
        IOSPYReleaseCaptureSurface(captureToken);
        _droppedFrames++;
        _dropCapturePressure++;
        return NO;
    }
    _capturedFrames++;
    _captureMsTotal += captureMs;
    _captureMsMax = MAX(_captureMsMax, captureMs);
    recordMetricSample(_captureMsSamples, &_captureMsWrites, captureMs);
    int fps = MAX(_config.target_fps, 1);
    uint8_t submittedCodec = _codec;
    BOOL forceKeyframe = _needKeyframe;
    uint64_t epoch = _encoderEpoch;
    double encodeStart = streamNowMs();
    _h264InFlight++;
    _encodeInFlightMax = MAX(_encodeInFlightMax, _h264InFlight);
    BOOL submitted = [_encoder submitSurface:surface
                                       width:width
                                      height:height
                                         fps:fps
                                       codec:submittedCodec
                                     bitrate:_effectiveBitrate
                            keyframeInterval:MAX(_config.keyframe_interval_frames, 1)
                               forceKeyframe:forceKeyframe
                                  completion:^(NSData *avcc, BOOL isKey, BOOL hardError) {
        // VideoToolbox has finished reading the IOSurface when this callback
        // fires, so the capture queue may reuse its pool slot immediately.
        IOSPYReleaseCaptureSurface(captureToken);
        double encodeMs = streamNowMs() - encodeStart;
        dispatch_async(self->_captureQueue, ^{
            if (epoch != self->_encoderEpoch) {
                return;
            }
            if (self->_h264InFlight > 0) {
                self->_h264InFlight--;
            }
            if (hardError) {
                self->_droppedFrames++;
                if (self->_codec == submittedCodec) {
                    self->_codec = submittedCodec == IOSPY_VIDEO_CODEC_HEVC
                        ? IOSPY_VIDEO_CODEC_H264 : IOSPY_VIDEO_CODEC_MJPEG;
                    self->_needKeyframe = YES;
                    NSLog(@"[ioscpyhook] asynchronous hardware encode failed; fallback codec=%u",
                          self->_codec);
                }
                return;
            }
            if (avcc.length == 0) {
                self->_droppedFrames++;
                if (forceKeyframe) {
                    self->_needKeyframe = YES;
                }
                return;
            }

            self->_encodedFrames++;
            self->_encodeMsTotal += encodeMs;
            self->_encodeMsMax = MAX(self->_encodeMsMax, encodeMs);
            recordMetricSample(self->_encodeMsSamples, &self->_encodeMsWrites, encodeMs);
            if (isKey) {
                self->_needKeyframe = NO;
                self->_dropUntilKeyframe = NO;
            } else if (self->_dropUntilKeyframe) {
                // Once one encoded inter-frame is lost, later dependent frames
                // are not useful even when they arrive successfully. Suppress
                // them until the forced IDR is ready instead of showing a burst
                // of corruption or delayed recovery on the Mac.
                self->_droppedFrames++;
                self->_dropReferenceChain++;
                self->_needKeyframe = YES;
                return;
            }

            // Keep the loopback queue bounded while tolerating short scheduling
            // bursts at 90/120 Hz.
            NSUInteger completionBacklogLimit = self->_config.target_fps >= 100 ? 4 : 2;
            if (self->_sendBacklog >= completionBacklogLimit) {
                self->_droppedFrames++;
                self->_dropSendPressure++;
                self->_needKeyframe = YES;
                self->_dropUntilKeyframe = YES;
                return;
            }
            self->_sendBacklog++;
            self->_sendBacklogMax = MAX(self->_sendBacklogMax, self->_sendBacklog);
            uint32_t flags = orientationFlags();
            flags |= submittedCodec == IOSPY_VIDEO_CODEC_HEVC
                ? IOSPY_VIDEO_FLAG_HEVC : IOSPY_VIDEO_FLAG_H264;
            if (isKey) {
                flags |= IOSPY_VIDEO_FLAG_KEYFRAME | IOSPY_VIDEO_FLAG_CONFIG;
            }
            NSData *frame = makeVideoFrame(width, height, flags, avcc);
            dispatch_async(self->_sendQueue, ^{
                double sendStart = streamNowMs();
                [self->_socketWriteLock lock];
                BOOL sent = fd >= 0 && fd == self->_fd &&
                    IOSPYWriteFrame(fd, IOSPYMsgVideoFrame, IOSPY_CHANNEL_VIDEO, 0, frame);
                [self->_socketWriteLock unlock];
                double sendMs = streamNowMs() - sendStart;
                dispatch_async(self->_captureQueue, ^{
                    if (epoch != self->_encoderEpoch) {
                        return;
                    }
                    if (self->_sendBacklog > 0) {
                        self->_sendBacklog--;
                    }
                    self->_sendMsTotal += sendMs;
                    self->_sendMsMax = MAX(self->_sendMsMax, sendMs);
                    recordMetricSample(self->_sendMsSamples, &self->_sendMsWrites, sendMs);
                    if (sent) {
                        self->_sentFrames++;
                    } else {
                        self->_droppedFrames++;
                        self->_dropTransport++;
                        self->_needKeyframe = YES;
                        self->_dropUntilKeyframe = YES;
                    }
                });
            });
        });
    }];
    if (!submitted) {
        IOSPYReleaseCaptureSurface(captureToken);
        if (_h264InFlight > 0) {
            _h264InFlight--;
        }
        _droppedFrames++;
        return NO; // hard failure, fall back to MJPEG
    }
    return YES;
}

@end
