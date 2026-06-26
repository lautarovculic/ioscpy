#import "FrameIngest.h"
#import "FrameStore.h"
#import "Protocol.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

static BOOL IOSPYVideoPayloadIsH264(NSData *payload) {
    if (payload.length < 16) {
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)payload.bytes;
    uint32_t flags = 0;
    memcpy(&flags, bytes + 8, sizeof(flags));
    return (ntohl(flags) & IOSPY_VIDEO_FLAG_H264) != 0;
}

@implementation IOSPYFrameIngest {
    uint16_t _port;
    int _listenFd;
    int _tweakFd;       // -1 when no tweak is connected
    NSLock *_writeLock; // guards _tweakFd and writes to it
    int _hostFd;        // the control server's host socket, -1 when none
    NSLock *_hostLock;  // the control server's per-connection write lock
    BOOL _videoReliable; // YES when the host requested H.264/in-order delivery
    BOOL _loggedMJPEGFallback;
    BOOL _loggedReliableVideoFailure;
}

+ (instancetype)shared {
    static IOSPYFrameIngest *ingest = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ingest = [[IOSPYFrameIngest alloc] init];
    });
    return ingest;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFd = -1;
        _tweakFd = -1;
        _writeLock = [[NSLock alloc] init];
        _hostFd = -1;
    }
    return self;
}

- (void)setHostFd:(int)fd writeLock:(NSLock *)lock {
    @synchronized(self) {
        _hostFd = fd;
        _hostLock = lock;
    }
}

- (void)setVideoReliable:(BOOL)reliable {
    @synchronized(self) {
        _videoReliable = reliable;
        _loggedMJPEGFallback = NO;
        _loggedReliableVideoFailure = NO;
    }
}

- (BOOL)startOnPort:(uint16_t)port {
    _port = port;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 2) != 0) {
        close(fd);
        return NO;
    }
    _listenFd = fd;
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    NSLog(@"[ioscpyd] frame channel listening on 127.0.0.1:%u", port);
    return YES;
}

- (void)acceptLoop {
    while (1) {
        int client = accept(_listenFd, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            usleep(100 * 1000);
            continue;
        }
        int yes = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

        [_writeLock lock];
        if (_tweakFd >= 0) {
            close(_tweakFd);
        }
        _tweakFd = client;
        [_writeLock unlock];

        NSLog(@"[ioscpyd] tweak attached to frame channel");
        [self readFramesFrom:client];

        [_writeLock lock];
        if (_tweakFd == client) {
            _tweakFd = -1;
        }
        [_writeLock unlock];
        close(client);
        NSLog(@"[ioscpyd] tweak detached from frame channel");
    }
}

- (void)readFramesFrom:(int)fd {
    IOSPYFrameHeader header;
    while (1) {
        // Drain the per-frame payload each iteration so this hot read loop
        // doesn't pile up memory and get the daemon jetsam-killed.
        @autoreleasepool {
            NSData *payload = nil;
            if (!IOSPYReadFrame(fd, &header, &payload)) {
                break;
            }
            if (header.type == IOSPYMsgVideoFrame && payload.length > 0) {
                BOOL requestedReliable;
                @synchronized(self) {
                    requestedReliable = _videoReliable;
                }
                BOOL actualH264 = IOSPYVideoPayloadIsH264(payload);
                if (requestedReliable && actualH264) {
                    // H.264: send every frame to the host in order. A blocking
                    // write backpressures the tweak's encoder instead of dropping
                    // a frame, which would corrupt the inter-frame stream.
                    //
                    // This holds the shared host write lock for the whole send, so
                    // a slow host can briefly delay a PONG. In practice H.264 frames
                    // are tiny (a few KB) and fit the socket buffer, so the write
                    // returns right away. Only a host that has truly stopped reading
                    // blocks here, and that case should just drop and reconnect. A
                    // separate video socket would remove the coupling, but that's
                    // for later.
                    int hostFd;
                    NSLock *hostLock;
                    @synchronized(self) {
                        hostFd = _hostFd;
                        hostLock = _hostLock;
                    }
                    if (hostFd >= 0 && hostLock) {
                        [hostLock lock];
                        BOOL ok = IOSPYWriteFrame(hostFd, IOSPYMsgVideoFrame,
                                                 IOSPY_CHANNEL_VIDEO, 0, payload);
                        [hostLock unlock];
                        if (!ok) {
                            BOOL shouldLog = NO;
                            @synchronized(self) {
                                if (!_loggedReliableVideoFailure) {
                                    _loggedReliableVideoFailure = YES;
                                    shouldLog = YES;
                                }
                            }
                            if (shouldLog) {
                                NSLog(@"[ioscpyd] reliable H.264 video write failed");
                            }
                        }
                    }
                } else if (requestedReliable) {
                    // The host asked for H.264, but the tweak fell back to MJPEG
                    // (JPEG frames have no H.264 flag). Do not run these large
                    // frames through the reliable/blocking H.264 path. Put them
                    // into the latest-frame store; the pump forwards them
                    // non-blocking/droppable just like a native MJPEG stream.
                    BOOL shouldLog = NO;
                    @synchronized(self) {
                        if (!_loggedMJPEGFallback) {
                            _loggedMJPEGFallback = YES;
                            shouldLog = YES;
                        }
                    }
                    if (shouldLog) {
                        NSLog(@"[ioscpyd] H.264 request is producing MJPEG; using latest-frame forwarding");
                    }
                    [[IOSPYFrameStore shared] setPayload:payload];
                } else {
                    // MJPEG: keep only the latest frame, the pump drops stale ones.
                    [[IOSPYFrameStore shared] setPayload:payload];
                }
            } else if (header.type == IOSPYMsgClipboardChanged) {
                // Relay tweak->host (e.g. device clipboard changed) on the host's
                // control socket, serialized with the video pump's writes.
                int hostFd;
                NSLock *hostLock;
                @synchronized(self) {
                    hostFd = _hostFd;
                    hostLock = _hostLock;
                }
                if (hostFd >= 0 && hostLock) {
                    [hostLock lock];
                    // Non-blocking: a clipboard frame is best-effort, not worth
                    // stalling the ingest thread (and the tweak behind it) over.
                    IOSPYTryWriteFrame(hostFd, IOSPYMsgClipboardChanged, IOSPY_CHANNEL_CONTROL, 0,
                                       payload);
                    [hostLock unlock];
                }
            }
        }
    }
}

- (BOOL)tweakConnected {
    [_writeLock lock];
    BOOL connected = _tweakFd >= 0;
    [_writeLock unlock];
    return connected;
}

- (void)tellTweakStartPayload:(NSData *)payload {
    [_writeLock lock];
    if (_tweakFd >= 0) {
        IOSPYWriteFrame(_tweakFd, IOSPYMsgStartStream, IOSPY_CHANNEL_CONTROL, 0, payload);
    }
    [_writeLock unlock];
}

- (void)tellTweakStop {
    [self sendToTweak:IOSPYMsgStopStream];
}

- (void)sendToTweak:(IOSPYMessageType)type {
    [_writeLock lock];
    if (_tweakFd >= 0) {
        IOSPYWriteFrame(_tweakFd, type, IOSPY_CHANNEL_CONTROL, 0, nil);
    }
    [_writeLock unlock];
}

- (void)forwardToTweak:(uint16_t)type payload:(NSData *)payload {
    [_writeLock lock];
    if (_tweakFd >= 0) {
        IOSPYWriteFrame(_tweakFd, (IOSPYMessageType)type, IOSPY_CHANNEL_CONTROL, 0, payload);
    }
    [_writeLock unlock];
}

@end
