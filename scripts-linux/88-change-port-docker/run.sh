#!/usr/bin/env bash
# scripts-linux/88-change-port-docker/run.sh
# Change the listening port for Docker daemon (TCP socket). Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="88"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="88"
PC_SERVICE_NAME="Docker daemon (TCP socket)"
PC_DEFAULT_PORT="2375"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="docker"
PC_VALIDATE_CMD=''
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/docker/daemon.json|||"tcp://0.0.0.0:[0-9]\+"|||"tcp://0.0.0.0:{PORT}""
)
pc_run "$@"
