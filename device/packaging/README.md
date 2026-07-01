# Packaging

The device package is built with Theos. The build runs from `device/` and produces
a single combined `.deb` for the chosen jailbreak layout.

## Building

```bash
# rootless (/var/jb), for Dopamine and palera1n-rootless
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

# rootful (/), for palera1n-rootful
make package FINALPACKAGE=1

# roothide (prefix detected at runtime); needs the roothide Theos fork
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
```

The finished `.deb` is written to `device/packages/`.

## What goes into the package

The package bundles three components, each built from its own subproject under
`device/`:

- `daemon` (`ioscpyd`): the root daemon that owns the connection, the video
  stream, and command routing.
- `ctl` (`ioscpyctl`): a small root helper for status checks and maintenance.
- `tweak` (`ioscpyhook`): the SpringBoard injection that performs touch, keyboard,
  clipboard, and system actions.

Package metadata (name, version, dependencies, maintainer) lives in
`device/control`. The dependency line accepts either ElleKit or Substrate, so a
single package installs across the common injection setups.

## Install scripts

`device/layout/DEBIAN/postinst` and `prerm` manage the launchd service. On install,
`postinst` detects the active jailbreak prefix, writes the launchd plist for that
prefix, and starts the daemon. On removal, `prerm` stops it and cleans up. Writing
the plist at install time, rather than baking in an absolute path, keeps one
package correct across every layout.

Every path used at runtime is resolved through `device/jbcompat`, which detects the
prefix and the injection framework instead of assuming them.

## Variants

| variant  | prefix              | architecture   | injection            |
|----------|---------------------|----------------|----------------------|
| rootless | /var/jb             | iphoneos-arm64 | ElleKit              |
| rootful  | /                   | iphoneos-arm64 | Substrate or ElleKit |
| roothide | detected at runtime | iphoneos-arm64 | ElleKit              |

All variants share the `iphoneos-arm64` architecture (the Procursus architecture
used by modern iOS 15 and later jailbreaks). They differ only in the install
prefix, which the install scripts and `jbcompat` resolve on the device.
