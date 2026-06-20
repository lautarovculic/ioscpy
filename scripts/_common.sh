#!/usr/bin/env bash
# Shared helpers for the device scripts: resolve a device, open an SSH path to
# it, and expose dev_ssh / dev_scp.
#
# Connection is configured entirely through the environment so nothing sensitive
# lives in the repo:
#   IOSCPY_SSH_HOST   ssh host to use directly (e.g. 172.20.10.2). If set, no
#                     USB tunnel is created.
#   IOSCPY_SSH_USER   ssh user (default: root)
#   IOSCPY_SSH_PASS   ssh password; if set, sshpass is used. Otherwise keys.
#   IOSCPY_DEVICE_UDID  target UDID for USB mode (default: first attached)
#   IOSCPY_LOCAL_PORT   local port for the USB SSH forward (default: 2222)
set -euo pipefail

IOSCPY_SSH_USER="${IOSCPY_SSH_USER:-root}"
IOSCPY_LOCAL_PORT="${IOSCPY_LOCAL_PORT:-2222}"

_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o ConnectTimeout=12 -o LogLevel=ERROR)
_IPROXY_PID=""

_cleanup() {
    [[ -n "$_IPROXY_PID" ]] && kill "$_IPROXY_PID" 2>/dev/null || true
}
trap _cleanup EXIT

# Decide host:port and (for USB mode) bring up the iproxy tunnel.
setup_connection() {
    if [[ -n "${IOSCPY_SSH_HOST:-}" ]]; then
        _HOST="$IOSCPY_SSH_HOST"
        _PORT=22
        return
    fi
    local udid="${IOSCPY_DEVICE_UDID:-$(idevice_id -l | awk 'NF{print $1; exit}')}"
    if [[ -z "$udid" ]]; then
        echo "no device attached and IOSCPY_SSH_HOST not set" >&2
        exit 1
    fi
    iproxy "${IOSCPY_LOCAL_PORT}:22" -u "$udid" -l >/dev/null 2>&1 &
    _IPROXY_PID=$!
    _HOST="127.0.0.1"
    _PORT="$IOSCPY_LOCAL_PORT"
    sleep 1
}

dev_ssh() {
    if [[ -n "${IOSCPY_SSH_PASS:-}" ]]; then
        sshpass -p "$IOSCPY_SSH_PASS" ssh "${_SSH_OPTS[@]}" -p "$_PORT" \
            "${IOSCPY_SSH_USER}@${_HOST}" "$@"
    else
        ssh "${_SSH_OPTS[@]}" -p "$_PORT" "${IOSCPY_SSH_USER}@${_HOST}" "$@"
    fi
}

dev_scp() {
    # usage: dev_scp <local> <remote>
    if [[ -n "${IOSCPY_SSH_PASS:-}" ]]; then
        sshpass -p "$IOSCPY_SSH_PASS" scp -O "${_SSH_OPTS[@]}" -P "$_PORT" \
            "$1" "${IOSCPY_SSH_USER}@${_HOST}:$2"
    else
        scp -O "${_SSH_OPTS[@]}" -P "$_PORT" "$1" "${IOSCPY_SSH_USER}@${_HOST}:$2"
    fi
}

# Common on-device PATH so prefix tools resolve under any layout.
DEVICE_PATH='export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin'
