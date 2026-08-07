#import "FrameIngest.h"
#import "FrameStore.h"
#import "Protocol.h"

#import <sys/socket.h>
#import <sys/uio.h>
#import <netinet/in.h>
#import <netinet/ip.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <stdlib.h>
#import <mach/mach_time.h>

static const uint32_t kIOSPYLANVideoMagic = 0x49554450u; // "IUDP"
static const uint8_t kIOSPYLANVideoVersion = 2;
static const uint8_t kIOSPYLANVideoParityFlag = 0x01;
// Standard IPv4 LAN MTU is 1500. 1400 data + 32 app + 28 UDP/IP = 1460,
// avoiding IP fragmentation while keeping packet rate lower at 120 FPS.
static const size_t kIOSPYLANVideoFragmentPayload = 1400;
// Keep FEC useful without turning 60 Mbps video into a packet-rate amplifier.
// dream.8 used 12/4 and synchronous userspace pacing. On the target device the
// pacing waits routinely overslept by tens of milliseconds, blocked the
// tweak->daemon ingest loop and caused heavy send-pressure drops.
static const size_t kIOSPYLANVideoFECGroup = 16;
static const size_t kIOSPYLANVideoKeyframeFECGroup = 8;
static const NSUInteger kIOSPYUDPTelemetrySamples = 256;

static int compareUDPMetricDouble(const void *a, const void *b) {
    double lhs = *(const double *)a;
    double rhs = *(const double *)b;
    return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
}

static double udpMetricPercentile(const double *samples, NSUInteger writes, double q) {
    NSUInteger count = MIN(writes, kIOSPYUDPTelemetrySamples);
    if (!samples || count == 0) return 0;
    double copy[kIOSPYUDPTelemetrySamples];
    memcpy(copy, samples, sizeof(double) * count);
    qsort(copy, count, sizeof(double), compareUDPMetricDouble);
    q = fmin(1.0, fmax(0.0, q));
    NSUInteger index = (NSUInteger)llround((double)(count - 1) * q);
    return copy[MIN(index, count - 1)];
}

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint8_t version;
    uint8_t flags;
    uint16_t headerSize;
    uint64_t token;
    uint32_t frameSequence;
    uint32_t frameLength;
    uint16_t fragmentIndex;
    uint16_t fragmentCount;
    uint16_t payloadLength;
    uint16_t reserved;
} IOSPYLANVideoHeader;

static_assert(sizeof(IOSPYLANVideoHeader) == 32, "LAN video header must remain 32 bytes");

@implementation IOSPYFrameIngest {
    uint16_t _port;
    int _listenFd;
    int _tweakFd;       // -1 when no tweak is connected
    NSLock *_writeLock; // guards _tweakFd and writes to it
    int _hostFd;        // the control server's host socket, -1 when none
    NSLock *_hostLock;  // the control server's per-connection write lock
    BOOL _videoReliable; // YES while an inter-frame H.264/HEVC stream is active
    int _udpFd;
    struct sockaddr_in _udpPeer;
    uint64_t _udpToken;
    uint32_t _udpFrameSequence;
    NSLock *_udpLock;
    CFAbsoluteTime _lastUDPKeyframeRequestTime;
    uint64_t _udpTelemetryFrames;
    uint64_t _udpTelemetryDatagrams;
    uint64_t _udpTelemetryFailures;
    uint64_t _udpTelemetryBytes;
    uint64_t _udpTelemetryFECDatagrams;
    double _udpTelemetryPacedMsTotal;
    double _udpTelemetrySendMsTotal;
    double _udpTelemetrySendMsMax;
    double _udpTelemetrySendMsSamples[kIOSPYUDPTelemetrySamples];
    NSUInteger _udpTelemetrySendMsWrites;
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
        _udpFd = -1;
        _udpLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)setLANVideoPeerAddress:(uint32_t)addressNetworkOrder
                           port:(uint16_t)portHostOrder
                          token:(uint64_t)token {
    [_udpLock lock];
    if (_udpFd >= 0) {
        close(_udpFd);
        _udpFd = -1;
    }
    memset(&_udpPeer, 0, sizeof(_udpPeer));
    _udpToken = 0;
    _udpFrameSequence = 0;
    if (portHostOrder > 0 && token != 0) {
        int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd >= 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags >= 0) {
                fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            }
            int sndbuf = 8 * 1024 * 1024;
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
#if defined(SO_NET_SERVICE_TYPE) && defined(NET_SERVICE_TYPE_VI)
            int serviceType = NET_SERVICE_TYPE_VI;
            setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, sizeof(serviceType));
