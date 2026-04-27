#!/usr/bin/env bash
# scripts-linux/83-change-port-ftp/run.sh
# Change the listening port for vsftpd FTP. Powered by _shared/port-change.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="83"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/port-change.sh"

PC_SERVICE_ID="83"
PC_SERVICE_NAME="vsftpd FTP"
PC_DEFAULT_PORT="21"
PC_CONFIG_JSON="$SCRIPT_DIR/config.json"
PC_SYSTEMD_UNIT="vsftpd"
PC_VALIDATE_CMD=''
PC_FIREWALL_PROTO="tcp"
PC_EDIT_SPECS=(
    "/etc/vsftpd.conf|||^#\?listen_port=.*|||listen_port={PORT}"
)
pc_run "$@"
