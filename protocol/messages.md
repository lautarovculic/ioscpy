# ioscpy Messages

This document mirrors the `MessageType` enum and defines each message payload. It
must stay in lockstep with `host/src/protocol.rs` and
`device/daemon/Protocol.{h,mm}`. Wire values are stable: an existing message is
never renumbered, and new messages are only appended.

## Message types (`type` field, u16)

| name                   | value | dir   | channel | payload      |
|------------------------|-------|-------|---------|--------------|
| HELLO                  | 1     | H→D   | control | JSON         |
| HELLO_ACK              | 2     | D→H   | control | JSON         |
| CAPABILITIES_REQUEST   | 3     | H→D   | control | (empty)      |
| CAPABILITIES_RESPONSE  | 4     | D→H   | control | JSON         |
| AUTHENTICATE           | 5     | H→D   | control | UTF-8 token  |
| START_STREAM           | 10    | H→D   | control | binary(opt)  |
| STOP_STREAM            | 11    | H→D   | control | (empty)      |
| VIDEO_FRAME            | 12    | D→H   | video   | binary       |
| REQUEST_KEYFRAME       | 13    | H→D   | control | (empty)      |
| INPUT_TOUCH            | 20    | H→D   | control | binary       |
| INPUT_KEY              | 21    | H→D   | control | binary       |
| INPUT_TEXT             | 22    | H→D   | control | UTF-8 text   |
| CLIPBOARD_GET          | 30    | H→D   | control | (empty)      |
| CLIPBOARD_SET          | 31    | H→D   | control | binary       |
| CLIPBOARD_CHANGED      | 32    | D→H   | control | binary       |
| ORIENTATION_CHANGED    | 40    | D→H   | control | JSON         |
| SCREEN_INFO            | 41    | D→H   | control | JSON         |
| SYSTEM_ACTION          | 50    | H→D   | control | binary(u16)  |
| KEYBOARD_MODE          | 51    | H→D   | control | binary(u8)   |
| PING                   | 60    | both  | control | (empty)      |
| PONG                   | 61    | both  | control | (empty)      |
| ERROR                  | 70    | D→H   | control | JSON         |
| LOG                    | 71    | D→H   | control | JSON         |

In the `dir` column, H→D denotes host to daemon and D→H denotes daemon to host.

`CLIPBOARD_GET` (30), `ORIENTATION_CHANGED` (40), and `SCREEN_INFO` (41) are
reserved. Their numbers are fixed, but nothing emits them yet. Clipboard
synchronization is push based (`CLIPBOARD_SET` and `CLIPBOARD_CHANGED`), so the
host never polls, and orientation is carried in the video frame flags rather than
as a separate message.

## Streaming

### START_STREAM (host to daemon)

The payload is an optional one byte codec selector:

```text
0x00  MJPEG
0x01  H.264
```

An empty payload is treated as MJPEG, so an older host still receives a picture.
The daemon honors H.264 only if it advertised `h264` in `stream_backends`.
Otherwise it falls back to MJPEG, and the host follows the per frame codec flag.

### VIDEO_FRAME (daemon to host), binary

The payload is a 16 byte big-endian sub-header followed by the encoded bytes:

| field   | offset | size | meaning                                  |
|---------|--------|------|------------------------------------------|
| width   | 0      | 4    | encoded frame width in pixels            |
| height  | 4      | 4    | encoded frame height in pixels           |
| flags   | 8      | 4    | bitfield (below)                         |
| length  | 12     | 4    | byte length of the encoded data          |
| data    | 16     | length | JPEG, or H.264 in AVCC form            |

The `flags` bits are:

```text
bit 0   H264       data is H.264 (AVCC, 4 byte length prefixed NALs); clear = JPEG
bit 1   KEYFRAME   H.264 keyframe (IDR), decodable on its own
bit 2   CONFIG     SPS/PPS parameter sets are prepended to data (AVCC NALs)
```

A plain JPEG frame leaves all flag bits at 0. H.264 is stateful, so the host must
feed frames to the decoder in order and must not drop them.

### REQUEST_KEYFRAME (host to daemon)

Empty payload. It asks the encoder to emit a keyframe with fresh SPS/PPS on the
next frame. The host uses it on connect and to recover after a decode gap.

## Input

### INPUT_TOUCH (host to daemon), binary, 10 bytes

| field | offset | size | meaning                      |
|-------|--------|------|------------------------------|
| phase | 0      | 1    | 0 down, 1 move, 2 up         |
| id    | 1      | 1    | finger id (0 for the cursor) |
| x     | 2      | 4    | f32 BE, normalized [0, 1]    |
| y     | 6      | 4    | f32 BE, normalized [0, 1]    |

Coordinates are normalized to the device screen, so the host stays independent of
the device resolution and orientation. The tweak maps them to native pixels.

### INPUT_KEY (host to daemon), binary, 1 byte

A single key code byte. The tweak maps each value to a HID usage or a Cmd chord:

| name      | value | name       | value |
|-----------|-------|------------|-------|
| ENTER     | 1     | DOWN       | 8     |
| BACKSPACE | 2     | SELECT_ALL | 10    |
| TAB       | 3     | COPY       | 11    |
| ESCAPE    | 4     | PASTE      | 12    |
| LEFT      | 5     | CUT        | 13    |
| RIGHT     | 6     | UNDO       | 14    |
| UP        | 7     |            |       |

Values 10 through 14 are the macOS editing shortcuts Cmd+A, Cmd+C, Cmd+V, Cmd+X,
and Cmd+Z. Value 9 is unused.

