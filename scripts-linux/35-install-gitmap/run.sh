#!/usr/bin/env bash
# 35-install-gitmap -- gitmap CLI (curl one-liner from gitmap-v8)
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

INSTALL_URL="$(jq -r '.install.installUrl // "https://raw.githubusercontent.com/alimtvnetwork/gitmap-v8/main/gitmap/scripts/install.sh"' "$CONFIG" 2>/dev/null)"
REPO="$(jq -r '.install.repo // "alimtvnetwork/gitmap-v8"' "$CONFIG" 2>/dev/null)"

# Where the upstream installer drops the binary by default.
BIN_DIR="${HOME}/.local/bin"
DEST="$BIN_DIR/gitmap"
INSTALLED_MARK="$ROOT/.installed/35.ok"

verify_installed() { command -v gitmap >/dev/null 2>&1 || [ -x "$DEST" ]; }

installed_version() {
  if command -v gitmap >/dev/null 2>&1; then gitmap version 2>/dev/null || gitmap --version 2>/dev/null || true; return; fi
  if [ -x "$DEST" ]; then "$DEST" version 2>/dev/null || "$DEST" --version 2>/dev/null || true; fi
}

version_key() { printf '%s' "$1" | grep -Eo 'v?[0-9]+([.][0-9]+){0,3}' | head -1 | sed 's/^v//'; }

remote_version() {
  local api="https://api.github.com/repos/${REPO}/releases/latest" tag_api="https://api.github.com/repos/${REPO}/tags" tag=""
  log_info "[35] Checking latest GitMap release: $api"
  if command -v curl >/dev/null 2>&1; then
    tag="$(curl -fsSL -H 'User-Agent: scripts-fixer-gitmap' "$api" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    [ -n "$tag" ] || tag="$(curl -fsSL -H 'User-Agent: scripts-fixer-gitmap' "$tag_api" 2>/dev/null | grep '"name"' | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | grep -E 'v?[0-9]+([.][0-9]+)+' | sort -Vr | head -1)"
  elif command -v wget >/dev/null 2>&1; then
    tag="$(wget -qO- --header='User-Agent: scripts-fixer-gitmap' "$api" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    [ -n "$tag" ] || tag="$(wget -qO- --header='User-Agent: scripts-fixer-gitmap' "$tag_api" 2>/dev/null | grep '"name"' | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | grep -E 'v?[0-9]+([.][0-9]+)+' | sort -Vr | head -1)"
  else
    log_file_error "(curl|wget)" "no downloader available to check GitMap remote release"
  fi
  printf '%s' "$tag"
}

is_remote_newer() {
  local installed_key remote_key newest
  installed_key="$(version_key "$1")"; remote_key="$(version_key "$2")"
  [ -n "$installed_key" ] && [ -n "$remote_key" ] || return 2
  newest="$(printf '%s\n%s\n' "$installed_key" "$remote_key" | sort -V | tail -1)"
  [ "$newest" = "$remote_key" ] && [ "$installed_key" != "$remote_key" ]
}

verb_install() {
  write_install_paths \
    --tool   "gitmap" \
    --source "$INSTALL_URL (curl | bash)" \
    --temp   "${TMPDIR:-/tmp}/scripts-fixer/gitmap" \
    --target "$DEST"

  log_info "[35] Starting gitmap installer"
  remote_ver="$(remote_version)"
  if verify_installed; then
    local_ver="$(installed_version | head -1)"
    log_ok "[35] Already installed${local_ver:+ ($local_ver)}"
    if [ -n "$remote_ver" ]; then
      log_info "[35] Latest remote GitMap version: $remote_ver"
      if is_remote_newer "$local_ver" "$remote_ver"; then
        log_info "[35] Update available (installed: $local_ver, remote: $remote_ver) -- running installer"
      else
        cmp_status=$?
        if [ "$cmp_status" -eq 2 ]; then
          log_warn "[35] Could not compare versions (installed: $local_ver, remote: $remote_ver) -- running installer to be safe"
        else
          log_ok "[35] GitMap is up to date -- installer skipped"
          mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
        fi
      fi
    else
      log_warn "[35] Could not resolve remote GitMap version -- installed GitMap kept, installer skipped"
      mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
    fi
  elif [ -n "$remote_ver" ]; then
    log_info "[35] Latest remote GitMap version: $remote_ver"
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
