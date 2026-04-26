#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="39"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 39-install-dotnet"; exit 1; }
INSTALLED_MARK="$ROOT/.installed/39.ok"
verify_installed() { command -v dotnet >/dev/null 2>&1; }
add_ms_repo() {
  local ver tmp
  ver=$(get_ubuntu_version)
  log_info "[39] Adding Microsoft apt repo for ubuntu $ver"
  has_curl || { log_err "[39] curl required"; return 1; }
  tmp=$(mktemp /tmp/packages-microsoft-prod.XXXXXX.deb) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL "https://packages.microsoft.com/config/ubuntu/${ver}/packages-microsoft-prod.deb" -o "$tmp"; then
    log_file_error "$tmp" "failed to download Microsoft repo deb for ubuntu $ver"; return 1
  fi
  sudo dpkg -i "$tmp" >/dev/null 2>&1 || { log_err "[39] dpkg -i failed"; return 1; }
  rm -f "$tmp"
  sudo apt-get update -y >/dev/null 2>&1 || true
}
verb_install() {
  log_info "[39] Starting .NET SDK installer"
  if verify_installed; then log_ok "[39] .NET already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  if ! is_debian_family || ! is_apt_available; then log_err "[39] apt required"; return 1; fi
  add_ms_repo || return 1
  log_info "[39] Installing dotnet-sdk-8.0"
  if sudo apt-get install -y dotnet-sdk-8.0; then
    log_ok "[39] .NET SDK installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_err "[39] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[39] dotnet detected: $(dotnet --version 2>/dev/null)"; return 0; fi; log_warn "[39] dotnet not on PATH"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y dotnet-sdk-8.0 || true; rm -f "$INSTALLED_MARK"; log_ok "[39] .NET removed"; }
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[39] Unknown verb: $1"; exit 2;; esac
