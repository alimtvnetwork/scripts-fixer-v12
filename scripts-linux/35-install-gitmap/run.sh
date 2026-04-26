#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="35"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 35-install-gitmap"; exit 1; }
has_jq || { log_err "[35] jq required to read config"; exit 1; }

SCRIPT_NAME=$(jq -r '.install.scriptName' "$CONFIG")
SCRIPT_SRC="$SCRIPT_DIR/$(jq -r '.install.scriptSrc' "$CONFIG")"
BIN_DIR_RAW=$(jq -r '.install.binDir' "$CONFIG")
BIN_DIR="${BIN_DIR_RAW//\$\{HOME\}/$HOME}"
DEPS=$(jq -r '.install.deps | join(" ")' "$CONFIG")
DEST="$BIN_DIR/$SCRIPT_NAME"
INSTALLED_MARK="$ROOT/.installed/35.ok"

verify_installed() { [ -x "$DEST" ] && "$DEST" --version >/dev/null 2>&1; }

verb_install() {
  log_info "[35] Starting gitmap installer"
  if verify_installed; then
    log_ok "[35] Already installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  if is_debian_family && is_apt_available; then
    log_info "[35] Installing deps: $DEPS"
    sudo apt-get install -y $DEPS || log_warn "[35] dep install failed (continuing — gitmap will fall back to git ls-files)"
  fi
  [ -f "$SCRIPT_SRC" ] || { log_file_error "$SCRIPT_SRC" "payload script missing"; return 1; }
  mkdir -p "$BIN_DIR" || { log_file_error "$BIN_DIR" "bin dir mkdir failed"; return 1; }
  log_info "[35] Installing gitmap to $DEST"
  if ! install -m 0755 "$SCRIPT_SRC" "$DEST"; then
    log_file_error "$DEST" "install failed (src=$SCRIPT_SRC)"; return 1
  fi
  if verify_installed; then
    log_ok "[35] Verify OK (gitmap --version)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[35] Verify FAILED after install"; return 1
}
verb_check()     { if verify_installed; then log_ok "[35] Verify OK"; return 0; fi; log_warn "[35] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$DEST" "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  rm -f "$DEST" || log_file_error "$DEST" "removal failed"
  rm -f "$INSTALLED_MARK"
  log_ok "[35] Removed gitmap"
}
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[35] Unknown verb: $1"; exit 2 ;;
esac