#endif
            int tos = IPTOS_LOWDELAY;
            setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
            _udpPeer.sin_family = AF_INET;
            _udpPeer.sin_addr.s_addr = addressNetworkOrder;
            _udpPeer.sin_port = htons(portHostOrder);
            _udpToken = token;
            _udpFd = fd;
            NSLog(@"[ioscpyd] LAN video UDP bound to %@:%u",
                  [NSString stringWithUTF8String:inet_ntoa(_udpPeer.sin_addr)],
                  portHostOrder);
        }
    }
    [_udpLock unlock];
}

- (BOOL)hasLANVideoPeer {
    [_udpLock lock];
    BOOL active = _udpFd >= 0 && _udpToken != 0;
    [_udpLock unlock];
    return active;
}

- (BOOL)sendLANVideoFrame:(NSData *)frame {
    if (frame.length == 0 || frame.length > UINT32_MAX) {
        return NO;
    }
    CFAbsoluteTime sendStartedAt = CFAbsoluteTimeGetCurrent();
    [_udpLock lock];
    if (_udpFd < 0 || _udpToken == 0) {
        [_udpLock unlock];
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)frame.bytes;
    size_t frameLength = frame.length;
    size_t fragmentCountSize =
        (frameLength + kIOSPYLANVideoFragmentPayload - 1) / kIOSPYLANVideoFragmentPayload;
    if (fragmentCountSize == 0 || fragmentCountSize > UINT16_MAX) {
        [_udpLock unlock];
        return NO;
    }
    uint16_t fragmentCount = (uint16_t)fragmentCountSize;
    uint32_t sequence = ++_udpFrameSequence;
    __block int localSendFailures = 0;

    uint32_t videoFlags = 0;
    if (frameLength >= 12) {
        uint32_t flagsBE = 0;
        memcpy(&flagsBE, bytes + 8, sizeof(flagsBE));
        videoFlags = ntohl(flagsBE);
    }
    BOOL keyframe = (videoFlags & IOSPY_VIDEO_FLAG_KEYFRAME) != 0;
    size_t fecGroupSize = keyframe ? kIOSPYLANVideoKeyframeFECGroup
                                   : kIOSPYLANVideoFECGroup;
    size_t groupCount = (fragmentCountSize + fecGroupSize - 1) / fecGroupSize;
    // Do not sleep between UDP groups here. This method runs synchronously on
    // the daemon frame-ingest path; dream.8's mach_wait_until() pacing turned a
    // nominal 6/12 ms spread into 30-100+ ms frame-send stalls under load,
    // backpressuring the local tweak socket and collapsing source FPS.
    double pacedWaitMs = 0;

    BOOL (^sendDatagram)(uint8_t, uint16_t, uint16_t, const void *, size_t) =
        ^BOOL(uint8_t packetFlags, uint16_t fragmentIndex, uint16_t parityGroupCount,
              const void *payloadBytes, size_t payloadLength) {
        IOSPYLANVideoHeader header = {};
        header.magic = htonl(kIOSPYLANVideoMagic);
        header.version = kIOSPYLANVideoVersion;
        header.flags = packetFlags;
        header.headerSize = htons((uint16_t)sizeof(header));
        header.token = CFSwapInt64HostToBig(_udpToken);
        header.frameSequence = htonl(sequence);
        header.frameLength = htonl((uint32_t)frameLength);
        header.fragmentIndex = htons(fragmentIndex);
        header.fragmentCount = htons(fragmentCount);
        header.payloadLength = htons((uint16_t)payloadLength);
        header.reserved = htons(parityGroupCount);

        struct iovec iov[2] = {
            {&header, sizeof(header)},
            {(void *)payloadBytes, payloadLength},
        };
        struct msghdr message = {};
        message.msg_name = &_udpPeer;
        message.msg_namelen = sizeof(_udpPeer);
        message.msg_iov = iov;
        message.msg_iovlen = 2;
        ssize_t sent = sendmsg(_udpFd, &message, MSG_DONTWAIT);
        if (sent < 0) {
            localSendFailures++;
            _udpTelemetryFailures++;
            return NO;
        } else {
            _udpTelemetryDatagrams++;
            _udpTelemetryBytes += (uint64_t)sent;
            if ((packetFlags & kIOSPYLANVideoParityFlag) != 0) {
                _udpTelemetryFECDatagrams++;
            }
            return YES;
        }
    };

    for (size_t group = 0; group < groupCount; group++) {
        size_t groupStart = group * fecGroupSize;
        size_t groupEnd = MIN(fragmentCountSize, groupStart + fecGroupSize);
        uint16_t parityDataCount = (uint16_t)(groupEnd - groupStart);
        uint8_t parity[kIOSPYLANVideoFragmentPayload] = {};

        for (size_t rawIndex = groupStart; rawIndex < groupEnd; rawIndex++) {
            uint16_t index = (uint16_t)rawIndex;
            size_t offset = rawIndex * kIOSPYLANVideoFragmentPayload;
            size_t length = MIN(kIOSPYLANVideoFragmentPayload, frameLength - offset);
            for (size_t i = 0; i < length; i++) {
                parity[i] ^= bytes[offset + i];
            }
            sendDatagram(0, index, 0, bytes + offset, length);
        }

        // One XOR parity per small group repairs one loss in every 4 keyframe
        // fragments (or every 12 P-frame fragments), dramatically improving IDR
        // recovery without retransmission/jitter buffering.
        sendDatagram(kIOSPYLANVideoParityFlag, (uint16_t)groupStart,
                     parityDataCount, parity, sizeof(parity));

    }

    double sendMs = (CFAbsoluteTimeGetCurrent() - sendStartedAt) * 1000.0;
    _udpTelemetryFrames++;
    _udpTelemetryPacedMsTotal += pacedWaitMs;
    _udpTelemetrySendMsTotal += sendMs;
    _udpTelemetrySendMsMax = MAX(_udpTelemetrySendMsMax, sendMs);
    _udpTelemetrySendMsSamples[_udpTelemetrySendMsWrites % kIOSPYUDPTelemetrySamples] = sendMs;
    _udpTelemetrySendMsWrites++;

    [_udpLock unlock];
    // Local EAGAIN/ENOBUFS means the kernel queue itself was pressured. Group FEC
    // may repair it, but request a fresh IDR conservatively rather than assuming
    // which parity group was affected.
    return localSendFailures == 0;
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

- (NSData *)augmentStatsPayloadWithDaemonTelemetry:(NSData *)payload {
    NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![raw isKindOfClass:[NSDictionary class]]) {
        return payload;
    }
    NSMutableDictionary *augmented = [raw mutableCopy];
    double udpAvg = _udpTelemetryFrames
        ? _udpTelemetrySendMsTotal / (double)_udpTelemetryFrames : 0;
    augmented[@"daemon_udp"] = @{
        @"active": @([self hasLANVideoPeer]),
        @"frames": @(_udpTelemetryFrames),
        @"datagrams": @(_udpTelemetryDatagrams),
        @"send_failures": @(_udpTelemetryFailures),
        @"bytes": @(_udpTelemetryBytes),
        @"fec_datagrams": @(_udpTelemetryFECDatagrams),
        @"paced_wait_ms": @(_udpTelemetryPacedMsTotal),
        @"frame_send_ms_avg": @(udpAvg),
        @"frame_send_ms_p95": @(udpMetricPercentile(
            _udpTelemetrySendMsSamples, _udpTelemetrySendMsWrites, 0.95)),
        @"frame_send_ms_p99": @(udpMetricPercentile(
            _udpTelemetrySendMsSamples, _udpTelemetrySendMsWrites, 0.99)),
        @"frame_send_ms_max": @(_udpTelemetrySendMsMax),
    };
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:augmented options:0 error:nil];

    _udpTelemetryFrames = 0;
    _udpTelemetryDatagrams = 0;
    _udpTelemetryFailures = 0;
    _udpTelemetryBytes = 0;
    _udpTelemetryFECDatagrams = 0;
    _udpTelemetryPacedMsTotal = 0;
    _udpTelemetrySendMsTotal = 0;
    _udpTelemetrySendMsMax = 0;
    _udpTelemetrySendMsWrites = 0;
    return encoded ?: payload;
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
                if ([self hasLANVideoPeer]) {
                    // LAN media is intentionally unreliable/latest-first. Never
                    // fall back to the control TCP stream after a UDP send miss:
                    // doing so would reintroduce head-of-line stalls exactly when
                    // Wi-Fi is under pressure. The Mac requests a fresh IDR when
                    // it detects an unrecoverable sequence gap.
                    if (![self sendLANVideoFrame:payload]) {
                        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                        if (now - _lastUDPKeyframeRequestTime >= 0.5) {
                            _lastUDPKeyframeRequestTime = now;
                            [self sendToTweak:IOSPYMsgRequestKeyframe];
                        }
                    }
                    continue;
                }
                BOOL reliable;
                @synchronized(self) {
                    reliable = _videoReliable;
                }
                if (reliable) {
                    // H.264/HEVC: send every frame to the host in order. A blocking
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
                        int rc = IOSPYTryWriteFrame(hostFd, IOSPYMsgVideoFrame,
                                                    IOSPY_CHANNEL_VIDEO, 0, payload);
                        [hostLock unlock];
                        if (rc == 0) {
                            // Preserve control responsiveness under Wi-Fi/host
                            // backpressure. Dropping an inter-frame requires a
                            // fresh keyframe before useful decoding can resume.
                            [self sendToTweak:IOSPYMsgRequestKeyframe];
                        } else if (rc < 0) {
                            break;
                        }
                    }
                } else {
                    // MJPEG: keep only the latest frame, the pump drops stale ones.
                    [[IOSPYFrameStore shared] setPayload:payload];
                }
            } else if (header.type == IOSPYMsgClipboardChanged ||
                       header.type == IOSPYMsgStats ||
                       header.type == IOSPYMsgAudioFrame) {
                // Relay tweak->host control events and periodic telemetry on the
                // host socket, serialized with the video pump's writes.
                int hostFd;
                NSLock *hostLock;
                @synchronized(self) {
                    hostFd = _hostFd;
                    hostLock = _hostLock;
                }
                if (hostFd >= 0 && hostLock) {
                    NSData *relayPayload = header.type == IOSPYMsgStats
                        ? [self augmentStatsPayloadWithDaemonTelemetry:payload]
                        : payload;
                    [hostLock lock];
                    // Non-blocking: clipboard and telemetry are best-effort and
                    // must never stall the tweak's capture path.
                    uint64_t channel = header.type == IOSPYMsgAudioFrame
                        ? IOSPY_CHANNEL_AUDIO : IOSPY_CHANNEL_CONTROL;
                    IOSPYTryWriteFrame(hostFd, (IOSPYMessageType)header.type,
                                       channel, 0, relayPayload);
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
        IOSPYWriteFrame(_tweakFd, IOSPYMsgStartStream, IOSPY_CHANNEL_CONTROL, 0,
                        payload ?: [NSData data]);
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
