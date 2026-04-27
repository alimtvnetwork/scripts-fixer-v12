#!/usr/bin/env bash
# scripts-linux/100-install-dns-bind9/run.sh
# Install BIND9. Powered by _shared/dns-install.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="100"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/dns-install.sh"

DNS_ID="100"
DNS_NAME="BIND9"
DNS_CONFIG_JSON="$SCRIPT_DIR/config.json"
DNS_INSTALLED_MARK="$ROOT/.installed/100.ok"
dns_run "$@"
