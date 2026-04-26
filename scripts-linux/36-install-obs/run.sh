#!/usr/bin/env bash
# 36-install-obs -- OBS Studio
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="36"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 36-install-obs"; exit 1; }

APT_PKG="obs-studio"
SNAP_PKG="obs-studio"
SNAP_FLAG=""
VERIFY_CMD='command -v obs'
INSTALLED_MARK="$ROOT/.installed/36.ok"

verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }

verb_install() {
  log_info "[36] Starting OBS Studio installer"
  if verify_installed; then
    log_ok "[36] Already installed"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  if [ -n "$APT_PKG" ] && is_debian_family && is_apt_available; then
    log_info "[36] Installing via apt: $APT_PKG"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if sudo apt-get install -y $APT_PKG; then
      log_ok "[36] Installed via apt"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
    log_warn "[36] apt failed -- trying snap fallback"
  fi
  if [ -n "$SNAP_PKG" ] && is_snap_available; then
    log_info "[36] Installing via snap: $SNAP_PKG $SNAP_FLAG"
    if sudo snap install $SNAP_PKG $SNAP_FLAG; then
      log_ok "[36] Installed via snap"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
  fi
  log_err "[36] No supported install method"
  return 1
}

verb_check() {
  if verify_installed; then log_ok "[36] Verify OK"; return 0; fi
  log_warn "[36] Verify FAILED -- run: bash $SCRIPT_DIR/run.sh repair"; return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if [ -n "$APT_PKG" ] && is_apt_pkg_installed "$APT_PKG"; then sudo apt-get remove -y $APT_PKG; fi
  if [ -n "$SNAP_PKG" ] && is_snap_pkg_installed "$SNAP_PKG"; then sudo snap remove $SNAP_PKG; fi
  rm -f "$INSTALLED_MARK"
  log_ok "[36] Uninstalled"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[36] Unknown verb: $1"; exit 2 ;;
esac
