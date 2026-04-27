#!/usr/bin/env bash
# scripts-linux/106-install-dns-knot-resolver/run.sh
# Install Knot Resolver. Powered by _shared/dns-install.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="106"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/dns-install.sh"

DNS_ID="106"
DNS_NAME="Knot Resolver"
DNS_CONFIG_JSON="$SCRIPT_DIR/config.json"
DNS_INSTALLED_MARK="$ROOT/.installed/106.ok"
dns_run "$@"
