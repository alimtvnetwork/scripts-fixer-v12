#!/usr/bin/env bash
# scripts-linux/85-change-port-mongodb/run.sh
# Change the listening port for MongoDB. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="85"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="85"
PC_SERVICE_NAME="MongoDB"
PC_DEFAULT_PORT="27017"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="mongod"
PC_VALIDATE_CMD='mongod --config /etc/mongod.conf --configExpand none -f /etc/mongod.conf 2>/dev/null || true'
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/mongod.conf|||^\([[:space:]]*\)port:.*|||\1port: {PORT}"
)
pc_run "$@"
