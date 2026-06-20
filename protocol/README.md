# ioscpy Protocol

This document set specifies the wire protocol spoken between the macOS host
(`ioscpy`) and the root daemon running on the device (`ioscpyd`). It is the
authoritative reference for the byte layout and the message exchange. The two
implementations, `host/src/protocol.rs` and `device/daemon/Protocol.{h,mm}`, are
expected to conform to it.

## Documents

- `frame.md` defines the fixed 32 byte frame header and the channel model.
- `messages.md` defines the message types, their payloads, the handshake, and the
  error format.

## Invariants

The following properties hold for every connection and must be preserved by any
change to the protocol.

1. The daemon listens on `127.0.0.1:27183` only. There is no public listener. A
   second loopback listener on `127.0.0.1:27184` carries the frame channel between
   the tweak and the daemon.
2. A single TCP connection links the host and the daemon. Two channels are
   multiplexed over it: channel `0` for control and channel `1` for video.
3. Header fields are big-endian. Handshake and diagnostic payloads are JSON. All
   payloads sent at high frequency are binary.
4. Video defaults to H.264, encoded and decoded with VideoToolbox on both ends.
   MJPEG is the automatic fallback. The codec is selected per connection through
   the `START_STREAM` codec byte and the advertised `stream_backends`, and is
   signalled per frame by the `VIDEO_FRAME` codec flag.
5. The daemon issues a per connection session token during the handshake. The host
   must return it in an `AUTHENTICATE` frame before the daemon will honor any
   message that actuates the device (input, clipboard, system actions). The primary
   security boundary remains the loopback bind together with USB only forwarding.
   The token is an additional check, not a replacement for that boundary. See the
   session token section of `messages.md`.
6. `PROTOCOL_VERSION` is `4`. Any change to the wire format increments it and
   updates this document set and both implementations in the same revision.
