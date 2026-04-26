#!/usr/bin/env bash
# 01-install-vscode
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="01"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 01-install-vscode"; exit 1; }

INSTALLED_MARK="$ROOT/.installed/01.ok"

verify_installed() { command -v code >/dev/null 2>&1; }

install_via_ms_repo() {
  log_info "[01] Adding Microsoft apt repo + key"
  has_curl || { log_err "[01] curl required for Microsoft key"; return 1; }
  local key_tmp keyring="/usr/share/keyrings/packages.microsoft.gpg"
  key_tmp=$(mktemp /tmp/microsoft.gpg.XXXXXX) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$key_tmp"; then
    log_file_error "$key_tmp" "failed to fetch/dearmor Microsoft GPG key"
    return 1
  fi
  sudo install -D -o root -g root -m 644 "$key_tmp" "$keyring" || { log_file_error "$keyring" "install of GPG keyring failed"; return 1; }
  rm -f "$key_tmp"
  echo "deb [arch=amd64,arm64,armhf signed-by=$keyring] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y code
}

install_via_snap() {
  log_info "[01] Installing code via snap classic"
  sudo snap install code --classic
}

verb_install() {
  log_info "[01] Starting VS Code installer"
  if verify_installed; then
    log_ok "[01] VS Code already installed"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  if is_debian_family && is_apt_available; then
    if install_via_ms_repo; then
      log_ok "[01] VS Code installed via Microsoft apt repo"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
    log_warn "[01] apt path failed -- trying snap fallback"
  fi
  if is_snap_available; then
    if install_via_snap; then
      log_ok "[01] VS Code installed via snap"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
  fi
  log_err "[01] No supported install method"
  return 1
}

verb_check() {
  if verify_installed; then log_ok "[01] code detected: $(code --version 2>/dev/null | head -1)"; return 0; fi
  log_warn "[01] code not on PATH"; return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if is_apt_pkg_installed code; then sudo apt-get remove -y code; fi
  if is_snap_pkg_installed code; then sudo snap remove code; fi
  rm -f "$INSTALLED_MARK"
  log_ok "[01] VS Code uninstalled"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[01] Unknown verb: $1"; exit 2 ;;
esac
