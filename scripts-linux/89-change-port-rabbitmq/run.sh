#!/usr/bin/env bash
# scripts-linux/89-change-port-rabbitmq/run.sh
# Change the listening port for RabbitMQ AMQP. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="89"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="89"
PC_SERVICE_NAME="RabbitMQ AMQP"
PC_DEFAULT_PORT="5672"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="rabbitmq-server"
PC_VALIDATE_CMD=''
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/rabbitmq/rabbitmq.conf|||^listeners.tcp.default[[:space:]]*=.*|||listeners.tcp.default = {PORT}"
)
pc_run "$@"
