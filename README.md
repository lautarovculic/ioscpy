# ioscpy

## ToDo
- [ ] https://github.com/lautarovculic/ioscpy/issues/7
- [ ] Screen Recording (showing status) button in sidepanel.
- [ ] Research: Providing support for Windows with a GUI as well, installer (Reserved, Author will implement this fully)
- [ ] Add Authentication & Authorization, also a notifiation in device that `ioscpy` is running (Reserved, Author will implement this fully)
- [ ] Make `ioscpy` wireless (BLE, Wi-Fi) (Reserved, Author will implement this fully)
- [ ] Custom Buttons Actions (Macros) (In phases, concept coming soon)

A macOS, Linux, and Windows CLI that mirrors and controls a jailbroken iPhone over USB.

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

## Linux

There is no prebuilt for Linux yet. Build the host from source. The device
package is the same as on macOS, installed from the Sileo/Zebra repo above.

Clone this repo, then run the installer:

```bash
./install.sh
```

`--yes` skips the confirmation prompts. `--prefix DIR` installs to `DIR` instead of `/usr/local` and omits `sudo` when the directory is under `$HOME`. `--uninstall` removes the installed binary.

### Manual install

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

`./install.sh` also works on Arch Linux.

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

On Wayland compositors that refuse server-side decorations (GNOME/mutter),
ioscpy automatically falls back to X11/XWayland so the window gets a normal
titlebar. Pass `--wayland` to stay on native Wayland instead.

## Windows

There is no prebuilt for Windows yet. Build the host from source. The device package is the same as on macOS and Linux, installed from the Sileo/Zebra repo.

ioscpy on Windows reuses the USB tooling an iOS setup already has, and does **not** replace any driver, so Frida, objection, grapefruit, ideviceinfo, iTunes, and any other usbmux tool keep working while it runs.

### 1. USB stack

- **Apple Mobile Device Support**: installed with iTunes from apple.com (get the
  Apple-website build, not the Microsoft Store one), or the standalone AMDS
  package. This provides the USB driver and usbmuxd. iTunes must see the phone.
- **libimobiledevice-win32**: provides `iproxy.exe`, `idevice_id.exe`,
  `ideviceinfo.exe`. Install with [Scoop](https://scoop.sh):

      scoop install libimobiledevice

  or with MSYS2:

      pacman -S mingw-w64-x86_64-libimobiledevice

  Make sure the three `.exe` files are on your `PATH` (or drop them next to
  `ioscpy.exe`). Check with `idevice_id -l`, which should print your device UDID.

### 2. Build toolchain

- **Rust** with the MSVC toolchain: install from [rustup.rs](https://rustup.rs).
- **Visual Studio Build Tools** with the C++ workload (the `openh264` decoder
  compiles a small C library through `cc`).
- **nasm** on `PATH`: `openh264`'s assembler (`scoop install nasm`).

### 3. Build and run

    git clone https://github.com/lautarovculic/ioscpy
    cd ioscpy
    cargo build --release --manifest-path host/Cargo.toml
    .\host\target\release\ioscpy.exe --list      # confirms the device is seen
    .\host\target\release\ioscpy.exe             # opens the mirror window

Pass `--mjpeg` if you prefer the MJPEG path over H.264. If `openh264` fails to
build, confirm `nasm` is on `PATH`.

## First touch

> After a respring or a fresh connection, give the phone one physical tap on its
> screen before driving it from the host. iOS only trusts touch events that come
> from the real digitizer, so that first real tap is what lets the injected ones
> through. You do it once, then the host takes over.

## Controls

- Mouse: click to tap, click and drag to swipe.
- Typing: keystrokes go to the focused field, in any Mac keyboard layout. Accents
  and emoji go through the clipboard.
- Esc: go back.
- Cmd+J, Cmd+L, Cmd+T, Cmd+R: Home, Lock, App Switcher, Rotate.
- Cmd+A, Cmd+C, Cmd+V, Cmd+X, Cmd+Z: Select All, Copy, Paste, Cut, Undo. The
  clipboard syncs both ways, so Cmd+C on the phone reaches the Mac.
- Enter, Backspace, Tab, arrows: the matching editing keys.

On Linux and Windows, use **Ctrl** in place of Cmd for these shortcuts (Ctrl+C,
Ctrl+V, and so on); the clipboard still syncs both ways.

Rotating the phone rotates and resizes the mirror.

## Tested on

Hosts:
- Debian, KDE/Wayland
- Ubuntu 26.04, GNOME/Wayland
- Arch Linux, BSPWM
- Windows 11 x64

Devices:

| layout | device | iOS | injection |
| --- | --- | --- | --- |
| roothide | iPhone11,2 | 15.5 | ElleKit |
| roothide | iPhone10,4 | 16.7.12 | ElleKit |
| roothide | iPhone10,3 | 16.7.10 | ElleKit |
| roothide | iPhone14 | 16.3 | ------- |
| rootless | iPhone13 | 15.5 | ElleKit |

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
host/       Rust host CLI (macOS, Linux, and Windows)
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

### Stream tuning and benchmarks

Run `ioscpy` with no arguments. Move the pointer to the top of the mirror for
Home and App Switcher controls. Use the native **视频设置** menu to change the
preset, frame rate, resolution, or bitrate; changes restart only the video stream,
take effect immediately, and persist for the next launch. The first-run default is
60 FPS, 2160 long edge, 25 Mbps.

The high-quality 120 FPS preset requests 2160 long edge at 40 Mbps without
automatic resolution reduction. Native resolution 120 FPS is also available for
testing the actual device limit. Command-line overrides remain for automation:

```bash
ioscpy --profile quality        # 60 FPS, 2160 long edge, 25 Mbps
ioscpy --profile balanced       # 60 FPS, 1800 long edge, 16 Mbps
ioscpy --profile latency        # 60 FPS, 1280 long edge, short queues
ioscpy --profile high-refresh   # 90 FPS, 1600 long edge, 18 Mbps
ioscpy --profile high-refresh --fps 120  # 2160 long edge, 40 Mbps
ioscpy --input-debug            # trace Mac touch sends and device HID submission
```

Advanced overrides include `--bitrate-mbps` and `--keyframe-seconds`. A headless
benchmark can save both Host measurements and the latest device capture/encode/
send counters as JSON:

```bash
ioscpy --bench 15 --profile balanced --bench-json bench.json
```

### Paired LAN prototype

USB remains the default and the daemon remains bound to `127.0.0.1`. On a device
you control, LAN listening can be enabled explicitly:

```bash
ioscpyctl lan-enable 0.0.0.0
```

The command prints a random pairing token once. Store it in a mode-600 file on
the Mac, then connect to the phone's LAN address:

```bash
chmod 600 ~/.ioscpy-pair-token
ioscpy --addr 192.168.1.50:27183 --pair-token-file ~/.ioscpy-pair-token
```

Use `ioscpyctl lan-disable` to return to loopback/USB-only mode. This stage is an
authenticated trusted-LAN prototype: the pairing token is required for remote
connections, but the video/control stream is not yet encrypted. Do not expose
the port to the internet or untrusted Wi-Fi.

## Scope

ioscpy is for controlling your own jailbroken iPhone from your Mac and Linux (Debian, Ubuntu and Arch Linux) device, over the USB cable, on the same desk.

For Linux hosts, same external requirement as macOS: libimobiledevice tools (`iproxy`,
  `idevice_id`, `ideviceinfo`) and `usbmuxd`.

It now runs on Windows too, reusing the standard iOS USB tools without replacing
any driver. It is still **ONLY** jailbroken iPhones.
