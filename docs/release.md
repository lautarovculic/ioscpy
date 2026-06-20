# Release

## Host (macOS)

The `ioscpy` binary is distributed through a Homebrew tap:

```bash
brew install lautarovculic/ioscpy/ioscpy
```

The formula builds from source and installs libimobiledevice, which provides the USB
tools required by the transport. `cargo install` is available as a developer fallback.

## Device (iOS)

The device package is distributed through a Sileo or Zebra repository. A user adds the
repository and installs ioscpy from the package manager, without requiring SSH. The
build produces one combined `.deb` per layout (rootless, rootful, roothide). The build
commands are documented in `device/packaging/README.md`.

## Versioning

Version numbers are semantic and tracked per component (host, daemon, tweak,
protocol). The protocol version governs compatibility: a matching major version is
required, and a minor mismatch is permitted only when capability negotiation succeeds.
The current protocol version is 4.
