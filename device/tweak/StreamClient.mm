#import "StreamClient.h"
#import "Capture.h"
#import "Encoder.h"
#import "Protocol.h"
#import "InputInjector.h"
#import "KeyboardSuppression.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

// Capture tuning. We aim high on rate and let the serial capture queue settle the
// real fps to whatever the device can sustain. Longest side is capped for
// bandwidth and CPU.
static const CGFloat kDefaultMaxDimension = 1600.0;
static const CGFloat kDefaultQuality = 0.72;
static const NSTimeInterval kDefaultInterval = 1.0 / 45.0;
static const uint16_t kMinMaxDimension = 320;
static const uint16_t kMaxMaxDimension = 1600;
static const uint8_t kMinFps = 1;
static const uint8_t kMaxFps = 60;

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

static uint16_t readBE16(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
}

static CGFloat streamMaxDimension(uint16_t requested) {
    if (requested == 0) {
        return kDefaultMaxDimension;
    }
    return (CGFloat)MIN(MAX(requested, kMinMaxDimension), kMaxMaxDimension);
}

static NSTimeInterval streamInterval(uint8_t requestedFps) {
    if (requestedFps == 0) {
        return kDefaultInterval;
    }
    uint8_t fps = MIN(MAX(requestedFps, kMinFps), kMaxFps);
    return 1.0 / (NSTimeInterval)fps;
}

static CGFloat streamQuality(uint8_t requestedPercent) {
    if (requestedPercent == 0) {
        return kDefaultQuality;
    }
    uint8_t percent = MIN(MAX(requestedPercent, 1), 100);
    return (CGFloat)percent / 100.0;
}

@interface IOSPYStreamClient ()
- (void)startClipboardObserver;
- (void)checkClipboard;
- (void)applyRemoteClipboard:(NSString *)text paste:(BOOL)paste;
- (void)sendClipboardChanged:(NSString *)text;
@end

@implementation IOSPYStreamClient {
    int _fd;
    dispatch_queue_t _captureQueue;
    dispatch_source_t _timer;
    dispatch_queue_t _clipQueue;   // ALL UIPasteboard access happens here, off-main
    dispatch_source_t _clipTimer;
    IOSPYH264Encoder *_encoder;    // created lazily on the capture queue
    uint8_t _codec;                // 0 = MJPEG, 1 = H.264 (host's request)
    CGFloat _maxDimension;
    CGFloat _quality;
    NSTimeInterval _interval;
    BOOL _needKeyframe;            // force an H.264 keyframe on the next frame
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
        _maxDimension = kDefaultMaxDimension;
        _quality = kDefaultQuality;
        _interval = kDefaultInterval;
        _captureQueue = dispatch_queue_create("com.ioscpy.capture", DISPATCH_QUEUE_SERIAL);
        _clipQueue = dispatch_queue_create("com.ioscpy.clip", DISPATCH_QUEUE_SERIAL);
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
    dispatch_async(_captureQueue, ^{
        int fd = self->_fd;
        if (fd >= 0) {
            IOSPYWriteFrame(fd, IOSPYMsgClipboardChanged, IOSPY_CHANNEL_CONTROL, 0, body);
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
            // START_STREAM: byte 0 selects codec. Newer hosts may append capture
            // knobs: maxDimension u16, fps u8, JPEG quality percent u8. Missing or
            // zero values keep the legacy defaults for backward compatibility.
            const uint8_t *bytes = (const uint8_t *)payload.bytes;
            uint8_t codec = (payload.length >= 1) ? bytes[0] : 0;
            uint16_t maxDim = (payload.length >= 3) ? readBE16(bytes + 1) : 0;
            uint8_t fps = (payload.length >= 4) ? bytes[3] : 0;
            uint8_t quality = (payload.length >= 5) ? bytes[4] : 0;
            dispatch_async(_captureQueue, ^{
                self->_codec = codec;
                self->_maxDimension = streamMaxDimension(maxDim);
                self->_interval = streamInterval(fps);
                self->_quality = streamQuality(quality);
                self->_needKeyframe = YES;
                NSLog(@"[ioscpyhook] stream profile codec=%u max=%.0f fps=%.1f quality=%.2f",
                      codec, self->_maxDimension, 1.0 / self->_interval, self->_quality);
                [self startCapture];
            });
        } else if (header.type == IOSPYMsgStopStream) {
            dispatch_async(_captureQueue, ^{ [self stopCapture]; });
        } else if (header.type == IOSPYMsgRequestKeyframe) {
            dispatch_async(_captureQueue, ^{ self->_needKeyframe = YES; });
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
            dispatch_async(dispatch_get_main_queue(), ^{
                IOSPYInjectTouch((IOSPYTouchPhase)phase, fingerID, x, y);
            });
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
        }
      }
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
    uint64_t interval = (uint64_t)(_interval * NSEC_PER_SEC);
    if (interval == 0) {
        interval = (uint64_t)(kDefaultInterval * NSEC_PER_SEC);
    }
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf captureAndSend]; });
    dispatch_resume(_timer);
    NSLog(@"[ioscpyhook] capture started");
}

