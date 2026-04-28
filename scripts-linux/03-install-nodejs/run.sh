#!/usr/bin/env bash
# 03-install-nodejs -- Node.js LTS
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="03"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 03-install-nodejs"; exit 1; }

INSTALL_APT="nodejs npm"
VERIFY_CMD='node --version'
UNINSTALL_APT="nodejs"
INSTALLED_MARK="$ROOT/.installed/03.ok"

verify_installed() {
  bash -c "$VERIFY_CMD" >/dev/null 2>&1
}

verb_install() {
  write_install_paths \
    --tool   "Node.js (LTS)" \
    --source "apt repo (Debian/Ubuntu) | dnf | brew" \
    --temp   "/var/cache/apt/archives | $TMPDIR/scripts-fixer/nodejs" \
    --target "/usr/bin/node + /usr/bin/npm"
  log_info "[03] Starting Node.js LTS installer"
  if verify_installed; then
    log_ok "[03] Already installed: nodejs npm"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  local method
  method=$(resolve_install_method "$CONFIG")
  log_info "[03] Resolution method: $method"
  case "$method" in
    apt)
      if ! is_debian_family; then log_warn "[03] Not a Debian-family distro"; return 1; fi
      log_info "[03] Installing via apt: nodejs npm"
      sudo apt-get update -y >/dev/null 2>&1 || true
      if sudo apt-get install -y $INSTALL_APT; then
        log_ok "[03] Installed: nodejs npm"
        mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      else
        log_err "[03] apt install failed for: nodejs npm"; return 1
      fi
      ;;
    none|*)
      log_err "[03] No supported install method on this system"
      return 1
      ;;
  esac
}

verb_check() {
  if verify_installed; then
    log_ok "[03] Verify OK"
    return 0
  fi
  log_warn "[03] Verify FAILED -- run: bash $SCRIPT_DIR/run.sh repair"
  return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if [ -z "$UNINSTALL_APT" ]; then log_warn "[03] No uninstall mapping"; return 0; fi
  if is_debian_family && is_apt_available; then
    log_info "[03] Uninstalling: $UNINSTALL_APT"
    sudo apt-get remove -y $UNINSTALL_APT && rm -f "$INSTALLED_MARK"
  fi
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[03] Unknown verb: $1"; exit 2 ;;
esac
