#!/usr/bin/env bash
# 62-install-zsh-clear
# Safer ZSH uninstall: restore previous ~/.zshrc backup AND surgically remove
# only the marker-bounded blocks deployed by 60-install-zsh and
# 61-install-zsh-theme-switcher. Aggressive removal (~/.oh-my-zsh, chsh,
# apt purge) is opt-in only.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="62"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
INSTALLED_MARK="$ROOT/.installed/62.ok"

[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 62-install-zsh-clear"; exit 1; }
has_jq || { log_err "[62] jq required to read config"; exit 1; }

ZSHRC="$HOME/.zshrc"
OMZ_DIR="$HOME/.oh-my-zsh"

# ---------- config ----------
DO_PRE_BACKUP=$(jq -r '.backup_before_clear'        "$CONFIG")
DO_RESTORE=$(jq -r    '.restore_from_backup'        "$CONFIG")
BACKUP_ROOT_RAW=$(jq -r '.backup_root'              "$CONFIG")
# Expand leading ~ safely (no eval)
BACKUP_ROOT="${BACKUP_ROOT_RAW/#\~/$HOME}"

CFG_REMOVE_ZSHRC=$(jq -r       '.aggressive.remove_zshrc'          "$CONFIG")
CFG_REMOVE_OMZ=$(jq -r         '.aggressive.remove_oh_my_zsh_dir'  "$CONFIG")
CFG_REMOVE_PKG=$(jq -r         '.aggressive.remove_apt_zsh_pkg'    "$CONFIG")
CFG_RESTORE_SHELL_FLAG=$(jq -r '.aggressive.restore_default_shell' "$CONFIG")
CFG_RESTORE_SHELL_PATH=$(jq -r '.aggressive.restore_shell_path'    "$CONFIG")

# ---------- helpers ----------
ts_now() { date '+%Y%m%d-%H%M%S'; }

# Pre-clear safety backup -- ALWAYS lands in $BACKUP_ROOT/pre-clear-<TS>/
pre_clear_backup() {
  [ "$DO_PRE_BACKUP" = "true" ] || return 0
  local ts dest
  ts=$(ts_now)
  dest="$BACKUP_ROOT/pre-clear-$ts"
  mkdir -p "$dest" || { log_file_error "$dest" "cannot create pre-clear backup dir"; return 1; }
  if [ -f "$ZSHRC" ]; then
    cp -p "$ZSHRC" "$dest/.zshrc" && log_info "[62] Pre-clear safety backup: $ZSHRC -> $dest/.zshrc"
  fi
  echo "$dest"
}

# Pick a backup directory from $BACKUP_ROOT.
# - "latest" or empty: newest (lex-sorted, since names are timestamps).
# - <TIMESTAMP>:       exact basename (must exist).
# - <abs path>:        verbatim (must be a dir).
# Excludes pre-clear-* (those are the safety nets we just made).
choose_backup_dir() {
  local sel="${1:-latest}"
  if [ -z "$sel" ] || [ "$sel" = "latest" ]; then
    if [ ! -d "$BACKUP_ROOT" ]; then
      log_warn "[62] Backup root $BACKUP_ROOT does not exist -- nothing to restore" >&2
      return 1
    fi
    # Newest non-pre-clear dir
    local picked
    picked=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
              ! -name 'pre-clear-*' -printf '%f\n' 2>/dev/null \
             | sort -r | head -n1)
    if [ -z "$picked" ]; then
      log_warn "[62] No timestamped backups found under $BACKUP_ROOT" >&2
      return 1
    fi
    echo "$BACKUP_ROOT/$picked"
    return 0
  fi
  if [ -d "$sel" ]; then echo "$sel"; return 0; fi
  if [ -d "$BACKUP_ROOT/$sel" ]; then echo "$BACKUP_ROOT/$sel"; return 0; fi
  log_file_error "$sel" "backup selector did not resolve to a directory" >&2
  return 1
}

restore_zshrc_from() {
  local dir="$1"
  if [ ! -f "$dir/.zshrc" ]; then
    log_warn "[62] Backup $dir contains no .zshrc -- nothing to restore"
    return 1
  fi
  cp -p "$dir/.zshrc" "$ZSHRC" || { log_file_error "$ZSHRC" "cannot restore .zshrc"; return 1; }
  log_ok "[62] Restored $dir/.zshrc -> $ZSHRC"
}

