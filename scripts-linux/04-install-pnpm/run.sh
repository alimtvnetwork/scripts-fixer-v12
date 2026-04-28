#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="04"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"; . "$ROOT/_shared/install-paths.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 04-install-pnpm"; exit 1; }
INSTALLED_MARK="$ROOT/.installed/04.ok"
PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
verify_installed() { command -v pnpm >/dev/null 2>&1 || [ -x "$PNPM_HOME/pnpm" ]; }

verb_install() {
  write_install_paths \
    --tool   "pnpm" \
    --source "https://get.pnpm.io/install.sh (official installer)" \
    --temp   "$HOME/.local/share/pnpm/.tmp" \
    --target "$PNPM_HOME/pnpm"
  log_info "[04] Starting pnpm installer"
  if verify_installed; then log_ok "[04] pnpm already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  has_curl || { log_err "[04] curl required"; return 1; }
  log_info "[04] Running official curl|sh installer"
  if curl -fsSL https://get.pnpm.io/install.sh | sh -; then
    log_ok "[04] pnpm installed (PATH updated in shell rc files)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
    return 0
  fi
  log_err "[04] pnpm install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[04] pnpm detected"; return 0; fi; log_warn "[04] pnpm not on PATH"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { rm -rf "$PNPM_HOME"; rm -f "$INSTALLED_MARK"; log_ok "[04] pnpm removed (PATH lines in shell rc remain -- edit manually)"; }
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[04] Unknown verb: $1"; exit 2;; esac
