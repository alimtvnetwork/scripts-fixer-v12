#!/usr/bin/env bash
# scripts-linux/102-install-dns-powerdns-auth/run.sh
# Install PowerDNS Authoritative. Powered by _shared/dns-install.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="102"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/dns-install.sh"

DNS_ID="102"
DNS_NAME="PowerDNS Authoritative"
DNS_CONFIG_JSON="$SCRIPT_DIR/config.json"
DNS_INSTALLED_MARK="$ROOT/.installed/102.ok"
dns_run "$@"