# Strip a single BEGIN..END marker block from $ZSHRC (handles multiple occurrences).
# Returns 0 always; logs PASS/no-op.
strip_marker_block() {
  local name="$1" begin="$2" end="$3"
  if [ ! -f "$ZSHRC" ]; then
    log_info "[62] $ZSHRC does not exist -- skipping '$name' marker strip"
    return 0
  fi
  if ! grep -Fq "$begin" "$ZSHRC"; then
    log_info "[62] No '$name' marker block found in $ZSHRC -- skipping"
    return 0
  fi
  local before after removed
  before=$(wc -l < "$ZSHRC")
  local tmp; tmp=$(mktemp)
  awk -v b="$begin" -v e="$end" '
    BEGIN { drop = 0 }
    {
      if (drop == 0 && index($0, b) > 0) { drop = 1; next }
      if (drop == 1) {
        if (index($0, e) > 0) { drop = 0 }
        next
      }
      print
    }
  ' "$ZSHRC" > "$tmp" || { rm -f "$tmp"; log_err "[62] awk strip failed"; return 1; }
  mv "$tmp" "$ZSHRC" || { log_file_error "$ZSHRC" "cannot rewrite zshrc"; return 1; }
  after=$(wc -l < "$ZSHRC")
  removed=$((before - after))
  log_ok "[62] Stripped marker block '$name' from $ZSHRC ($removed lines removed)"
}

