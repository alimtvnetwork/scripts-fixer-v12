#!/usr/bin/env bash
# 35-install-gitmap -- gitmap CLI (curl one-liner from gitmap-v9 release)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="35"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 35-install-gitmap"; exit 1; }

# Canonical install one-liner (matches README + root install hint)
INSTALL_URL="https://github.com/alimtvnetwork/gitmap-v9/releases/download/v3.180/install.sh"

# Where the upstream installer drops the binary by default.
BIN_DIR="${HOME}/.local/bin"
DEST="$BIN_DIR/gitmap"
INSTALLED_MARK="$ROOT/.installed/35.ok"

verify_installed() { command -v gitmap >/dev/null 2>&1 || [ -x "$DEST" ]; }

verb_install() {
  write_install_paths \
    --tool   "gitmap" \
    --source "$INSTALL_URL (curl | bash)" \
    --temp   "${TMPDIR:-/tmp}/scripts-fixer/gitmap" \
    --target "$DEST"

  log_info "[35] Starting gitmap installer"
  if verify_installed; then
    log_ok "[35] Already installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_file_error "(curl)" "curl not found; cannot run gitmap install one-liner"
    return 1
  fi

  mkdir -p "$BIN_DIR" || { log_file_error "$BIN_DIR" "bin dir mkdir failed"; return 1; }

  log_info "[35] Invoking: curl -fsSL $INSTALL_URL | bash"
  if ! curl -fsSL "$INSTALL_URL" | bash; then
    log_file_error "$INSTALL_URL" "curl | bash one-liner exited non-zero"
    return 1
  fi

  if verify_installed; then
    log_ok "[35] Verify OK (gitmap installed)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[35] Verify FAILED after install (binary not on PATH; check $DEST)"
  return 1
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
