#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="11"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 11-install-vscode-settings-sync"; exit 1; }
has_jq || { log_err "[11] jq required to read config"; exit 1; }

VSCODE_DIR_RAW=$(jq -r '.install.vscodeUserDir' "$CONFIG")
VSCODE_DIR="${VSCODE_DIR_RAW//\$\{HOME\}/$HOME}"
PAYLOAD_DIR="$SCRIPT_DIR/$(jq -r '.install.payloadDir' "$CONFIG")"
EXT_FILE="$PAYLOAD_DIR/$(jq -r '.install.extensionsList' "$CONFIG")"
mapfile -t FILES < <(jq -r '.install.files[]' "$CONFIG")
INSTALLED_MARK="$ROOT/.installed/11.ok"

verify_installed() {
  for f in "${FILES[@]}"; do
    [ -f "$VSCODE_DIR/$f" ] || return 1
  done
  return 0
}

verb_install() {
  write_install_paths \
    --tool   "VS Code settings sync" \
    --source "$SCRIPT_DIR/payload (curated settings.json + extensions list)" \
    --temp   "$TMPDIR/scripts-fixer/vscode-sync" \
    --target "$HOME/.config/Code/User/settings.json + installed extensions"
  log_info "[11] Starting VS Code settings sync"
  if [ ! -d "$VSCODE_DIR" ] && ! command -v code >/dev/null 2>&1; then
    log_warn "[11] VS Code not detected (missing 'code' on PATH and missing $VSCODE_DIR) — skipping"
    return 0
  fi
  log_info "[11] Ensuring VS Code user dir exists: $VSCODE_DIR"
  if ! mkdir -p "$VSCODE_DIR"; then
    log_file_error "$VSCODE_DIR" "mkdir failed"; return 1
  fi
  local ts backup
  ts=$(date +%Y%m%d-%H%M%S)
  backup="$VSCODE_DIR/.backup-$ts"
  local need_backup=0
  for f in "${FILES[@]}"; do [ -f "$VSCODE_DIR/$f" ] && need_backup=1; done
  if [ "$need_backup" -eq 1 ]; then
    log_info "[11] Backing up existing settings to $backup"
    if ! mkdir -p "$backup"; then
      log_file_error "$backup" "backup mkdir failed"; return 1
    fi
    for f in "${FILES[@]}"; do
      if [ -f "$VSCODE_DIR/$f" ]; then
        cp "$VSCODE_DIR/$f" "$backup/$f" || log_file_error "$backup/$f" "backup copy failed"
      fi
    done
  fi
  for f in "${FILES[@]}"; do
    local src="$PAYLOAD_DIR/$f"
    local dst="$VSCODE_DIR/$f"
    [ -f "$src" ] || { log_file_error "$src" "payload file missing"; return 1; }
    log_info "[11] Deploying $f -> $dst"
    if ! cp "$src" "$dst"; then
      log_file_error "$dst" "deploy copy failed (src=$src)"; return 1
    fi
  done
  if command -v code >/dev/null 2>&1 && [ -f "$EXT_FILE" ]; then
    log_info "[11] Installing extensions from $EXT_FILE"
    while IFS= read -r ext; do
      [ -n "$ext" ] && code --install-extension "$ext" --force >/dev/null 2>&1 || true
    done < "$EXT_FILE"
  else
    log_info "[11] Skipping extensions (no 'code' CLI on PATH)"
  fi
  if verify_installed; then
    log_ok "[11] Verify OK (settings + keybindings present)"
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[11] Verify FAILED after deploy"; return 1
}
verb_check()     { if verify_installed; then log_ok "[11] Verify OK"; return 0; fi; log_warn "[11] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  for f in "${FILES[@]}"; do
    rm -f "$VSCODE_DIR/$f" || log_file_error "$VSCODE_DIR/$f" "removal failed"
  done
  rm -f "$INSTALLED_MARK"
  log_ok "[11] Removed deployed VS Code settings (backups under $VSCODE_DIR/.backup-* preserved)"
}
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[11] Unknown verb: $1"; exit 2 ;;
esac
