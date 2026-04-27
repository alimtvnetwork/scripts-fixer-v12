#!/usr/bin/env bash
# scripts-linux/80-change-port-ssh/run.sh
# Change the listening port for OpenSSH server. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="80"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="80"
PC_SERVICE_NAME="OpenSSH server"
PC_DEFAULT_PORT="22"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="ssh"
PC_VALIDATE_CMD='sshd -t'
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/ssh/sshd_config|||^#\?Port .*|||Port {PORT}"
)
pc_run "$@"
