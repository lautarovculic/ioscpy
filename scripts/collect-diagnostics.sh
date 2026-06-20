#!/usr/bin/env bash
# Pull a diagnostics bundle off the device into ./diagnostics/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
source "$HERE/_common.sh"

setup_connection
echo ">> building diagnostics bundle on device"
dev_ssh "$DEVICE_PATH; ioscpyctl export-diagnostics"

mkdir -p "$ROOT/diagnostics"
OUT="$ROOT/diagnostics/ioscpy-diagnostics-$(date +%Y%m%d-%H%M%S).tar.gz"
echo ">> downloading to $OUT"
if [[ -n "${IOSCPY_SSH_PASS:-}" ]]; then
    sshpass -p "$IOSCPY_SSH_PASS" scp -O -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -P "$_PORT" \
        "${IOSCPY_SSH_USER}@${_HOST}:/tmp/ioscpy-diagnostics.tar.gz" "$OUT"
else
    scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$_PORT" \
        "${IOSCPY_SSH_USER}@${_HOST}:/tmp/ioscpy-diagnostics.tar.gz" "$OUT"
fi
echo ">> done: $OUT"
