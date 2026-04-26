#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="38"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 38-install-flutter"; exit 1; }
has_jq || { log_err "[38] jq required to read config"; exit 1; }

SNAP_NAME=$(jq -r '.install.snapName' "$CONFIG")
SNAP_CLASSIC=$(jq -r '.install.snapClassic' "$CONFIG")
INDEX_URL=$(jq -r '.install.fallback.indexUrl' "$CONFIG")
BASE_URL=$(jq -r '.install.fallback.baseUrl' "$CONFIG")
DEST_DIR_RAW=$(jq -r '.install.fallback.destDir' "$CONFIG")
BIN_DIR_RAW=$(jq -r '.install.fallback.binDir' "$CONFIG")
DEST_DIR="${DEST_DIR_RAW//\$\{HOME\}/$HOME}"
BIN_DIR="${BIN_DIR_RAW//\$\{HOME\}/$HOME}"
APT_DEPS=$(jq -r '.install.aptDeps | join(" ")' "$CONFIG")
INSTALLED_MARK="$ROOT/.installed/38.ok"

verify_installed() { command -v flutter >/dev/null 2>&1 && flutter --version >/dev/null 2>&1; }

install_via_snap() {
  command -v snap >/dev/null 2>&1 || return 1
  log_info "[38] Trying snap install (classic): $SNAP_NAME"
  if [ "$SNAP_CLASSIC" = "true" ]; then
    sudo snap install "$SNAP_NAME" --classic
  else
    sudo snap install "$SNAP_NAME"
  fi
}

install_via_tarball() {
  has_curl || { log_err "[38] curl required for tarball fallback"; return 1; }
  if is_debian_family && is_apt_available; then
    log_info "[38] Installing apt deps: $APT_DEPS"
    sudo apt-get install -y $APT_DEPS || log_warn "[38] apt deps install partial — continuing"
  fi
  log_info "[38] Fetching Flutter release index: $INDEX_URL"
  local idx_tmp archive_path
  idx_tmp=$(mktemp /tmp/flutter-idx.XXXXXX.json) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL "$INDEX_URL" -o "$idx_tmp"; then
    log_file_error "$idx_tmp" "Failed to fetch release index from $INDEX_URL"; rm -f "$idx_tmp"; return 1
  fi
  archive_path=$(jq -r '.current_release.stable as $h | .releases[] | select(.hash==$h) | .archive' "$idx_tmp")
  rm -f "$idx_tmp"
  if [ -z "$archive_path" ] || [ "$archive_path" = "null" ]; then
    log_err "[38] Could not parse stable archive path from release index"; return 1
  fi
  local url="$BASE_URL/$archive_path"
  local tar_tmp
  tar_tmp=$(mktemp /tmp/flutter-sdk.XXXXXX.tar.xz) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  log_info "[38] Downloading Flutter SDK: $url"
  if ! curl -fL "$url" -o "$tar_tmp"; then
    log_file_error "$tar_tmp" "Download failed from $url"; rm -f "$tar_tmp"; return 1
  fi
  mkdir -p "$DEST_DIR" "$BIN_DIR" || { log_file_error "$DEST_DIR" "dest dir mkdir failed"; rm -f "$tar_tmp"; return 1; }
  log_info "[38] Extracting SDK into $DEST_DIR"
  if ! tar -xJf "$tar_tmp" -C "$(dirname "$DEST_DIR")"; then
    log_file_error "$DEST_DIR" "Extract failed (archive=$tar_tmp)"; rm -f "$tar_tmp"; return 1
  fi
  rm -f "$tar_tmp"
  log_info "[38] Symlinking flutter into $BIN_DIR"
  if ! ln -sf "$DEST_DIR/bin/flutter" "$BIN_DIR/flutter"; then
    log_file_error "$BIN_DIR/flutter" "Symlink failed (target=$DEST_DIR/bin/flutter)"; return 1
  fi
  ln -sf "$DEST_DIR/bin/dart" "$BIN_DIR/dart" 2>/dev/null || true
}

verb_install() {
  log_info "[38] Starting Flutter installer"
  if verify_installed; then
    log_ok "[38] Already installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  if install_via_snap; then
    log_ok "[38] Installed via snap"
  else
    log_warn "[38] snap install failed — falling back to tarball method"
    install_via_tarball || return 1
  fi
  if verify_installed; then
    log_ok "[38] Verify OK (flutter --version)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[38] Verify FAILED after install"; return 1
}
verb_check()     { if verify_installed; then log_ok "[38] Verify OK"; return 0; fi; log_warn "[38] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  command -v snap >/dev/null 2>&1 && sudo snap remove "$SNAP_NAME" 2>/dev/null || true
  rm -f "$BIN_DIR/flutter" "$BIN_DIR/dart" || true
  rm -rf "$DEST_DIR" || log_file_error "$DEST_DIR" "tarball SDK removal failed"
  rm -f "$INSTALLED_MARK"
  log_ok "[38] Removed (snap + tarball + symlinks)"
}
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[38] Unknown verb: $1"; exit 2 ;;
esac