strip_all_markers() {
  local n; n=$(jq -r '.marker_pairs | length' "$CONFIG")
  [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i name b e
  for i in $(seq 0 $((n-1))); do
    name=$(jq -r ".marker_pairs[$i].name"  "$CONFIG")
    b=$(jq -r    ".marker_pairs[$i].begin" "$CONFIG")
    e=$(jq -r    ".marker_pairs[$i].end"   "$CONFIG")
    strip_marker_block "$name" "$b" "$e"
  done
}

clear_install_markers() {
  local n; n=$(jq -r '.clear_install_markers | length' "$CONFIG")
  [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i f path
  for i in $(seq 0 $((n-1))); do
    f=$(jq -r ".clear_install_markers[$i]" "$CONFIG")
    path="$ROOT/.installed/$f"
    if [ -f "$path" ]; then
      rm -f "$path" && log_info "[62] Cleared install marker $path"
    fi
  done
  rm -f "$INSTALLED_MARK"
}

# ---------- aggressive ops (opt-in) ----------
agg_remove_zshrc() {
  [ -f "$ZSHRC" ] || return 0
  rm -f "$ZSHRC" && log_warn "[62] Removed $ZSHRC"
}
agg_remove_omz() {
  [ -d "$OMZ_DIR" ] || return 0
  rm -rf "$OMZ_DIR" && log_warn "[62] Removed $OMZ_DIR"
}
agg_apt_purge_zsh() {
  if ! is_debian_family || ! is_apt_available; then
    log_err "[62] apt purge requested but apt-get not available"; return 1
  fi
  log_warn "[62] apt-get purge zsh requested"
  sudo apt-get purge -y zsh || log_err "[62] apt purge zsh failed"
}
agg_chsh_restore() {
  local sh="$CFG_RESTORE_SHELL_PATH"
  [ -x "$sh" ] || { log_err "[62] restore shell $sh not executable"; return 1; }
  if chsh -s "$sh" 2>/dev/null; then
    log_ok "[62] Default shell restored to $sh"
  else
    log_warn "[62] chsh failed (non-interactive shell, no PAM, or insufficient perms)"
  fi
}

# ---------- verbs ----------
verb_install() {
  log_info "[62] Starting safer ZSH uninstall (restore + surgical strip)"

  # Per-run aggressive flag overrides (always opt-in)
  local AGG_RM_ZSHRC="$CFG_REMOVE_ZSHRC"
  local AGG_RM_OMZ="$CFG_REMOVE_OMZ"
  local AGG_RM_PKG="$CFG_REMOVE_PKG"
  local AGG_CHSH="$CFG_RESTORE_SHELL_FLAG"
  local backup_sel="latest"
  local applied=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --remove-zshrc)       AGG_RM_ZSHRC=true ;;
      --remove-omz)         AGG_RM_OMZ=true ;;
      --remove-zsh-pkg)     AGG_RM_PKG=true ;;
      --restore-shell)      AGG_CHSH=true ;;
      --no-restore)         DO_RESTORE=false ;;
      --backup=*)           backup_sel="${arg#--backup=}" ;;
      --backup-latest)      backup_sel="latest" ;;
    esac
  done

  pre_clear_backup >/dev/null

  # 1. Restore previous backup (default ON)
  if [ "$DO_RESTORE" = "true" ]; then
    local pick
    if pick=$(choose_backup_dir "$backup_sel"); then
      log_info "[62] Selected backup: $pick"
      restore_zshrc_from "$pick" || true
    else
      log_info "[62] No backup restored -- continuing with surgical strip on current ~/.zshrc"
    fi
  else
    log_info "[62] restore_from_backup disabled -- skipping restore step"
  fi

  # 2. Surgical marker strip (always)
  strip_all_markers

  # 3. Clear install markers
  clear_install_markers

  # 4. Aggressive ops (opt-in only)
  if [ "$AGG_RM_OMZ" = "true" ];   then agg_remove_omz;    applied+=("remove-omz"); fi
  if [ "$AGG_RM_ZSHRC" = "true" ]; then agg_remove_zshrc;  applied+=("remove-zshrc"); fi
  if [ "$AGG_CHSH" = "true" ];     then agg_chsh_restore;  applied+=("restore-shell"); fi
  if [ "$AGG_RM_PKG" = "true" ];   then agg_apt_purge_zsh; applied+=("remove-zsh-pkg"); fi

  mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"

  if [ ${#applied[@]} -eq 0 ]; then
    log_ok "[62] Done (safe mode). Open a new shell to verify."
  else
    log_warn "[62] Done (aggressive mode applied: ${applied[*]})"
  fi
}

verb_check() {
  if [ ! -f "$ZSHRC" ]; then
    log_ok "[62] ~/.zshrc does not exist -- nothing to clean"
    return 0
  fi
  local n; n=$(jq -r '.marker_pairs | length' "$CONFIG")
  local residual=()
  local i name b
  for i in $(seq 0 $((n-1))); do
    name=$(jq -r ".marker_pairs[$i].name"  "$CONFIG")
    b=$(jq -r    ".marker_pairs[$i].begin" "$CONFIG")
    if grep -Fq "$b" "$ZSHRC"; then residual+=("$name"); fi
  done
  if [ ${#residual[@]} -eq 0 ]; then
    log_ok "[62] No lovable marker blocks present in $ZSHRC"
    return 0
  fi
  log_warn "[62] Residual marker block(s) still present in $ZSHRC: ${residual[*]}"
  return 1
}

verb_strip() {
  pre_clear_backup >/dev/null
  strip_all_markers
}

verb_restore() {
  local sel="${1:-latest}"
  pre_clear_backup >/dev/null
  local pick
  pick=$(choose_backup_dir "$sel") || return 1
  log_info "[62] Selected backup: $pick"
  restore_zshrc_from "$pick"
}

verb_list_backups() {
  if [ ! -d "$BACKUP_ROOT" ]; then
    log_warn "[62] Backup root $BACKUP_ROOT does not exist"; return 1
  fi
  local rows
  rows=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
  if [ -z "$rows" ]; then
    log_warn "[62] No backups under $BACKUP_ROOT"; return 1
  fi
  echo "Backups in $BACKUP_ROOT (newest first):"
  local d has_zshrc
  while IFS= read -r d; do
    if [ -f "$BACKUP_ROOT/$d/.zshrc" ]; then has_zshrc='zshrc:yes'; else has_zshrc='zshrc:no '; fi
    printf "  %-32s  %s\n" "$d" "$has_zshrc"
  done <<< "$rows"
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install "$@"; }

verb_uninstall() {
  log_info "[62] uninstall verb only clears the 62-clear install marker"
  rm -f "$INSTALLED_MARK"
}

# ---------- arg parsing ----------
case "${1:-install}" in
  install)       shift || true; verb_install "$@" ;;
  check)         verb_check ;;
  strip)         verb_strip ;;
  restore)       shift || true; verb_restore "$@" ;;
  list-backups)  verb_list_backups ;;
  repair)        shift || true; verb_repair "$@" ;;
  uninstall)     verb_uninstall ;;
  *) log_err "[62] Unknown verb: $1 (expected install|check|strip|restore|list-backups|repair|uninstall)"; exit 2 ;;
esac
