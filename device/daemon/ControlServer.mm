#import "ControlServer.h"
#import "Protocol.h"
#import "Detect.h"
#import "Paths.h"
#import "FrameStore.h"
#import "FrameIngest.h"

#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

NSString *const IOSPYDaemonVersion = @"0.1.0";

@implementation IOSPYControlServer {
    uint16_t _port;
    int _listenFd;
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _port = port;
        _listenFd = -1;
    }
    return self;
}

- (BOOL)startAndReturnError:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return [self failWith:error message:@"socket() failed"];
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1 only, never public

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return [self failWith:error message:[NSString stringWithFormat:@"bind 127.0.0.1:%u failed (%s)", _port, strerror(errno)]];
    }
    if (listen(fd, 4) != 0) {
        close(fd);
        return [self failWith:error message:@"listen() failed"];
    }

    _listenFd = fd;
    NSLog(@"[ioscpyd] listening on 127.0.0.1:%u", _port);
    printf("[ioscpyd] listening on 127.0.0.1:%u\n", _port);
    fflush(stdout);
    return YES;
}

- (void)runLoop {
    while (1) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int client = accept(_listenFd, (struct sockaddr *)&peer, &plen);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EBADF || errno == EINVAL) {
                // Listen socket is gone, let launchd relaunch us cleanly.
                NSLog(@"[ioscpyd] listen socket invalid (%s); stopping accept loop", strerror(errno));
                break;
            }
            // Transient fd or buffer pressure, back off so we don't spin a core.
            NSLog(@"[ioscpyd] accept() failed: %s", strerror(errno));
            usleep(100 * 1000);
            continue;
        }
        int yes = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        // Don't let a stalled/half-open client wedge the single-threaded loop.
        struct timeval tv = {30, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        // Keep the send buffer small (a frame or two) so a slow host shows up as
        // backpressure quickly and the pump drops stale frames instead of letting
        // a backlog build up on the wire.
        int sndbuf = 256 * 1024;
        setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        [self handleClient:client];
        close(client);
    }
}