- (void)stopCapture {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
        NSLog(@"[ioscpyhook] capture stopped");
    }
    // Release the encoder's hardware session while idle; it lazily rebuilds.
    [_encoder invalidate];
}

- (void)captureAndSend {
    int fd = _fd;
    if (fd < 0) {
        return;
    }
    if (_codec == IOSPY_VIDEO_CODEC_H264) {
        if ([self captureAndSendH264:fd]) {
            return;
        }
        // H.264 isn't usable on this device/OS, so drop to MJPEG for the rest of
        // the session and the screen still shows. The host follows the per-frame
        // flags, so it adapts on its own. Tear the encoder down (and force a fresh
        // one if H.264 is requested again) so a half-failed session isn't reused.
        [_encoder invalidate];
        _encoder = nil;
        _codec = IOSPY_VIDEO_CODEC_MJPEG;
        NSLog(@"[ioscpyhook] H.264 unavailable; using MJPEG");
    }
    [self captureAndSendJPEG:fd];
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
    NSData *jpeg = IOSPYCaptureScreenJPEG(_maxDimension, _quality, &width, &height, NULL, NULL);
    if (!jpeg) {
        return;
    }
    IOSPYWriteFrame(fd, IOSPYMsgVideoFrame, IOSPY_CHANNEL_VIDEO, 0,
                    makeVideoFrame(width, height, orientationFlags(), jpeg));
}

- (BOOL)captureAndSendH264:(int)fd {
    if (!IOSPYH264Available()) {
        return NO;
    }
    if (!_encoder) {
        _encoder = [[IOSPYH264Encoder alloc] init];
    }
    int width = 0, height = 0;
    IOSurfaceRef surface = IOSPYCaptureScreenSurface(_maxDimension, &width, &height);
    if (!surface || width < 2 || height < 2) {
        return NO;
    }
    int fps = (int)round(1.0 / _interval);
    if (fps < 1) {
        fps = 1;
    }
    BOOL isKey = NO;
    NSData *avcc = [_encoder encodeSurface:surface
                                     width:width
                                    height:height
                                       fps:fps
                             forceKeyframe:_needKeyframe
                                  keyframe:&isKey];
    if (!avcc) {
        return NO; // hard failure, fall back to MJPEG
    }
    if (avcc.length == 0) {
        return YES; // dropped this tick, encoder still healthy
    }
    if (isKey) {
        _needKeyframe = NO;
    }
    uint32_t flags = IOSPY_VIDEO_FLAG_H264 | orientationFlags();
    if (isKey) {
        flags |= IOSPY_VIDEO_FLAG_KEYFRAME | IOSPY_VIDEO_FLAG_CONFIG;
    }
    IOSPYWriteFrame(fd, IOSPYMsgVideoFrame, IOSPY_CHANNEL_VIDEO, 0,
                    makeVideoFrame(width, height, flags, avcc));
    return YES;
}

@end
