#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="51"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 51-install-flameshot"; exit 1; }
has_jq || { log_err "[51] jq required to read config"; exit 1; }
APT_PKG=$(jq -r '.install.apt' "$CONFIG")
INSTALLED_MARK="$ROOT/.installed/51.ok"
verify_installed() { command -v flameshot >/dev/null 2>&1 && flameshot --version >/dev/null 2>&1; }
verb_install() {
  write_install_paths \
    --tool   "Flameshot" \
    --source "apt (Debian/Ubuntu): flameshot" \
    --temp   "/var/cache/apt/archives" \
    --target "/usr/bin/flameshot"
  log_info "[51] Starting Flameshot installer"
  if verify_installed; then
    log_ok "[51] Already installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  if ! is_debian_family || ! is_apt_available; then log_err "[51] apt required"; return 1; fi
  log_info "[51] Installing via apt: $APT_PKG"
  if sudo apt-get install -y $APT_PKG; then
    log_ok "[51] Installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_err "[51] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[51] Verify OK"; return 0; fi; log_warn "[51] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y $APT_PKG || true; rm -f "$INSTALLED_MARK"; log_ok "[51] Removed"; }
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[51] Unknown verb: $1"; exit 2 ;;
esac
