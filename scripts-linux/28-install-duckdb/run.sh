#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="28"
. "$ROOT/_shared/logger.sh"; . "$ROOT/_shared/pkg-detect.sh"; . "$ROOT/_shared/file-error.sh"; . "$ROOT/_shared/install-paths.sh"
CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 28-install-duckdb"; exit 1; }
INSTALL_PATH="/usr/local/bin/duckdb"
INSTALLED_MARK="$ROOT/.installed/28.ok"
verify_installed() { command -v duckdb >/dev/null 2>&1 || [ -x "$INSTALL_PATH" ]; }

resolve_arch_url() {
  local arch
  arch=$(get_arch)
  case "$arch" in
    x86_64|amd64) echo "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip" ;;
    aarch64|arm64) echo "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-arm64.zip" ;;
    *) echo "" ;;
  esac
}

verb_install() {
  write_install_paths \
    --tool   "DuckDB CLI" \
    --source "https://github.com/duckdb/duckdb/releases (official binary zip)" \
    --temp   "$TMPDIR/scripts-fixer/duckdb" \
    --target "$INSTALL_PATH"
  log_info "[28] Starting DuckDB installer"
  if verify_installed; then log_ok "[28] DuckDB already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  has_curl   || { log_err "[28] curl required"; return 1; }
  command -v unzip >/dev/null 2>&1 || { log_warn "[28] unzip missing -- installing"; sudo apt-get install -y unzip || { log_err "[28] failed to install unzip"; return 1; }; }
  local url tmp_zip tmp_dir
  url=$(resolve_arch_url)
  if [ -z "$url" ]; then log_err "[28] Unsupported arch: $(get_arch)"; return 1; fi
  tmp_zip=$(mktemp /tmp/duckdb.XXXXXX.zip) || { log_file_error "/tmp" "mktemp failed for duckdb zip"; return 1; }
  tmp_dir=$(mktemp -d /tmp/duckdb.XXXXXX)  || { log_file_error "/tmp" "mktemp -d failed for duckdb extract"; return 1; }
  log_info "[28] Downloading: $url"
  if ! curl -fsSL "$url" -o "$tmp_zip"; then
    log_file_error "$tmp_zip" "DuckDB zip download failed from $url"
    rm -rf "$tmp_zip" "$tmp_dir"; return 1
  fi
  log_info "[28] Extracting to $tmp_dir"
  if ! unzip -q -o "$tmp_zip" -d "$tmp_dir"; then
    log_file_error "$tmp_zip" "unzip failed"
    rm -rf "$tmp_zip" "$tmp_dir"; return 1
  fi
  if [ ! -f "$tmp_dir/duckdb" ]; then
    log_file_error "$tmp_dir/duckdb" "duckdb binary not found after extract"
    rm -rf "$tmp_zip" "$tmp_dir"; return 1
  fi
  if ! sudo install -m 0755 "$tmp_dir/duckdb" "$INSTALL_PATH"; then
    log_file_error "$INSTALL_PATH" "install of duckdb binary failed"
    rm -rf "$tmp_zip" "$tmp_dir"; return 1
  fi
  rm -rf "$tmp_zip" "$tmp_dir"
  log_ok "[28] DuckDB installed at $INSTALL_PATH"
  mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
}
verb_check()     { if verify_installed; then log_ok "[28] duckdb detected: $(duckdb --version 2>/dev/null | head -1)"; return 0; fi; log_warn "[28] duckdb not on PATH"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo rm -f "$INSTALL_PATH"; rm -f "$INSTALLED_MARK"; log_ok "[28] DuckDB removed"; }
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[28] Unknown verb: $1"; exit 2;; esac
