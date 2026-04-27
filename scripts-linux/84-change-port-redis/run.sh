#!/usr/bin/env bash
# scripts-linux/84-change-port-redis/run.sh
# Change the listening port for Redis. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="84"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="84"
PC_SERVICE_NAME="Redis"
PC_DEFAULT_PORT="6379"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="redis-server"
PC_VALIDATE_CMD='redis-server /etc/redis/redis.conf --test-config 2>/dev/null || true'
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/redis/redis.conf|||^port .*|||port {PORT}"
)
pc_run "$@"