- (void)handleClient:(int)fd {
    IOSPYFrameHeader hdr;
    NSData *payload = nil;

    // First frame must be HELLO. Anything else (including a probe that closes
    // right away) just drops the connection.
    if (!IOSPYReadFrame(fd, &hdr, &payload)) {
        return;
    }
    if (hdr.type != IOSPYMsgHello) {
        [self sendError:fd code:@"BAD_HANDSHAKE" message:@"expected HELLO"];
        return;
    }

    NSLog(@"[ioscpyd] client connected, sending HELLO_ACK");
    // Serialize every write to this socket: control replies run on this read
    // thread while video frames come from the pump thread.
    NSLock *writeLock = [[NSLock alloc] init];
    // Let the frame ingest relay tweak->host frames (clipboard) on this socket.
    [[IOSPYFrameIngest shared] setHostFd:fd writeLock:writeLock];
    // Per-connection secret the host must echo before we honor any privileged
    // message. Tied to this socket only, a new connection gets a fresh one.
    NSString *sessionToken = [self randomToken];
    __block BOOL authenticated = NO;
    [writeLock lock];
    [self sendHelloAck:fd token:sessionToken];
    [self sendLog:fd
            level:@"info"
          message:[NSString stringWithFormat:@"ioscpyd %@ ready, %@ (%@)", IOSPYDaemonVersion,
                                              IOSPYLayoutName(IOSPYDetectLayout()),
                                              IOSPYInjectionFramework()]];
    [writeLock unlock];

    __block BOOL alive = YES;
    __block BOOL streaming = NO;
    dispatch_semaphore_t pumpDone = NULL;

    BOOL connected = YES;
    while (connected) {
      @autoreleasepool {
        if (!IOSPYReadFrame(fd, &hdr, &payload)) {
            connected = NO;
            continue;
        }
        switch (hdr.type) {
            case IOSPYMsgPing:
                [writeLock lock];
                IOSPYWriteFrame(fd, IOSPYMsgPong, IOSPY_CHANNEL_CONTROL, hdr.seq, nil);
                [writeLock unlock];
                break;
            case IOSPYMsgCapabilitiesRequest:
                [writeLock lock];
                [self sendCapabilities:fd];
                [writeLock unlock];
                break;
            case IOSPYMsgAuthenticate: {
                NSString *got = payload.length
                                    ? [[NSString alloc] initWithData:payload
                                                            encoding:NSUTF8StringEncoding]
                                    : @"";
                if (got && [got isEqualToString:sessionToken]) {
                    authenticated = YES;
                    NSLog(@"[ioscpyd] client authenticated");
                } else {
                    // Wrong token: not the host we handed the token to, so drop
                    // it rather than take input from it.
                    [writeLock lock];
                    [self sendError:fd code:@"BAD_TOKEN" fatal:YES
                            message:@"session token mismatch"];
                    [writeLock unlock];
                    connected = NO;
                }
                break;
            }
            case IOSPYMsgStartStream:
                if (!streaming) {
                    // 1-byte payload picks the codec (0/empty = MJPEG, 1 = H.264).
                    uint8_t codec = (payload.length >= 1) ? ((const uint8_t *)payload.bytes)[0] : 0;
                    BOOL h264 = (codec == IOSPY_VIDEO_CODEC_H264);
                    streaming = YES;
                    [[IOSPYFrameIngest shared] setVideoReliable:h264];
                    [[IOSPYFrameIngest shared] tellTweakStartCodec:codec];
                    NSLog(@"[ioscpyd] stream started (codec=%s)", h264 ? "h264" : "mjpeg");
                    if (!h264) {
                        // MJPEG: latest-only pump that drops stale frames under
                        // backpressure so motion stays smooth. H.264 goes out in
                        // order straight from the ingest thread instead.
                        pumpDone = dispatch_semaphore_create(0);
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                            uint64_t lastSeq = 0;
                            while (alive && streaming) {
                                // Drain the frame payloads each iteration so memory
                                // doesn't climb on this long-lived block, or jetsam
                                // kills the daemon.
                                @autoreleasepool {
                                    // Blocks until a new frame is ready, or a short
                                    // timeout so we can re-check the run state.
                                    NSData *frame =
                                        [[IOSPYFrameStore shared] payloadNewerThan:&lastSeq];
                                    if (!frame) {
                                        continue;
                                    }
                                    [writeLock lock];
                                    // Non-blocking: if the host is behind, this
                                    // frame is dropped (rc == 0) and the loop grabs
                                    // the newest next, so latency stays about a frame.
                                    int rc = IOSPYTryWriteFrame(fd, IOSPYMsgVideoFrame,
                                                                IOSPY_CHANNEL_VIDEO, lastSeq, frame);
                                    [writeLock unlock];
                                    if (rc < 0) {
                                        break;
                                    }
                                }
                            }
                            dispatch_semaphore_signal(pumpDone);
                        });
                    }
                }
                break;
            case IOSPYMsgStopStream:
                if (streaming) {
                    streaming = NO;
                    [[IOSPYFrameIngest shared] setVideoReliable:NO];
                    [[IOSPYFrameIngest shared] tellTweakStop];
                    NSLog(@"[ioscpyd] stream stopped");
                }
                break;
            case IOSPYMsgRequestKeyframe:
                // Host wants a fresh keyframe, e.g. it just connected mid-stream.
                [[IOSPYFrameIngest shared] forwardToTweak:hdr.type payload:payload];
                break;
            case IOSPYMsgInputTouch:
            case IOSPYMsgInputKey:
            case IOSPYMsgInputText:
            case IOSPYMsgClipboardSet:
            case IOSPYMsgSystemAction:
            case IOSPYMsgKeyboardMode:
                // Privileged interaction lives in the tweak, so hand it off, but
                // only once the peer has proved it holds this session's token.
                if (!authenticated) {
                    [writeLock lock];
                    [self sendError:fd code:@"UNAUTHENTICATED" fatal:NO
                            message:@"authenticate before sending input"];
                    [writeLock unlock];
                    break;
                }
                [[IOSPYFrameIngest shared] forwardToTweak:hdr.type payload:payload];
                break;
            default:
                break;
        }
      }
    }

    // Client gone: stop the pump and wait for it before closing the socket.
    alive = NO;
    streaming = NO;
    [[IOSPYFrameIngest shared] setVideoReliable:NO];
    [[IOSPYFrameIngest shared] setHostFd:-1 writeLock:nil];
    [[IOSPYFrameIngest shared] tellTweakStop];
    // Restore the on-screen keyboard in case this session hid it. Covers an
    // abrupt host loss (kill -9, cable pull) where no explicit disable arrives.
    uint8_t keyboardOff = 0;
    [[IOSPYFrameIngest shared] forwardToTweak:IOSPYMsgKeyboardMode
                                      payload:[NSData dataWithBytes:&keyboardOff length:1]];
    if (pumpDone) {
        dispatch_semaphore_wait(pumpDone,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
    }
    NSLog(@"[ioscpyd] client disconnected");
}

