#!/usr/bin/env bash
# 47-install-ubuntu-font -- Ubuntu font family
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="47"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 47-install-ubuntu-font"; exit 1; }

APT_PKG="fonts-ubuntu"
SNAP_PKG=""
SNAP_FLAG=""
VERIFY_CMD='fc-list 2>/dev/null | grep -qi ubuntu'
INSTALLED_MARK="$ROOT/.installed/47.ok"

verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }

verb_install() {
  write_install_paths \
    --tool   "Ubuntu font family" \
    --source "apt (Debian/Ubuntu): fonts-ubuntu" \
    --temp   "/var/cache/apt/archives" \
    --target "/usr/share/fonts/truetype/ubuntu"
  log_info "[47] Starting Ubuntu font family installer"
  if verify_installed; then
    log_ok "[47] Already installed"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  if [ -n "$APT_PKG" ] && is_debian_family && is_apt_available; then
    log_info "[47] Installing via apt: $APT_PKG"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if sudo apt-get install -y $APT_PKG; then
      log_ok "[47] Installed via apt"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
    log_warn "[47] apt failed -- trying snap fallback"
  fi
  if [ -n "$SNAP_PKG" ] && is_snap_available; then
    log_info "[47] Installing via snap: $SNAP_PKG $SNAP_FLAG"
    if sudo snap install $SNAP_PKG $SNAP_FLAG; then
      log_ok "[47] Installed via snap"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
  fi
  log_err "[47] No supported install method"
  return 1
}

verb_check() {
  if verify_installed; then log_ok "[47] Verify OK"; return 0; fi
  log_warn "[47] Verify FAILED -- run: bash $SCRIPT_DIR/run.sh repair"; return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if [ -n "$APT_PKG" ] && is_apt_pkg_installed "$APT_PKG"; then sudo apt-get remove -y $APT_PKG; fi
  if [ -n "$SNAP_PKG" ] && is_snap_pkg_installed "$SNAP_PKG"; then sudo snap remove $SNAP_PKG; fi
  rm -f "$INSTALLED_MARK"
  log_ok "[47] Uninstalled"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[47] Unknown verb: $1"; exit 2 ;;
esac
