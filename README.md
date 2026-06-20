# ioscpy

A macOS CLI that mirrors and controls a jailbroken iPhone over USB.

With one device attached, that is all you need. It connects on its own.

<p align="center">
  <img src="docs/assets/ioscpy-demo.gif" width="720" alt="ioscpy demo">
</p>

## Install

There are two sides. The Mac app runs the mirror, the iPhone package lets the
phone be controlled. Install both.

On the Mac, with Homebrew:

```bash
brew tap lautarovculic/ioscpy   # the Mac app
brew trust lautarovculic/ioscpy
brew install ioscpy
ioscpy --version
```

On the jailbroken iPhone, add this repository in Sileo or Zebra, then install
ioscpy from it and respring:

```text
https://lautarovculic.github.io/ioscpy-repo/
```

The repository carries both rootless and rootful builds, and the package manager
picks the one that matches the jailbreak.

```bash
ioscpy --device <UDID>   # pick a device when several are attached
ioscpy --list            # list attached devices
ioscpy --no-keyboard     # hide the on-screen keyboard, type from the Mac
ioscpy --mjpeg           # force MJPEG video instead of the default H.264
ioscpy --debug           # full diagnostics
ioscpy --version
```

## First touch

> After a respring or a fresh connection, give the phone one physical tap on its
> screen before driving it from the Mac. iOS only trusts touch events that come
> from the real digitizer, so that first real tap is what lets the injected ones
> through. You do it once, then the Mac takes over.

## Controls

- Mouse: click to tap, click and drag to swipe.
- Typing: keystrokes go to the focused field, in any Mac keyboard layout. Accents
  and emoji go through the clipboard.
- Esc: go back.
- Cmd+J, Cmd+L, Cmd+T, Cmd+R: Home, Lock, App Switcher, Rotate.
- Cmd+A, Cmd+C, Cmd+V, Cmd+X, Cmd+Z: Select All, Copy, Paste, Cut, Undo. The
  clipboard syncs both ways, so Cmd+C on the phone reaches the Mac.
- Enter, Backspace, Tab, arrows: the matching editing keys.

Rotating the phone rotates and resizes the mirror.

## Tested devices

ioscpy is developed and tested on the device below. I don't have a rootful device
or other iOS versions on hand, so this table is incomplete.

| layout   | device     | iOS     | injection | status                                          |
|----------|------------|---------|-----------|-------------------------------------------------|
| rootless |            |         |           | scheme builds; runs on the roothide unit via `/var/jb` |
| roothide | iPhone10,3 | 16.7.10 | ElleKit   | working (rootless `.deb` via `/var/jb`)         |
| rootful  |            |         |           | builds and layout validated; runtime not tested |

If you run ioscpy on a different iPhone, iOS version, or jailbreak, please help fill
this in. Rootful and other iOS versions especially need testing.

- If it works, add a row with your device, iOS version, layout, and injection
  framework, and open a pull request.
- If it fails, open an issue with enough detail to fix it:
  - iPhone model and iOS version
  - jailbreak and layout (Dopamine, palera1n rootless or rootful, roothide)
  - injection framework (ElleKit, Substitute, Substrate)
  - the output of `ioscpy --debug`
  - what broke (screen, touch, keyboard, clipboard, install, and so on)

## Layout

```text
host/       Rust macOS CLI
device/     iOS package (Theos): daemon, ctl, tweak, jbcompat, packaging
protocol/   wire format docs, kept in lockstep with the code
scripts/    device deploy, respring, log, and diagnostics helpers
docs/       architecture, jailbreak compatibility, troubleshooting, release
```

## Building

```bash
make host-release        # macOS host binary
make device-rootless     # rootless .deb (Dopamine, palera1n-rootless, /var/jb)
make device-rootful      # rootful .deb (palera1n-rootful, /)
make release             # host plus both device variants
```

Requires Rust, Theos (`$THEOS`), libimobiledevice (`idevice_id`, `iproxy`), `ldid`,
and `dpkg-deb`.

## Scope

ioscpy is for controlling your own jailbroken iPhone from your Mac, over the USB
cable, on the same desk. It runs on macOS and talks to a jailbroken iOS device.
It is not for Linux or Windows, and not for iPhones that are not jailbroken.

## Author

[Lautaro Villarreal Culic'](https://lautarovculic.com) - MIT licensed.