### INPUT_TEXT (host to daemon), UTF-8

The literal characters to type. The Mac has already resolved its keyboard layout,
so the payload is layout independent. The tweak injects ASCII as HID key events
and routes anything else, such as accents and emoji, through the clipboard paste
path.

### KEYBOARD_MODE (host to daemon), binary, 1 byte

Payload `[suppress:u8]`. A non-zero value hides the on-screen software keyboard:
the device behaves as if a hardware keyboard is attached, so the focused field
stays focused and typed HID input still lands. A zero value restores it. The
setting is bound to the session. The device also restores the keyboard if the host
disconnects for any reason, so it cannot be left hidden. This applies to iOS 16 and
later. It is a no-op on iOS 15, which has no such mode.

## System actions (`SYSTEM_ACTION` payload, u16 big-endian)

| name         | value | status   |
|--------------|-------|----------|
| HOME         | 1     | live     |
| LOCK         | 2     | live     |
| WAKE         | 3     | live     |
| APP_SWITCHER | 4     | live     |
| ROTATE_LEFT  | 5     | reserved |
| ROTATE_RIGHT | 6     | reserved |
| SCREENSHOT   | 7     | reserved |
| BACK         | 8     | live     |

Actions marked `live` are handled by the tweak today. Values marked `reserved` are
fixed wire numbers that the tweak does not act on yet. `BACK` is the action sent by
the host Esc key. The device performs it with Cmd+[, which UIKit treats as the
navigation controller pop and WebKit treats as a web back, routed to the focused
app. It therefore needs no touch and works before any physical tap.

## Clipboard

`CLIPBOARD_SET` (host to device) and `CLIPBOARD_CHANGED` (device to host) both
carry `[flags:u8][utf8 text]`:

- `CLIPBOARD_SET`: `flags` bit 0 requests a paste after setting (inject Cmd+V). It
  is used for cross device paste and for typing characters that cannot ride HID.
- `CLIPBOARD_CHANGED`: `flags` is 0. The device pushes this when its pasteboard
  changes.

To prevent loops, each side records the FNV-1a/64 hash of the last value it synced
(byte identical on both ends) and ignores a change whose hash it already holds.

## Handshake

### HELLO (host to daemon), JSON

```json
{
  "role": "host",
  "host_version": "0.1.5",
  "protocol_version": 4,
  "nonce": "<hex>"
}
```

### HELLO_ACK (daemon to host), JSON

Carries the daemon version, a per connection session token, and the capability
map. The host selects backends from `capabilities` and must return `session_token`
in an `AUTHENTICATE` frame before any privileged message is honored (see below).

```json
{
  "daemon_version": "0.1.5",
  "protocol_version": 4,
  "session_token": "<hex>",
  "capabilities": {
    "ios_version": "16.7.10",
    "device_model": "iPhone10,3",
    "jailbreak_layout": "rootless",
    "jb_prefix": "/var/jb",
    "injection_framework": "ElleKit",
    "daemon_uid": 0,
    "stream_backends": ["h264", "mjpeg"],
    "input_backends": ["iohid"],
    "clipboard": true,
    "keyboard": true,
    "orientation": false
  }
}
```

Capabilities reflect what is wired up at that moment, not a target state, and the
host must not assume a capability that is absent. The tweak dependent entries
(`stream_backends`, `input_backends`, `clipboard`, `keyboard`) are populated only
while the `ioscpyhook` tweak is attached. Before that they are empty or false, and
the host warns. `stream_backends` lists the preferred codec first (`h264`).

### AUTHENTICATE (host to daemon), UTF-8

The `session_token` string from HELLO_ACK, returned verbatim. The daemon binds the
token to the accepted connection and marks it authenticated only on a byte exact
match. A mismatch is answered with a fatal `BAD_TOKEN` error and the connection is
closed. The host sends this immediately after the handshake, so it accompanies
every connect. Messages that do not actuate the device (ping, capabilities, stream
start and stop, keyframe requests) are accepted without it. The privileged set
described below is not.

## Errors

Every recoverable error carries:

```json
{
  "code": "TWEAK_UNAVAILABLE",
  "component": "ioscpyhook",
  "fatal": false,
  "message": "Video stream is available, but input injection is unavailable.",
  "suggestion": "Respring or reinstall the device package."
}
```

## Version negotiation

- The major `protocol_version` must match.
- A minor mismatch is allowed only if capability negotiation succeeds.
- If the host is newer than the daemon, it offers an update. If the daemon is newer
  than the host, it warns and continues when the protocol is compatible.

## Session token

The daemon issues a per connection `session_token` in HELLO_ACK, and the host must
return it in an `AUTHENTICATE` (5) frame before the daemon will honor any message
that actuates the device: `INPUT_TOUCH` (20), `INPUT_KEY` (21), `INPUT_TEXT` (22),
`CLIPBOARD_SET` (31), `SYSTEM_ACTION` (50), and `KEYBOARD_MODE` (51). Until then,
those messages are refused with a non-fatal `UNAUTHENTICATED` error and dropped. A
wrong token closes the connection outright with `BAD_TOKEN`.

The token is bound to the accepted socket, so a fresh connection receives a fresh
token, and the daemon serves one control connection at a time. This is a layer of
defense in depth: a peer that did not complete the handshake cannot drive input
even if it reaches the port. The primary boundary remains the loopback bind plus
USB only forwarding (the daemon listens on `127.0.0.1` and is reached over usbmux);
the token does not replace it. Any new privileged handler joins the gated set
above.
