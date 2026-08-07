# ioscpy dream 0.3 native app

Version 0.3 replaces the minifb host UI with a macOS 26 SwiftUI/AppKit app. The
legacy Rust host remains in the repository only as protocol regression coverage;
release artifacts contain the native app.

## Release target

- iPhone 14 Pro, iOS 16.0.2, roothide + ElleKit
- Apple Silicon Mac, macOS 26
- one active iPhone session, with multiple saved device profiles
- USB or same-LAN selected explicitly by the user; LAN control stays on TCP and
  encoded video uses a dedicated low-latency UDP channel with one-fragment XOR
  recovery and automatic TCP fallback when UDP is unreachable

## Mac architecture

```text
Network/usbmux bytes
  -> protocol v5 demultiplexer
  -> VideoToolbox H.264/HEVC hardware decoder
  -> CVPixelBuffer
  -> Core Image Metal context
  -> MTKView drawable
```

The display path never converts the full frame to a CPU RGB array. The mirror
view implements `NSTextInputClient`, so Chinese composition and candidate
selection finish on macOS and only committed UTF-8 text reaches the phone.

The native UI provides a persistent home page, multi-device profiles, fixed
aspect-ratio resizing, automatic orientation changes, an optional device shell,
always-on-top mode, and a hover-only material toolbar. Settings are stored under
`~/Library/Application Support/ioscpy/` with mode `0600`.

## Device architecture

The root daemon is also the low-power LAN listener. While idle it blocks in
`accept()` and performs no screen capture, video encoding, audio capture, polling,
or recurring disk writes. SpringBoard starts expensive modules only after an
authenticated session requests them.

The 30-day LAN trust flow uses a four-digit, 120-second presence code followed by
a 256-bit random token. Five wrong codes trigger a ten-minute cooldown. The
four-digit code is not used as the long-term credential.

## Experimental device features

These features compile into the test package but require the target phone to
establish actual private-API behavior:

- full physical display off while CARenderServer capture remains active;
- physical touch/button wake while synthetic remote events remain dark;
- safe passcode entry through the iOS 16 lock screen;
- ReplayKit system-playback capture from SpringBoard and local-output muting;
- sustained native-resolution HEVC at 120 FPS.

Failure of any one of these modules must not disable basic video or input. The
display is restored and audio capture is stopped on disconnect. The emergency
device-side recovery command is:

```sh
ioscpyctl display-restore
```

## Build

```sh
scripts/build-macos-app.sh dist/macos
make device-rootless
```

The GitHub Actions `Build` workflow produces:

- `ioscpy-macos-app`
- `ioscpy-device-rootless`
- `ioscpy-device-rootful`
- `ioscpy-dream-complete`

The Mac bundle is ad-hoc signed only. It is not Developer ID signed or notarized.
USB mode currently expects `idevice_id` and `iproxy` from libimobiledevice.

## Device validation order

1. Install the rootless package and run `sbreload`.
2. Confirm `ioscpyctl status` reports protocol 5 and version 0.3.0-dream.7.
3. Open the Mac app and validate USB video/input before enabling LAN.
4. Test Chinese text and precise trackpad scrolling.
5. Test HEVC 120 FPS and record device/host telemetry.
6. Pair LAN using the displayed four-digit code, disconnect Wi-Fi, and validate
   the reconnect ladder after restoring Wi-Fi.
7. Test audio with an ordinary video or music app, not a call.
8. Test black-screen mode last, with SSH available for `display-restore`.

No experimental capability is considered validated merely because CI compiles
it. Real-device results determine whether it remains enabled in the next build.

## dream.7 performance diagnostics

`0.3.0-dream.7` is intentionally a measurement build. It does not change the
user's selected resolution, frame rate, codec, or bitrate. Its purpose is to
separate capture, encoder, transport, decode, render, and input latency before
the next performance change.

The Mac app persists newline-delimited JSON diagnostics to:

```text
~/Library/Logs/ioscpy/latest.log
```

The previous non-empty `latest.log` is archived on the next launch as
`ioscpy-YYYYMMDD-HHmmss.log`; the newest 12 archives are retained. The same file
is available from the macOS menu `诊断 -> 在 Finder 中显示最新日志`.

The log contains the iPhone/tweak telemetry relayed through the daemon, so a
normal performance report does not require a separate SpringBoard log. Important
measurements include:

- device capture/encode/send FPS and p50/p95/p99/max stage times;
- capture timer gaps and encoder/send queue pressure;
- SpringBoard main-queue wait and HID injection time for touch events;
- daemon UDP fragmentation/send time and local `sendmsg` failures;
- Mac receive frame gaps, decode-queue wait, VideoToolbox decode latency,
  decoded-frame age at render, and render-submit time;
- LAN frame assembly p50/p95/p99/max, packet-gap jitter, FEC recovery, loss, and
  late-frame counts;
- Mac realtime input write completion p50/p95/p99 and control RTT.

For a useful trace, run one 60-second USB session and one 60-second LAN session:
10 seconds mostly idle, 30 seconds of rapid swipes/scrolling, then 20 seconds
mostly idle. Quit the app normally after each run so the final records are
flushed, then attach `latest.log` (or the archived log after the next launch).
