#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="44"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 44-install-rust"; exit 1; }
INSTALLED_MARK="$ROOT/.installed/44.ok"
CARGO_BIN="$HOME/.cargo/bin"
verify_installed() { command -v rustc >/dev/null 2>&1 || [ -x "$CARGO_BIN/rustc" ]; }
verb_install() {
  log_info "[44] Starting Rust installer"
  if verify_installed; then log_ok "[44] rustc already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  has_curl || { log_err "[44] curl required"; return 1; }
  log_info "[44] Running rustup -y (default profile)"
  if curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable; then
    log_ok "[44] Rust toolchain installed (~/.cargo/bin)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_err "[44] rustup failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[44] rustc detected"; return 0; fi; log_warn "[44] rustc not on PATH"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  if command -v rustup >/dev/null 2>&1; then rustup self uninstall -y || true; fi
  rm -rf "$HOME/.cargo" "$HOME/.rustup"; rm -f "$INSTALLED_MARK"; log_ok "[44] Rust removed"
}
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[44] Unknown verb: $1"; exit 2;; esac
