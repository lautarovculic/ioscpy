# Architecture

ioscpy consists of two halves connected over a USB forwarded socket: a host on
macOS and a set of components on the device.

## Host (macOS, Rust)

The host is a single `ioscpy` binary. It discovers attached devices, manages the USB
forwarding, implements the wire protocol, renders the screen, and forwards input. Its
modules correspond to distinct responsibilities:

- `device`: enumeration and selection of devices through libimobiledevice.
- `usbmux`: establishment and teardown of the USB port forward.
- `protocol`: the frame codec, the handshake, and the capability map.
- `health`: connection state and the capability report.
- `video`, `window`, `input`, `keyboard`, `clipboard`: the interactive session,
  layered on top of the transport.

## Device (iOS, Theos)

The device side comprises three components, each with a single responsibility:

- `ioscpyd`: the root daemon, started by launchd. It owns the loopback socket, the
  handshake, the capability map, and command routing. It performs no UI work.
- `ioscpyhook`: the tweak injected into SpringBoard. It performs the privileged
  interactions: touch and key injection, pasteboard access, system actions, and
  orientation tracking.
- `ioscpyctl`: a small root helper for status, diagnostics, and maintenance.

All knowledge of a specific jailbreak is confined to `jbcompat`. It resolves the
filesystem prefix and detects the layout and injection framework; every other
component derives its paths and capabilities from it.

## Flow

```text
ioscpy: discover the device, forward localhost:N to device:27183
        HELLO and HELLO_ACK (capability map, session token)
        AUTHENTICATE (echo the token), then start the stream, send input, sync clipboard
device: ioscpyd routes commands to ioscpyhook, which injects them.
```

## Transport and protocol

A single TCP connection over usbmux carries two multiplexed channels, control and
video. The daemon binds the loopback interface only and exposes no public listener.
The host must echo the session token before the daemon honors any input. The framing
and message numbers are specified under `protocol/`.
