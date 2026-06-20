#!/usr/bin/env bash
# Respring the device to reload the tweak.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_common.sh"

setup_connection
echo ">> respringing"
dev_ssh "$DEVICE_PATH; sbreload 2>/dev/null || killall -9 SpringBoard"
