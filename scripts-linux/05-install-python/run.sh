#!/usr/bin/env bash
# 05-install-python -- Python 3 + pip + venv
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="05"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 05-install-python"; exit 1; }

INSTALL_APT="python3 python3-pip python3-venv"
VERIFY_CMD='python3 --version'
UNINSTALL_APT="python3-pip python3-venv"
INSTALLED_MARK="$ROOT/.installed/05.ok"

verify_installed() {
  bash -c "$VERIFY_CMD" >/dev/null 2>&1
}

verb_install() {
  log_info "[05] Starting Python 3 + pip + venv installer"
  if verify_installed; then
    log_ok "[05] Already installed: python3 python3-pip python3-venv"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  local method
  method=$(resolve_install_method "$CONFIG")
  log_info "[05] Resolution method: $method"
  case "$method" in
    apt)
      if ! is_debian_family; then log_warn "[05] Not a Debian-family distro"; return 1; fi
      log_info "[05] Installing via apt: python3 python3-pip python3-venv"
      sudo apt-get update -y >/dev/null 2>&1 || true
      if sudo apt-get install -y $INSTALL_APT; then
        log_ok "[05] Installed: python3 python3-pip python3-venv"
        mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      else
        log_err "[05] apt install failed for: python3 python3-pip python3-venv"; return 1
      fi
      ;;
    none|*)
      log_err "[05] No supported install method on this system"
      return 1
      ;;
  esac
}

verb_check() {
  if verify_installed; then
    log_ok "[05] Verify OK"
    return 0
  fi
  log_warn "[05] Verify FAILED -- run: bash $SCRIPT_DIR/run.sh repair"
  return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if [ -z "$UNINSTALL_APT" ]; then log_warn "[05] No uninstall mapping"; return 0; fi
  if is_debian_family && is_apt_available; then
    log_info "[05] Uninstalling: $UNINSTALL_APT"
    sudo apt-get remove -y $UNINSTALL_APT && rm -f "$INSTALLED_MARK"
  fi
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[05] Unknown verb: $1"; exit 2 ;;
esac
