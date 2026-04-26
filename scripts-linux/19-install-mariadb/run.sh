#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="19"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 19-install-mariadb"; exit 1; }
APT_PKG="mariadb-server"; VERIFY_CMD='mariadb --version'; INSTALLED_MARK="$ROOT/.installed/19.ok"
verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }
verb_install() {
  log_info "[19] Starting MariaDB Server installer"
  if verify_installed; then log_ok "[19] Already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  if ! is_debian_family || ! is_apt_available; then log_err "[19] apt not available"; return 1; fi
  log_info "[19] Installing via apt: $APT_PKG"
  sudo apt-get update -y >/dev/null 2>&1 || true
  if sudo apt-get install -y $APT_PKG; then
    log_ok "[19] Installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_err "[19] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[19] Verify OK"; return 0; fi; log_warn "[19] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y $APT_PKG; rm -f "$INSTALLED_MARK"; log_ok "[19] Removed"; }
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[19] Unknown verb: $1"; exit 2;; esac
