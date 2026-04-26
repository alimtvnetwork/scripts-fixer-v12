#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="16"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 16-install-php"; exit 1; }
APT_PKG="php-cli php-fpm"; VERIFY_CMD='php --version'; INSTALLED_MARK="$ROOT/.installed/16.ok"
verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }
verb_install() {
  log_info "[16] Starting PHP CLI + FPM installer"
  if verify_installed; then log_ok "[16] Already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  if ! is_debian_family || ! is_apt_available; then log_err "[16] apt not available"; return 1; fi
  log_info "[16] Installing via apt: $APT_PKG"
  sudo apt-get update -y >/dev/null 2>&1 || true
  if sudo apt-get install -y $APT_PKG; then
    log_ok "[16] Installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_err "[16] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[16] Verify OK"; return 0; fi; log_warn "[16] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y $APT_PKG; rm -f "$INSTALLED_MARK"; log_ok "[16] Removed"; }
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[16] Unknown verb: $1"; exit 2;; esac
