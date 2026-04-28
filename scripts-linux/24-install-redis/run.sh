#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="24"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"; . "$ROOT/_shared/install-paths.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 24-install-redis"; exit 1; }
APT_PKG="redis-server"; INSTALLED_MARK="$ROOT/.installed/24.ok"
verify_installed() { command -v redis-server >/dev/null 2>&1; }
verb_install() {
  write_install_paths \
    --tool   "Redis" \
    --source "apt (Debian/Ubuntu): $APT_PKG" \
    --temp   "/var/cache/apt/archives" \
    --target "/usr/bin/redis-server + /var/lib/redis"
  log_info "[24] Starting Redis installer"
  if verify_installed; then log_ok "[24] Redis already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  if ! is_debian_family || ! is_apt_available; then log_err "[24] apt not available"; return 1; fi
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y $APT_PKG && { log_ok "[24] Redis installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; }
}
verb_check()     { if verify_installed; then log_ok "[24] redis detected: $(redis-server --version 2>/dev/null | head -1)"; return 0; fi; log_warn "[24] redis-server not on PATH"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y $APT_PKG; rm -f "$INSTALLED_MARK"; log_ok "[24] Redis removed"; }
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[24] Unknown verb: $1"; exit 2;; esac
