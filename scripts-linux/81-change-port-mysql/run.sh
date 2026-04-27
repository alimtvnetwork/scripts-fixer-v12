#!/usr/bin/env bash
# scripts-linux/81-change-port-mysql/run.sh
# Change the listening port for MySQL server. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="81"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="81"
PC_SERVICE_NAME="MySQL server"
PC_DEFAULT_PORT="3306"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="mysql"
PC_VALIDATE_CMD=''
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/mysql/mysql.conf.d/mysqld.cnf|||^port[[:space:]]*=.*|||port            = {PORT}"
)
pc_run "$@"
