# Jailbreak compatibility

ioscpy targets iOS 15 and later across the common jailbreak layouts. All layout
specific logic is confined to a single location, `device/jbcompat`, rather than
distributed through the code.

## Detected at runtime

- Layout and prefix: rootless (`/var/jb`), rootful (`/`), or a dynamically rooted
  (roothide) environment. The prefix is derived from the install path of the running
  binary (`_NSGetExecutablePath`, with the trailing `/usr/bin/<tool>` removed). This
  is correct on every layout because dpkg has already placed the daemon under the
  active prefix, including the randomized roothide path
  `/private/preboot/.../jb-XXXX/procursus`. The resolver falls back to the `JBROOT`
  environment variable, then `/var/jb`, then `/`, and it confirms that the daemon
  exists under the resolved prefix before accepting it. Only the daemon and
  `ioscpyctl` resolve a prefix; the tweak reaches the daemon over a fixed loopback
  port and requires none.
- Injection framework: ElleKit, Substitute, or Substrate. ElleKit provides a
  Substrate compatible shim, so it is checked first in order to report the framework
  that is actually in control.
- Device facts: the model and the OS version, reported in the capability map.

## Capability negotiation

During the handshake the daemon transmits a capability map that describes the layout,
the injection framework, the available stream and input backends, and the features
that are live (clipboard, keyboard, orientation). The host selects backends from this
map and assumes no capability that is not advertised.

## Packaging

A separate package variant is published per layout, rather than a single package that
rewrites itself at install time. One `device/control` and `device/layout` drive the
rootless and rootful builds. Theos relocates the install path under the active prefix
for each scheme, and `postinst` re-derives the same prefix at install time (from the
location of the installed daemon, then a `jbroot` probe, then `JBROOT`, `/var/jb`, or
`/`) to generate the launchd plist. `Architecture: iphoneos-arm64` is pinned in
`control`, since that is the Procursus architecture for rootless, roothide, and modern
(palera1n) rootful, and Theos sets no architecture for the default rootful scheme.

The roothide variant (`make package THEOS_PACKAGE_SCHEME=roothide`) requires the
roothide Theos fork, which rewrites the dyld install names to the
`@loader_path/.jbroot/...` form. Without that fork the build falls back to a rootful
package. A rootless `.deb` still installs and runs on a roothide device that retains
the `/var/jb` symlink, as the test unit does.

## Tested devices

The tested devices table is maintained in the root `README.md`, where contributors
may add their results. The test unit, on which `/var/jb` points to
`/private/preboot/.../jb-XXXX/procursus`, is roothide, and the same host binary and
rootless package operate on it unchanged. Rootful runtime remains untested and
requires a palera1n-rootful device; the package builds with the correct paths
(`/usr/bin`, `Library/MobileSubstrate/DynamicLibraries`) and architecture.

Contributions that extend coverage to other iOS versions and jailbreaks are welcome.
See the contribution note under "Tested devices" in the root `README.md`.
