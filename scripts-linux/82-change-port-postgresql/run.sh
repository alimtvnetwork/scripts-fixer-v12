#!/usr/bin/env bash
# scripts-linux/82-change-port-postgresql/run.sh
# Change the listening port for PostgreSQL. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="82"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="82"
PC_SERVICE_NAME="PostgreSQL"
PC_DEFAULT_PORT="5432"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="postgresql"
PC_VALIDATE_CMD=''
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/postgresql/*/main/postgresql.conf|||^#\?port[[:space:]]*=.*|||port = {PORT}"
)
pc_run "$@"
