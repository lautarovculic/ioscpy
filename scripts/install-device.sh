#!/usr/bin/env bash
# Build (unless --no-build) the rootless package and install it on the device.
#   IOSCPY_VARIANT=rootless|rootful   which package to push (default: rootless)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
source "$HERE/_common.sh"

VARIANT="${IOSCPY_VARIANT:-rootless}"

if [[ "${1:-}" != "--no-build" ]]; then
    echo ">> building $VARIANT package"
    if [[ "$VARIANT" == "rootful" ]]; then
        ( cd "$ROOT/device" && make package FINALPACKAGE=1 )
    else
        ( cd "$ROOT/device" && make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1 )
    fi
fi

DEB="$(ls -t "$ROOT"/device/packages/*.deb | head -1)"
echo ">> using $DEB"

setup_connection
echo ">> copying to device"
dev_scp "$DEB" /tmp/ioscpy.deb
echo ">> installing"
dev_ssh "$DEVICE_PATH; dpkg -i /tmp/ioscpy.deb"
echo ">> status"
dev_ssh "$DEVICE_PATH; ioscpyctl status"
