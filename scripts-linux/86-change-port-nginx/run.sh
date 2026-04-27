#!/usr/bin/env bash
# scripts-linux/86-change-port-nginx/run.sh
# Change the listening port for nginx. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="86"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="86"
PC_SERVICE_NAME="nginx"
PC_DEFAULT_PORT="80"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="nginx"
PC_VALIDATE_CMD='nginx -t'
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/nginx/sites-enabled/default|||listen[[:space:]]\+[0-9]\+\([[:space:]]\+default_server\)\?;|||listen {PORT};"
)
pc_run "$@"
