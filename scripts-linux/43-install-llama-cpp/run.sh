#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="43"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 43-install-llama-cpp"; exit 1; }
has_jq || { log_err "[43] jq required to read config"; exit 1; }

APT_DEPS=$(jq -r '.install.aptDeps | join(" ")' "$CONFIG")
REPO_URL=$(jq -r '.install.repoUrl' "$CONFIG")
SRC_DIR_RAW=$(jq -r '.install.srcDir' "$CONFIG")
BUILD_DIR_RAW=$(jq -r '.install.buildDir' "$CONFIG")
BIN_DIR_RAW=$(jq -r '.install.binDir' "$CONFIG")
SRC_DIR="${SRC_DIR_RAW//\$\{HOME\}/$HOME}"
BUILD_DIR="${BUILD_DIR_RAW//\$\{HOME\}/$HOME}"
BIN_DIR="${BIN_DIR_RAW//\$\{HOME\}/$HOME}"
mapfile -t BINARIES < <(jq -r '.install.binaries[]' "$CONFIG")
mapfile -t CMAKE_FLAGS < <(jq -r '.install.cmakeFlags[]' "$CONFIG")
INSTALLED_MARK="$ROOT/.installed/43.ok"

verify_installed() {
  [ -x "$BIN_DIR/llama-cli" ] || return 1
  "$BIN_DIR/llama-cli" --version >/dev/null 2>&1
}

verb_install() {
  write_install_paths \
    --tool   "llama.cpp (build from source)" \
    --source "https://github.com/ggerganov/llama.cpp (git clone + cmake)" \
    --temp   "$TMPDIR/scripts-fixer/llama-cpp" \
    --target "/usr/local/bin/llama-* (cli binaries)"
  log_info "[43] Starting llama.cpp build-from-source installer"
  if verify_installed; then
    log_ok "[43] Already installed"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  if ! is_debian_family || ! is_apt_available; then
    log_err "[43] apt required (Debian/Ubuntu family)"; return 1
  fi
  log_info "[43] Installing build deps: $APT_DEPS"
  if ! sudo apt-get install -y $APT_DEPS; then
    log_err "[43] apt build deps failed"; return 1
  fi
  mkdir -p "$(dirname "$SRC_DIR")" "$BIN_DIR" || { log_file_error "$(dirname "$SRC_DIR")" "src/bin parent mkdir failed"; return 1; }
  if [ -d "$SRC_DIR/.git" ]; then
    log_info "[43] Existing repo found, pulling latest in $SRC_DIR"
    if ! git -C "$SRC_DIR" pull --ff-only; then
      log_file_error "$SRC_DIR" "git pull failed (will rebuild from existing tree)"
    fi
  else
    log_info "[43] Cloning $REPO_URL into $SRC_DIR"
    if ! git clone --depth 1 "$REPO_URL" "$SRC_DIR"; then
      log_file_error "$SRC_DIR" "git clone failed (url=$REPO_URL, dest=$SRC_DIR)"; return 1
    fi
  fi
  mkdir -p "$BUILD_DIR" || { log_file_error "$BUILD_DIR" "build dir mkdir failed"; return 1; }
  log_info "[43] cmake configure in $BUILD_DIR"
  if ! cmake -S "$SRC_DIR" -B "$BUILD_DIR" "${CMAKE_FLAGS[@]}"; then
    log_file_error "$BUILD_DIR" "cmake configure failed"; return 1
  fi
  log_info "[43] cmake build (parallel) in $BUILD_DIR"
  if ! cmake --build "$BUILD_DIR" --config Release -j "$(nproc 2>/dev/null || echo 2)"; then
    log_file_error "$BUILD_DIR" "cmake build failed"; return 1
  fi
  log_info "[43] Symlinking binaries into $BIN_DIR"
  for b in "${BINARIES[@]}"; do
    local built="$BUILD_DIR/bin/$b"
    if [ ! -x "$built" ]; then
      log_file_error "$built" "expected built binary missing after build"; continue
    fi
    if ! ln -sf "$built" "$BIN_DIR/$b"; then
      log_file_error "$BIN_DIR/$b" "symlink failed (target=$built)"
    fi
  done
  if verify_installed; then
    log_ok "[43] Verify OK (llama-cli --version)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[43] Verify FAILED after build"; return 1
}
verb_check()     { if verify_installed; then log_ok "[43] Verify OK"; return 0; fi; log_warn "[43] Verify FAILED"; return 1; }
verb_repair()    { rm -rf "$BUILD_DIR"; rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  for b in "${BINARIES[@]}"; do
    rm -f "$BIN_DIR/$b" || log_file_error "$BIN_DIR/$b" "symlink removal failed"
  done
  rm -rf "$SRC_DIR" || log_file_error "$SRC_DIR" "source tree removal failed"
  rm -f "$INSTALLED_MARK"
  log_ok "[43] Removed source tree + symlinks (apt build deps left intact)"
}
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[43] Unknown verb: $1"; exit 2 ;;
esac