- (NSDictionary *)capabilityMap {
    NSString *prefix = IOSPYJBPrefix();
    return @{
        @"ios_version": IOSPYSystemVersion(),
        @"device_model": IOSPYDeviceModel(),
        @"jailbreak_layout": IOSPYLayoutName(IOSPYDetectLayout()),
        @"jb_prefix": prefix.length ? prefix : @"/",
        @"injection_framework": IOSPYInjectionFramework(),
        @"daemon_uid": @(getuid()),
        // Backends are live whenever the tweak is attached. H.264 is preferred;
        // if a device can't encode it the tweak streams MJPEG and the host follows
        // the per-frame codec flag, so this stays a safe default.
        @"stream_backends": [[IOSPYFrameIngest shared] tweakConnected] ? @[@"h264", @"mjpeg"] : @[],
        @"input_backends": [[IOSPYFrameIngest shared] tweakConnected] ? @[@"iohid"] : @[],
        @"clipboard": @([[IOSPYFrameIngest shared] tweakConnected]),
        @"keyboard": @([[IOSPYFrameIngest shared] tweakConnected]),
        @"orientation": @NO,
    };
}

- (void)sendHelloAck:(int)fd token:(NSString *)token {
    NSDictionary *ack = @{
        @"daemon_version": IOSPYDaemonVersion,
        @"protocol_version": @(IOSPY_PROTOCOL_VERSION),
        @"session_token": token,
        @"capabilities": [self capabilityMap],
    };
    [self sendJSON:fd type:IOSPYMsgHelloAck object:ack];
}

- (void)sendCapabilities:(int)fd {
    [self sendJSON:fd type:IOSPYMsgCapabilitiesResponse object:[self capabilityMap]];
}

- (void)sendLog:(int)fd level:(NSString *)level message:(NSString *)message {
    [self sendJSON:fd type:IOSPYMsgLog object:@{@"level": level, @"message": message}];
}

- (void)sendError:(int)fd code:(NSString *)code message:(NSString *)message {
    [self sendError:fd code:code fatal:YES message:message];
}

- (void)sendError:(int)fd code:(NSString *)code fatal:(BOOL)fatal message:(NSString *)message {
    NSDictionary *err = @{
        @"code": code,
        @"component": @"ioscpyd",
        @"fatal": @(fatal),
        @"message": message,
        @"suggestion": @"",
    };
    [self sendJSON:fd type:IOSPYMsgError object:err];
}

- (void)sendJSON:(int)fd type:(IOSPYMessageType)type object:(id)object {
    NSError *jsonErr = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:object options:0 error:&jsonErr];
    if (!body) {
        NSLog(@"[ioscpyd] JSON encode failed: %@", jsonErr);
        return;
    }
    IOSPYWriteFrame(fd, type, IOSPY_CHANNEL_CONTROL, 0, body);
}

- (NSString *)randomToken {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(bytes) * 2];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

- (BOOL)failWith:(NSError **)error message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:@"com.ioscpy.daemon"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

@end
