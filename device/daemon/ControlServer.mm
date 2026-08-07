#import "ControlServer.h"
#import "Protocol.h"
#import "Detect.h"
#import "Paths.h"
#import "FrameStore.h"
#import "FrameIngest.h"

#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <netinet/ip.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

NSString *const IOSPYDaemonVersion = @"0.3.0-dream.9";
static NSString *const IOSPYTrustPath = @"/var/mobile/Library/Preferences/com.ioscpy.trust.plist";
static const NSTimeInterval IOSPYTrustLifetime = 30.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval IOSPYPairingLifetime = 120.0;

@implementation IOSPYControlServer {
    uint16_t _port;
    int _listenFd;
    BOOL _lanEnabled;
    NSString *_bindAddress;
    NSMutableDictionary *_trustedHosts;
    NSMutableDictionary *_pairingChallenges;
    NSMutableDictionary *_pairingFailures;
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _port = port;
        _listenFd = -1;
    }
    return self;
}

- (BOOL)startAndReturnError:(NSError **)error {
    // The daemon is the lightweight listener: while idle it blocks in accept()
    // and performs no capture, encode, audio, polling, or periodic disk I/O.
    // LAN is therefore reachable from a locked device without keeping the
    // expensive media pipeline alive.
    _lanEnabled = YES;
    _bindAddress = @"0.0.0.0";
    NSDictionary *lan = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.ioscpy.lan.plist"];
    NSString *requestedBind = [lan[@"BindAddress"] isKindOfClass:[NSString class]]
                                  ? lan[@"BindAddress"] : nil;
    struct in_addr configuredAddress;
    if (requestedBind.length > 0 &&
        inet_pton(AF_INET, requestedBind.UTF8String, &configuredAddress) == 1) {
        _bindAddress = [requestedBind copy];
    }
    _lanEnabled = ![_bindAddress isEqualToString:@"127.0.0.1"];
    NSDictionary *savedTrust = [NSDictionary dictionaryWithContentsOfFile:IOSPYTrustPath];
    _trustedHosts = savedTrust ? [savedTrust mutableCopy] : [NSMutableDictionary dictionary];
    _pairingChallenges = [NSMutableDictionary dictionary];
    _pairingFailures = [NSMutableDictionary dictionary];

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
    if (inet_pton(AF_INET, _bindAddress.UTF8String, &addr.sin_addr) != 1) {
        close(fd);
        return [self failWith:error message:@"invalid bind address"];
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return [self failWith:error
                      message:[NSString stringWithFormat:@"bind %@:%u failed (%s)",
                                                         _bindAddress, _port, strerror(errno)]];
    }
    if (listen(fd, 4) != 0) {
        close(fd);
        return [self failWith:error message:@"listen() failed"];
    }

    _listenFd = fd;
    NSLog(@"[ioscpyd] listening on %@:%u%@", _bindAddress, _port,
          _lanEnabled ? @" (paired LAN)" : @" (USB only)");
    printf("[ioscpyd] listening on %s:%u%s\n", _bindAddress.UTF8String, _port,
           _lanEnabled ? " (paired LAN)" : " (USB only)");
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
        int tos = IPTOS_LOWDELAY;
        setsockopt(client, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
        // Don't let a stalled/half-open client wedge the single-threaded loop.
        struct timeval tv = {30, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        // Keep the send buffer small (a frame or two) so a slow host shows up as
        // backpressure quickly and the pump drops stale frames instead of letting
        // a backlog build up on the wire.
        int sndbuf = 256 * 1024;
        setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        BOOL peerIsLoopback = ntohl(peer.sin_addr.s_addr) == INADDR_LOOPBACK;
        [self handleClient:client peerIsLoopback:peerIsLoopback peerAddress:peer];
        close(client);
    }
}

- (void)handleClient:(int)fd peerIsLoopback:(BOOL)peerIsLoopback peerAddress:(struct sockaddr_in)peer {
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

    id helloObject = payload.length
                         ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil]
                         : nil;
    NSDictionary *hello = [helloObject isKindOfClass:[NSDictionary class]]
                              ? helloObject : @{};
    NSString *issuedPairToken = nil;
    NSDate *issuedPairExpiry = nil;
    if (_lanEnabled && !peerIsLoopback &&
        ![self authorizeLANHello:hello
                              fd:fd
                     peerAddress:peer
                     issuedToken:&issuedPairToken
                           expiry:&issuedPairExpiry]) {
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
    [self sendHelloAck:fd token:sessionToken pairToken:issuedPairToken expiry:issuedPairExpiry];
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
                IOSPYWriteFrame(fd, IOSPYMsgPong, IOSPY_CHANNEL_CONTROL, hdr.seq, payload);
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
            case IOSPYMsgMediaBind: {
                if (!authenticated) {
                    [writeLock lock];
                    [self sendError:fd code:@"UNAUTHENTICATED" fatal:NO
                            message:@"authenticate before binding LAN media"];
                    [writeLock unlock];
                    break;
                }
                if (!peerIsLoopback && payload.length >= 12) {
                    const uint8_t *b = (const uint8_t *)payload.bytes;
                    uint16_t portBE = 0;
                    uint64_t tokenBE = 0;
                    memcpy(&portBE, b, sizeof(portBE));
                    memcpy(&tokenBE, b + 4, sizeof(tokenBE));
                    uint16_t mediaPort = ntohs(portBE);
                    uint64_t mediaToken = CFSwapInt64BigToHost(tokenBE);
                    if (mediaPort > 0 && mediaToken != 0) {
                        [[IOSPYFrameIngest shared]
                            setLANVideoPeerAddress:peer.sin_addr.s_addr
                                              port:mediaPort
                                             token:mediaToken];
                        NSLog(@"[ioscpyd] LAN video moved off control TCP to UDP:%u",
                              mediaPort);
                    } else {
                        [[IOSPYFrameIngest shared]
                            setLANVideoPeerAddress:0 port:0 token:0];
                        NSLog(@"[ioscpyd] LAN UDP video disabled; using TCP fallback");
                    }
                }
                break;
            }
            case IOSPYMsgStartStream:
                if (!streaming) {
                    IOSPYStreamConfig config = IOSPYParseStreamConfig(payload);
                    BOOL interFrame = (config.codec == IOSPY_VIDEO_CODEC_H264 ||
                                       config.codec == IOSPY_VIDEO_CODEC_HEVC);
                    const char *codecName = config.codec == IOSPY_VIDEO_CODEC_HEVC ? "hevc" :
                                            (config.codec == IOSPY_VIDEO_CODEC_H264 ? "h264" : "mjpeg");
                    streaming = YES;
                    [[IOSPYFrameIngest shared] setVideoReliable:interFrame];
                    [[IOSPYFrameIngest shared] tellTweakStartPayload:payload];
                    NSLog(@"[ioscpyd] stream started (codec=%s fps=%u max=%u bitrate=%u)",
                          codecName, config.target_fps,
                          config.max_dimension, config.bitrate_bps);
                    if (!interFrame) {
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
                } else {
                    // Live video reconfiguration. The host keeps the authenticated
                    // control connection open and sends a fresh START_STREAM when
                    // the user changes FPS, resolution, or bitrate. The tweak
                    // atomically stops its timer/encoder and starts with the new
                    // config, so input and clipboard remain uninterrupted.
                    IOSPYStreamConfig config = IOSPYParseStreamConfig(payload);
                    BOOL interFrame = (config.codec == IOSPY_VIDEO_CODEC_H264 ||
                                       config.codec == IOSPY_VIDEO_CODEC_HEVC);
                    const char *codecName = config.codec == IOSPY_VIDEO_CODEC_HEVC ? "hevc" :
                                            (config.codec == IOSPY_VIDEO_CODEC_H264 ? "h264" : "mjpeg");
                    [[IOSPYFrameIngest shared] setVideoReliable:interFrame];
                    [[IOSPYFrameIngest shared] tellTweakStartPayload:payload];
                    NSLog(@"[ioscpyd] stream reconfigured (codec=%s fps=%u max=%u bitrate=%u)",
                          codecName, config.target_fps,
                          config.max_dimension, config.bitrate_bps);
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
            case IOSPYMsgInputScroll:
            case IOSPYMsgClipboardSet:
            case IOSPYMsgSystemAction:
            case IOSPYMsgKeyboardMode:
            case IOSPYMsgDisplayMode:
            case IOSPYMsgAudioMode:
            case IOSPYMsgUnlock:
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
    [[IOSPYFrameIngest shared] setLANVideoPeerAddress:0 port:0 token:0];
    [[IOSPYFrameIngest shared] setHostFd:-1 writeLock:nil];
    [[IOSPYFrameIngest shared] tellTweakStop];
    // Restore the on-screen keyboard in case this session hid it. Covers an
    // abrupt host loss (kill -9, cable pull) where no explicit disable arrives.
    uint8_t keyboardOff = 0;
    [[IOSPYFrameIngest shared] forwardToTweak:IOSPYMsgKeyboardMode
                                      payload:[NSData dataWithBytes:&keyboardOff length:1]];
    uint8_t displayOn = 0;
    [[IOSPYFrameIngest shared] forwardToTweak:IOSPYMsgDisplayMode
                                      payload:[NSData dataWithBytes:&displayOn length:1]];
    uint8_t audioOff = 0;
    [[IOSPYFrameIngest shared] forwardToTweak:IOSPYMsgAudioMode
                                      payload:[NSData dataWithBytes:&audioOff length:1]];
    if (pumpDone) {
        dispatch_semaphore_wait(pumpDone,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
    }
    NSLog(@"[ioscpyd] client disconnected");
}

- (BOOL)authorizeLANHello:(NSDictionary *)hello
                       fd:(int)fd
              peerAddress:(struct sockaddr_in)peer
              issuedToken:(NSString **)issuedToken
                    expiry:(NSDate **)issuedExpiry {
    NSString *hostID = [hello[@"host_id"] isKindOfClass:[NSString class]] ? hello[@"host_id"] : nil;
    NSString *hostName = [hello[@"host_name"] isKindOfClass:[NSString class]] ? hello[@"host_name"] : @"Mac";
    NSString *pairToken = [hello[@"pair_token"] isKindOfClass:[NSString class]] ? hello[@"pair_token"] : nil;
    NSString *pairCode = [hello[@"pair_code"] isKindOfClass:[NSString class]] ? hello[@"pair_code"] : nil;
    if (hostID.length < 8 || hostID.length > 128) {
        [self sendError:fd code:@"HOST_ID_REQUIRED" fatal:YES
                message:@"LAN connection requires a stable host_id"];
        return NO;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSDictionary *trusted = [_trustedHosts[hostID] isKindOfClass:[NSDictionary class]]
        ? _trustedHosts[hostID] : nil;
    NSString *savedToken = [trusted[@"token"] isKindOfClass:[NSString class]] ? trusted[@"token"] : nil;
    NSTimeInterval savedExpiry = [trusted[@"expires"] doubleValue];
    if (savedToken.length >= 32 && pairToken.length >= 32 && savedExpiry > now &&
        [savedToken isEqualToString:pairToken]) {
        return YES;
    }
    if (trusted && savedExpiry <= now) {
        [_trustedHosts removeObjectForKey:hostID];
        [self saveTrustedHosts];
    }

    NSDictionary *failure = [_pairingFailures[hostID] isKindOfClass:[NSDictionary class]]
        ? _pairingFailures[hostID] : nil;
    NSTimeInterval cooldownUntil = [failure[@"cooldown_until"] doubleValue];
    if (cooldownUntil > now) {
        [self sendError:fd code:@"PAIR_COOLDOWN" fatal:YES
                message:@"Too many incorrect pairing attempts; wait before retrying"];
        return NO;
    }

    NSDictionary *challenge = [_pairingChallenges[hostID] isKindOfClass:[NSDictionary class]]
        ? _pairingChallenges[hostID] : nil;
    NSTimeInterval challengeExpiry = [challenge[@"expires"] doubleValue];
    NSString *expectedCode = [challenge[@"code"] isKindOfClass:[NSString class]]
        ? challenge[@"code"] : nil;

    if (pairCode.length > 0) {
        if (challengeExpiry > now && expectedCode.length == 4 && [pairCode isEqualToString:expectedCode]) {
            NSString *token = [self randomLongToken];
            NSDate *expiryDate = [NSDate dateWithTimeIntervalSince1970:now + IOSPYTrustLifetime];
            _trustedHosts[hostID] = @{
                @"token": token,
                @"expires": @(expiryDate.timeIntervalSince1970),
                @"host_name": hostName ?: @"Mac",
            };
            [_pairingChallenges removeObjectForKey:hostID];
            [_pairingFailures removeObjectForKey:hostID];
            [self saveTrustedHosts];
            NSDictionary *hide = @{@"hide": @YES};
            NSData *hideData = [NSJSONSerialization dataWithJSONObject:hide options:0 error:nil];
            if (hideData) {
                [[IOSPYFrameIngest shared] forwardToTweak:IOSPYMsgPairResult payload:hideData];
            }
            if (issuedToken) *issuedToken = token;
            if (issuedExpiry) *issuedExpiry = expiryDate;
            NSLog(@"[ioscpyd] paired LAN host %@ for 30 days", hostName);
            return YES;
        }

        NSInteger attempts = [failure[@"attempts"] integerValue] + 1;
        if (attempts >= 5) {
            _pairingFailures[hostID] = @{
                @"attempts": @0,
                @"cooldown_until": @(now + 10.0 * 60.0),
            };
        } else {
            _pairingFailures[hostID] = @{
                @"attempts": @(attempts),
                @"cooldown_until": @0,
            };
        }
        [self sendPairingError:fd code:@"PAIR_CODE_INVALID"
                       message:@"The four-digit pairing code is incorrect"
                     pairingID:challenge[@"pairing_id"] ?: @""];
        return NO;
    }

    if (![[IOSPYFrameIngest shared] tweakConnected]) {
        [self sendError:fd code:@"SPRINGBOARD_BRIDGE_UNAVAILABLE" fatal:YES
                message:@"SpringBoard bridge is not connected; run sbreload and try again"];
        return NO;
    }

    uint32_t value = arc4random_uniform(10000);
    NSString *code = [NSString stringWithFormat:@"%04u", value];
    NSString *pairingID = [self randomToken];
    NSString *peerIP = [NSString stringWithUTF8String:inet_ntoa(peer.sin_addr)] ?: @"";
    _pairingChallenges[hostID] = @{
        @"code": code,
        @"pairing_id": pairingID,
        @"expires": @(now + IOSPYPairingLifetime),
        @"host_name": hostName ?: @"Mac",
        @"peer_ip": peerIP,
    };
    NSDictionary *card = @{
        @"code": code,
        @"host_name": hostName ?: @"Mac",
        @"expires_in": @(IOSPYPairingLifetime),
    };
    NSData *cardData = [NSJSONSerialization dataWithJSONObject:card options:0 error:nil];
    if (cardData) {
        [[IOSPYFrameIngest shared] forwardToTweak:IOSPYMsgPairResult payload:cardData];
    }
    [self sendPairingError:fd code:@"PAIR_REQUIRED"
                   message:@"Enter the four-digit code displayed on the iPhone"
                 pairingID:pairingID];
    return NO;
}

- (void)saveTrustedHosts {
    if (![_trustedHosts writeToFile:IOSPYTrustPath atomically:YES]) {
        NSLog(@"[ioscpyd] could not save trusted hosts");
        return;
    }
    chmod(IOSPYTrustPath.fileSystemRepresentation, 0600);
    chown(IOSPYTrustPath.fileSystemRepresentation, 501, 501);
}

- (void)sendPairingError:(int)fd
                     code:(NSString *)code
                  message:(NSString *)message
                pairingID:(NSString *)pairingID {
    NSDictionary *err = @{
        @"code": code,
        @"component": @"ioscpyd",
        @"fatal": @YES,
        @"message": message,
        @"suggestion": @"",
        @"pairing_id": pairingID ?: @"",
        @"expires_in": @(IOSPYPairingLifetime),
    };
    [self sendJSON:fd type:IOSPYMsgError object:err];
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
        @"stream_backends": [[IOSPYFrameIngest shared] tweakConnected] ? @[@"hevc", @"h264", @"mjpeg"] : @[],
        @"input_backends": [[IOSPYFrameIngest shared] tweakConnected] ? @[@"iohid"] : @[],
        @"clipboard": @([[IOSPYFrameIngest shared] tweakConnected]),
        @"keyboard": @([[IOSPYFrameIngest shared] tweakConnected]),
        @"orientation": @NO,
        @"lan": @(_lanEnabled),
        @"lan_video_udp": @YES,
        @"black_screen": @([[IOSPYFrameIngest shared] tweakConnected]),
        @"audio": @([[IOSPYFrameIngest shared] tweakConnected]),
    };
}

- (void)sendHelloAck:(int)fd token:(NSString *)token pairToken:(NSString *)pairToken expiry:(NSDate *)expiry {
    NSMutableDictionary *ack = [@{
        @"daemon_version": IOSPYDaemonVersion,
        @"protocol_version": @(IOSPY_PROTOCOL_VERSION),
        @"session_token": token,
        @"capabilities": [self capabilityMap],
    } mutableCopy];
    if (pairToken.length > 0) {
        ack[@"pair_token"] = pairToken;
    }
    if (expiry) {
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        ack[@"pair_expires_at"] = [formatter stringFromDate:expiry];
    }
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

- (NSString *)randomLongToken {
    uint8_t bytes[32];
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
