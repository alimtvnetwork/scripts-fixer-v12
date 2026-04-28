#!/usr/bin/env bash
# 07-install-git -- Git
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="07"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
# Single source of truth for global git config defaults (cross-OS).
. "$ROOT/_shared/git-config-defaults.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 07-install-git"; exit 1; }

INSTALL_APT="git"
VERIFY_CMD='git --version'
UNINSTALL_APT="git"
INSTALLED_MARK="$ROOT/.installed/07.ok"

verify_installed() {
  bash -c "$VERIFY_CMD" >/dev/null 2>&1
}

verb_install() {
  write_install_paths \
    --tool   "Git" \
    --source "apt | dnf | brew" \
    --temp   "/var/cache/apt/archives | $TMPDIR/scripts-fixer/git" \
    --target "/usr/bin/git"
  log_info "[07] Starting Git installer"
  if verify_installed; then
    log_ok "[07] Already installed: git"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    verb_configure || true
    return 0
  fi
  local method
  method=$(resolve_install_method "$CONFIG")
  log_info "[07] Resolution method: $method"
  case "$method" in
    apt)
      if ! is_debian_family; then log_warn "[07] Not a Debian-family distro"; return 1; fi
      log_info "[07] Installing via apt: git"
      sudo apt-get update -y >/dev/null 2>&1 || true
      if sudo apt-get install -y $INSTALL_APT; then
        log_ok "[07] Installed: git"
        mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
        verb_configure || true
      else
        log_err "[07] apt install failed for: git"; return 1
      fi
      ;;
    none|*)
      log_err "[07] No supported install method on this system"
      return 1
      ;;
  esac
}

verb_check() {
  if verify_installed; then
    log_ok "[07] Verify OK"
    return 0
  fi
  log_warn "[07] Verify FAILED -- run: bash $SCRIPT_DIR/run.sh repair"
  return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

# Apply the cross-OS global git defaults defined in
# scripts/shared/git-config-defaults.json. Pure delegation -- the helper is
# the same one used by Windows scripts/07-install-git/helpers/git.ps1.
verb_configure() {
  if ! command -v git >/dev/null 2>&1; then
    log_warn "[07] git not on PATH yet -- skipping configure"
    return 0
  fi
  apply_default_git_config "$@"
}

verb_uninstall() {
  if [ -z "$UNINSTALL_APT" ]; then log_warn "[07] No uninstall mapping"; return 0; fi
  if is_debian_family && is_apt_available; then
    log_info "[07] Uninstalling: $UNINSTALL_APT"
    sudo apt-get remove -y $UNINSTALL_APT && rm -f "$INSTALLED_MARK"
  fi
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  configure) shift; verb_configure "$@" ;;
  uninstall) verb_uninstall ;;
  *) log_err "[07] Unknown verb: $1"; exit 2 ;;
esac
