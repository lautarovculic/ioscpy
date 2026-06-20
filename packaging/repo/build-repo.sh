#!/usr/bin/env bash
# Build a Sileo and Zebra repository from the device .deb files.
#
# It gathers the packages, writes the Packages index, builds a Release file with
# checksums, and drops the repo icon in place. The result lands in out/, a plain
# static folder you can serve over HTTPS and add in Sileo or Zebra.
#
# Usage:
#   packaging/repo/build-repo.sh                 use device/packages/*.deb
#   packaging/repo/build-repo.sh path/to/a.deb   use the .deb files you pass
#
# Override with env vars when you need to:
#   IOSCPY_DEB_DIR    where to look for .deb files (default device/packages)
#   IOSCPY_REPO_OUT   where to write the repo       (default packaging/repo/out)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

deb_dir="${IOSCPY_DEB_DIR:-$root/device/packages}"
out="${IOSCPY_REPO_OUT:-$here/out}"

# Repo identity shown in Sileo and Zebra.
origin="${IOSCPY_REPO_ORIGIN:-ioscpy}"
label="${IOSCPY_REPO_LABEL:-ioscpy}"
desc="${IOSCPY_REPO_DESC:-Mirror and control a jailbroken iPhone from macOS over USB.}"
archs="${IOSCPY_REPO_ARCHS:-iphoneos-arm64}"

if ! command -v dpkg-scanpackages >/dev/null 2>&1; then
  echo "dpkg-scanpackages not found. Install it with: brew install dpkg" >&2
  exit 1
fi

# Collect the .deb files: the ones passed as arguments, or every .deb in deb_dir.
debs=()
if [ "$#" -gt 0 ]; then
  debs=("$@")
else
  while IFS= read -r f; do debs+=("$f"); done \
    < <(find "$deb_dir" -name '*.deb' 2>/dev/null | sort)
fi

if [ "${#debs[@]}" -eq 0 ]; then
  echo "no .deb files found. Build one first with: make device-rootless" >&2
  exit 1
fi

# Fresh layout: out/debs holds the packages, the index files sit at the root.
rm -rf "$out"
mkdir -p "$out/debs"
for d in "${debs[@]}"; do
  cp "$d" "$out/debs/"
  echo "added $(basename "$d")"
done

cp "$here/CydiaIcon.png" "$out/CydiaIcon.png"

# Build the package index. Filename: paths come out as debs/<name>.deb.
cd "$out"
dpkg-scanpackages --multiversion debs > Packages 2>/dev/null
gzip  -9 -k -f -n Packages
bzip2 -9 -k -f    Packages
xz    -9 -k -f    Packages

# Helpers for the Release checksums.
size_of() { wc -c < "$1" | tr -d ' '; }
md5_of()  { md5 -q "$1"; }
sha_of()  { shasum -a 256 "$1" | awk '{print $1}'; }

index_files=(Packages Packages.gz Packages.bz2 Packages.xz)

{
  echo "Origin: $origin"
  echo "Label: $label"
  echo "Suite: stable"
  echo "Version: 1.0"
  echo "Codename: ios"
  echo "Architectures: $archs"
  echo "Components: main"
  echo "Description: $desc"
  echo "MD5Sum:"
  for f in "${index_files[@]}"; do
    printf ' %s %s %s\n' "$(md5_of "$f")" "$(size_of "$f")" "$f"
  done
  echo "SHA256:"
  for f in "${index_files[@]}"; do
    printf ' %s %s %s\n' "$(sha_of "$f")" "$(size_of "$f")" "$f"
  done
} > Release

echo
echo "repo ready in $out"
echo "serve that folder over HTTPS, then add the URL in Sileo or Zebra."
