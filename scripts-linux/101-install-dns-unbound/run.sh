#!/usr/bin/env bash
# scripts-linux/101-install-dns-unbound/run.sh
# Install Unbound. Powered by _shared/dns-install.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="101"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/dns-install.sh"

DNS_ID="101"
DNS_NAME="Unbound"
DNS_CONFIG_JSON="$SCRIPT_DIR/config.json"
DNS_INSTALLED_MARK="$ROOT/.installed/101.ok"
dns_run "$@"
