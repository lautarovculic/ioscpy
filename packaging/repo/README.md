# Sileo and Zebra repository

This folder builds the package repository that iPhone users add to install the
device side of ioscpy. It is the iOS counterpart to Homebrew: Homebrew installs
the Mac app, this repository installs the tweak and daemon on the phone.

## Build it

Build a device package first, then run the script:

```bash
make device-rootless
packaging/repo/build-repo.sh
```

The output goes to `packaging/repo/out/`:

```text
out/
  debs/            the .deb files
  Packages         package index, plus .gz .bz2 .xz copies
  Release          repo metadata and checksums
  CydiaIcon.png    the icon Sileo and Zebra show for the repo
```

You can pass specific packages instead of using the default folder:

```bash
packaging/repo/build-repo.sh path/to/one.deb path/to/another.deb
```

A few settings can be overridden with environment variables:

```text
IOSCPY_DEB_DIR     where to look for .deb files (default device/packages)
IOSCPY_REPO_OUT    where to write the repo       (default packaging/repo/out)
IOSCPY_REPO_ARCHS  architectures line in Release (default iphoneos-arm64)
```

## Host it

The `out/` folder is static. Put it behind HTTPS anywhere that serves files:
GitHub Pages, a small VPS with nginx, or any object storage with a web front.
The only rule is that `Packages`, `Release`, `CydiaIcon.png`, and `debs/` stay at
the same base URL.

Then add that URL in Sileo or Zebra under Sources, and ioscpy shows up as an
installable package.

## Notes

The repository is unsigned, which Sileo and Zebra accept. If you want APT to
verify a signature, sign `Release` with GPG to produce `Release.gpg` and
`InRelease`, and publish your public key next to the repo. That step is optional
and not required for installs to work.

When you ship a new version, rebuild the package, run the script again, and
re-upload `out/`. Phones see the update on their next refresh.
