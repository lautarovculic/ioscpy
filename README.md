# ioscpy

## ToDo
- [ ] Add Authentication & Authorization
- [ ] https://github.com/lautarovculic/ioscpy/issues/4

A macOS and Linux CLI that mirrors and controls a jailbroken iPhone over USB.

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

## Linux

There is no prebuilt for Linux yet. Build the host from source. The device
package is the same as on macOS, installed from the Sileo/Zebra repo above.

Prereqs on Debian/Ubuntu:

```bash
sudo apt install build-essential pkg-config nasm \
                 libimobiledevice-utils usbmuxd \
                 libxkbcommon-dev libwayland-dev \
                 libxcb1-dev libxkbcommon-x11-dev
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Make sure `usbmuxd` is running so the device shows up:

```bash
sudo systemctl enable --now usbmuxd
idevice_id -l   # should print the UDID with the phone attached
```

Build the host as your user, then install:

```bash
make host-release
sudo make install-host    # installs to /usr/local/bin/ioscpy
ioscpy --version
```

## For Arch Linux

```bash
sudo pacman -S --needed \
  base-devel pkgconf nasm \
  libimobiledevice usbmuxd \
  libxkbcommon wayland libxcb libxkbcommon-x11 \
  rustup curl git
```

```bash
rustup default stable
```

Enable the service

```bash
sudo systemctl enable --now usbmuxd.service
```

Check if device is connected

```bash
idevice_id -l
```

Then run the binary

```bash
cd host/target/release && chmod +x ioscpy
```

```bash
./ioscpy
```

The build step stays as your user so a rustup-installed `cargo` is found.
`install-host` is a separate target that just copies the built binary, so it
runs fine under `sudo` without needing `cargo` on root's PATH. For a no-sudo
install in your home, use `make install-host PREFIX=$HOME/.local` and make
sure `$HOME/.local/bin` is on your `PATH`.

H.264 decoding works on Linux through the `openh264` software decoder. Pass
`--mjpeg` if you prefer the MJPEG path.

## Tested on

Hosts:
- Debian, KDE/Wayland
- Ubuntu 26.04, GNOME/Wayland
- Arch Linux, BSPWM

Devices:

| layout | device | iOS | injection |
| --- | --- | --- | --- |
| roothide | iPhone11,2 | 15.5 | ElleKit |
| roothide | iPhone10,4 | 16.7.12 | ElleKit |
| roothide | iPhone10,3 | 16.7.10 | ElleKit |

ioscpy is developed and tested on the devices above. I don't have a rootful device
or every iOS version on hand, so coverage by layout is incomplete:

| layout   | status                                          |
|----------|-------------------------------------------------|
| rootless | builds; runs on the roothide unit via `/var/jb` |
| roothide | working (rootless `.deb` via `/var/jb`)         |
| rootful  | builds and layout validated; runtime not tested |

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
host/       Rust host CLI (macOS and Linux)
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

ioscpy is for controlling your own jailbroken iPhone from your Mac and Linux (Debian) device, over the USB
cable, on the same desk.

For Linux hosts, same external requirement as macOS: libimobiledevice tools (`iproxy`,
  `idevice_id`, `ideviceinfo`) and `usbmuxd`.

It is not for Windows, and not for iPhones that are not jailbroken.

## Author / Contributors

- [Lautaro Villarreal Culic'](https://lautarovculic.com)
- [Moamen Yasser](https://www.linkedin.com/in/ymuu/)
- [Alessio Amatucci](https://github.com/Alexius22)
