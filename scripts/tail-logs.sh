#!/usr/bin/env bash
# Follow the daemon log on the device.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_common.sh"

setup_connection
# Resolve the prefix on the device (single-quoted so $P expands there, not here)
# so this works under rootless (/var/jb) and rootful (/).
dev_ssh "$DEVICE_PATH"' ; P=/var/jb; [ -d "$P" ] || P=; tail -n 100 -f "$P/var/log/ioscpy/ioscpyd.log"'
