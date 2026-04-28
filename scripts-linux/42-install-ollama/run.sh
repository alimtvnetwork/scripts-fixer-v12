#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="42"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 42-install-ollama"; exit 1; }
has_jq || { log_err "[42] jq required to read config"; exit 1; }

SCRIPT_URL=$(jq -r '.install.scriptUrl' "$CONFIG")
BIN_PATH=$(jq -r '.install.binPath' "$CONFIG")
SERVICE=$(jq -r '.install.service' "$CONFIG")
INSTALLED_MARK="$ROOT/.installed/42.ok"

verify_installed() { command -v ollama >/dev/null 2>&1 && ollama --version >/dev/null 2>&1; }

verb_install() {
  write_install_paths \
    --tool   "Ollama" \
    --source "https://ollama.com/install.sh (official installer)" \
    --temp   "$TMPDIR/scripts-fixer/ollama" \
    --target "/usr/local/bin/ollama + /usr/share/ollama"
  log_info "[42] Starting Ollama installer"
  if verify_installed; then
    log_ok "[42] Already installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  has_curl || { log_err "[42] curl required"; return 1; }
  log_info "[42] Fetching official install script: $SCRIPT_URL"
  local tmp
  tmp=$(mktemp /tmp/ollama-install.XXXXXX.sh) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
    log_file_error "$tmp" "Failed to download Ollama install script from $SCRIPT_URL"
    rm -f "$tmp"; return 1
  fi
  log_info "[42] Running official Ollama installer"
  if ! sh "$tmp"; then
    log_file_error "$tmp" "Official Ollama installer exited non-zero"
    rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  if verify_installed; then
    log_ok "[42] Verify OK (ollama binary found)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[42] Verify FAILED after install"; return 1
}
verb_check()     { if verify_installed; then log_ok "[42] Verify OK"; return 0; fi; log_warn "[42] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  log_info "[42] Removing ollama binary + systemd service"
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE" 2>/dev/null || true
    sudo systemctl disable "$SERVICE" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE}.service"
    sudo systemctl daemon-reload 2>/dev/null || true
  fi
  sudo rm -f "$BIN_PATH" || log_file_error "$BIN_PATH" "ollama binary removal failed"
  rm -f "$INSTALLED_MARK"
  log_ok "[42] Removed"
}
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[42] Unknown verb: $1"; exit 2 ;;
esac
