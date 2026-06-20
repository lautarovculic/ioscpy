#!/usr/bin/env bash
# Remove the device package.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_common.sh"

setup_connection
echo ">> removing com.ioscpy.device"
dev_ssh "$DEVICE_PATH; dpkg -r com.ioscpy.device || true"
echo ">> done"
