#!/usr/bin/env bash
# scripts-linux/107-install-dns-coredns/run.sh
# Install CoreDNS. Powered by _shared/dns-install.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="107"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/dns-install.sh"

DNS_ID="107"
DNS_NAME="CoreDNS"
DNS_CONFIG_JSON="$SCRIPT_DIR/config.json"
DNS_INSTALLED_MARK="$ROOT/.installed/107.ok"
dns_run "$@"
