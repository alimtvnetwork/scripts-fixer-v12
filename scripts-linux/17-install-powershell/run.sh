#!/usr/bin/env bash
# 17-install-powershell -- PowerShell on Ubuntu/Debian
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="17"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 17-install-powershell"; exit 1; }

INSTALLED_MARK="$ROOT/.installed/17.ok"

verify_installed() { command -v pwsh >/dev/null 2>&1; }

install_via_ms_repo() {
  local ver
  ver=$(get_ubuntu_version)
  log_info "[17] Adding Microsoft apt repo for ubuntu $ver"
  has_curl || { log_err "[17] curl required to fetch Microsoft repo key"; return 1; }
  local tmp
  tmp=$(mktemp /tmp/packages-microsoft-prod.XXXXXX.deb) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL "https://packages.microsoft.com/config/ubuntu/${ver}/packages-microsoft-prod.deb" -o "$tmp"; then
    log_file_error "$tmp" "failed to download Microsoft repo deb for ubuntu $ver"
    return 1
  fi
  sudo dpkg -i "$tmp" >/dev/null 2>&1 || { log_err "[17] dpkg -i failed for $tmp"; return 1; }
  rm -f "$tmp"
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y powershell
}

install_via_snap() {
  log_info "[17] Installing powershell via snap (classic)"
  sudo snap install powershell --classic
}

verb_install() {
  log_info "[17] Starting PowerShell installer"
  if verify_installed; then
    log_ok "[17] PowerShell already installed"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  if is_debian_family && is_apt_available; then
    if install_via_ms_repo; then
      log_ok "[17] PowerShell installed via Microsoft apt repo"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
    log_warn "[17] Microsoft repo path failed -- trying snap fallback"
  fi
  if is_snap_available; then
    if install_via_snap; then
      log_ok "[17] PowerShell installed via snap"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
  fi
  log_err "[17] No supported install method"
  return 1
}

verb_check() {
  if verify_installed; then log_ok "[17] pwsh detected: $(pwsh --version 2>/dev/null | head -1)"; return 0; fi
  log_warn "[17] pwsh not on PATH"; return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if is_apt_pkg_installed powershell; then sudo apt-get remove -y powershell; fi
  if is_snap_pkg_installed powershell; then sudo snap remove powershell; fi
  rm -f "$INSTALLED_MARK"
  log_ok "[17] PowerShell removed"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[17] Unknown verb: $1"; exit 2 ;;
esac
