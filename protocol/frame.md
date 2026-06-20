# ioscpy Wire Frame

This document defines the binary framing layer. It is authoritative. Any change
must be reflected in the host (`host/src/protocol.rs`) and the daemon
(`device/daemon/Protocol.{h,mm}`) in the same revision, and must increment
`PROTOCOL_VERSION`.

## Frame header

Every frame begins with a fixed 32 byte header, followed by `length` bytes of
payload. All multibyte integers are big-endian (network byte order).

```c
struct IoscpyFrameHeader {
    uint32_t magic;       // 'ICPY' == 0x49435059
    uint16_t version;     // protocol version (currently 4)
    uint16_t type;        // message type (see messages.md)
    uint32_t flags;       // reserved for compression and encryption (0 for now)
    uint64_t stream_id;   // logical channel (0 = control, 1 = video)
    uint64_t seq;         // monotonic per channel sequence number
    uint32_t length;      // payload length in bytes (may be 0)
};                        // total: 32 bytes
```

Field offsets:

| field      | offset | size |
|------------|--------|------|
| magic      | 0      | 4    |
| version    | 4      | 2    |
| type       | 6      | 2    |
| flags      | 8      | 4    |
| stream_id  | 12     | 8    |
| seq        | 20     | 8    |
| length     | 28     | 4    |
| payload    | 32     | length |

## Constants

```text
MAGIC             = 0x49435059   ("ICPY")
PROTOCOL_VERSION  = 4
HEADER_SIZE       = 32 bytes
DEFAULT_PORT      = 27183        (daemon binds 127.0.0.1:27183 only)
MAX_PAYLOAD       = 16 MiB       (upper bound; larger frames are rejected)
```

## Channels (`stream_id`)

```text
0  control   handshake, capabilities, ping/pong, input, clipboard, system actions, errors, logs
1  video     video frames
```

Both channels are multiplexed over a single TCP connection. Each channel maintains
its own `seq` counter.

## Flags

```text
bit 0   COMPRESSED   payload is compressed (reserved, unused for now)
bit 1   ENCRYPTED    payload is encrypted (reserved, unused for now)
others  reserved, must be 0
```

## Payload encoding

Payloads sent at high frequency (video, input) are compact binary, defined per
message in `messages.md`. The low frequency control and diagnostic payloads
(HELLO, HELLO_ACK, CAPABILITIES, ERROR, LOG) are UTF-8 JSON, which keeps the
handshake and diagnostics readable and easy to inspect.
