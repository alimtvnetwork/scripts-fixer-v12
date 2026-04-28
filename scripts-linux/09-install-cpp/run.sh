#!/usr/bin/env bash
# 09-install-cpp -- C++ toolchain (build-essential, gdb, cmake)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="09"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 09-install-cpp"; exit 1; }

INSTALL_APT="build-essential gdb cmake"
VERIFY_CMD='g++ --version'
UNINSTALL_APT="build-essential gdb cmake"
INSTALLED_MARK="$ROOT/.installed/09.ok"

verify_installed() {
  bash -c "$VERIFY_CMD" >/dev/null 2>&1
}

verb_install() {
  write_install_paths \
    --tool   "C++ toolchain (gcc/g++/make)" \
    --source "apt build-essential | dnf @development-tools | brew" \
    --temp   "/var/cache/apt/archives | $TMPDIR/scripts-fixer/cpp" \
    --target "/usr/bin/g++ + /usr/bin/gcc + /usr/bin/make"
  log_info "[09] Starting C++ toolchain (build-essential, gdb, cmake) installer"
  if verify_installed; then
    log_ok "[09] Already installed: build-essential gdb cmake"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  local method
  method=$(resolve_install_method "$CONFIG")
  log_info "[09] Resolution method: $method"
  case "$method" in
    apt)
      if ! is_debian_family; then log_warn "[09] Not a Debian-family distro"; return 1; fi
      log_info "[09] Installing via apt: build-essential gdb cmake"
      sudo apt-get update -y >/dev/null 2>&1 || true
      if sudo apt-get install -y $INSTALL_APT; then
        log_ok "[09] Installed: build-essential gdb cmake"
        mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      else
        log_err "[09] apt install failed for: build-essential gdb cmake"; return 1
      fi
      ;;
    none|*)
      log_err "[09] No supported install method on this system"
      return 1
      ;;
  esac
}

verb_check() {
  if verify_installed; then
    log_ok "[09] Verify OK"
    return 0
  fi
  log_warn "[09] Verify FAILED -- run: bash $SCRIPT_DIR/run.sh repair"
  return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if [ -z "$UNINSTALL_APT" ]; then log_warn "[09] No uninstall mapping"; return 0; fi
  if is_debian_family && is_apt_available; then
    log_info "[09] Uninstalling: $UNINSTALL_APT"
    sudo apt-get remove -y $UNINSTALL_APT && rm -f "$INSTALLED_MARK"
  fi
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[09] Unknown verb: $1"; exit 2 ;;
esac
