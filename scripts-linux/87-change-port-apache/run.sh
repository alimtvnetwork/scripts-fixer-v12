#!/usr/bin/env bash
# scripts-linux/87-change-port-apache/run.sh
# Change the listening port for Apache (apache2). Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="87"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="87"
PC_SERVICE_NAME="Apache (apache2)"
PC_DEFAULT_PORT="80"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="apache2"
PC_VALIDATE_CMD='apache2ctl configtest'
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/apache2/ports.conf|||Listen [0-9]\+|||Listen {PORT}"
)
pc_run "$@"
