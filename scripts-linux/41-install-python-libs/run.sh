#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="41"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 41-install-python-libs"; exit 1; }
has_jq || { log_err "[41] jq required to read config"; exit 1; }

APT_BASE=$(jq -r '.install.aptBase | join(" ")' "$CONFIG")
PIP_LIBS=$(jq -r '.install.pipLibs | join(" ")' "$CONFIG")
VENV_PATH_RAW=$(jq -r '.install.venvPath' "$CONFIG")
VENV_PATH="${VENV_PATH_RAW//\$\{HOME\}/$HOME}"
INSTALLED_MARK="$ROOT/.installed/41.ok"

verify_installed() {
  command -v python3 >/dev/null 2>&1 || return 1
  [ -x "$VENV_PATH/bin/python" ] || return 1
  "$VENV_PATH/bin/python" -c 'import numpy,pandas,sklearn' >/dev/null 2>&1
}

verb_install() {
  log_info "[41] Starting Python AI base libraries installer"
  if verify_installed; then
    log_ok "[41] Already installed (venv + import OK)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  if ! is_debian_family || ! is_apt_available; then
    log_err "[41] apt required (Debian/Ubuntu family)"; return 1
  fi
  log_info "[41] Installing apt base: $APT_BASE"
  if ! sudo apt-get install -y $APT_BASE; then
    log_err "[41] apt base install failed"; return 1
  fi
  if [ ! -x "$VENV_PATH/bin/python" ]; then
    log_info "[41] Creating venv at $VENV_PATH"
    mkdir -p "$(dirname "$VENV_PATH")" || { log_file_error "$(dirname "$VENV_PATH")" "venv parent mkdir failed"; return 1; }
    if ! python3 -m venv "$VENV_PATH"; then
      log_file_error "$VENV_PATH" "venv creation failed"; return 1
    fi
  fi
  log_info "[41] Installing pip libs into venv: $PIP_LIBS"
  "$VENV_PATH/bin/python" -m pip install --upgrade pip >/dev/null 2>&1 || true
  if ! "$VENV_PATH/bin/python" -m pip install $PIP_LIBS; then
    log_file_error "$VENV_PATH" "pip install failed inside venv"; return 1
  fi
  if verify_installed; then
    log_ok "[41] Verify OK"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[41] Verify FAILED after install"; return 1
}
verb_check()     { if verify_installed; then log_ok "[41] Verify OK"; return 0; fi; log_warn "[41] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  rm -rf "$VENV_PATH" || log_file_error "$VENV_PATH" "venv removal failed"
  rm -f "$INSTALLED_MARK"
  log_ok "[41] Removed venv at $VENV_PATH (apt python3 left intact, may be shared)"
}
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[41] Unknown verb: $1"; exit 2 ;;
esac
