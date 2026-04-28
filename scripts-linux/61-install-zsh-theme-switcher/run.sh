#!/usr/bin/env bash
# 61-install-zsh-theme-switcher
# Wires a 'zsh-theme' command into ~/.zshrc and provides install/check/switch verbs.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="61"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
PAYLOAD="$SCRIPT_DIR/payload/zsh-theme-fn.zsh"
ZSHRC="$HOME/.zshrc"
INSTALLED_MARK="$ROOT/.installed/61.ok"

[ -f "$CONFIG" ]  || { log_file_error "$CONFIG"  "config.json missing for 61-install-zsh-theme-switcher"; exit 1; }
[ -f "$PAYLOAD" ] || { log_file_error "$PAYLOAD" "payload/zsh-theme-fn.zsh missing"; exit 1; }
has_jq || { log_err "[61] jq required to read config"; exit 1; }

MARK_BEGIN=$(jq -r '.marker_begin' "$CONFIG")
MARK_END=$(jq -r   '.marker_end'   "$CONFIG")
FN_NAME=$(jq -r    '.shell_function_name' "$CONFIG")
DEFAULT_THEME=$(jq -r '.default_theme' "$CONFIG")

# ---------- helpers ----------
zshrc_has_block() {
  [ -f "$ZSHRC" ] && grep -Fq "$MARK_BEGIN" "$ZSHRC"
}

zshrc_has_theme_line() {
  [ -f "$ZSHRC" ] && grep -qE '^ZSH_THEME=' "$ZSHRC"
}

omz_present() {
  [ -d "${ZSH:-$HOME/.oh-my-zsh}" ]
}

theme_in_config() {
  local name="$1"
  jq -r '.themes[], .custom_themes[]' "$CONFIG" | grep -Fxq "$name"
}

backup_zshrc() {
  if [ -f "$ZSHRC" ]; then
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    cp -p "$ZSHRC" "$ZSHRC.backup-$ts"
    log_info "[61] Backed up $ZSHRC -> $ZSHRC.backup-$ts"
  fi
}

inject_block() {
  # Substitute the placeholder for the real config path, then append between markers.
  local rendered
  rendered=$(sed "s|__LOVABLE_CFG_PATH__|$CONFIG|g" "$PAYLOAD")
  {
    echo ""
    echo "$MARK_BEGIN"
    # The payload file already includes its own marker comments at top/bottom;
    # but we re-emit our markers so removal is unambiguous if the payload changes.
    echo "$rendered"
    echo "$MARK_END"
  } >> "$ZSHRC"
}

remove_block() {
  [ -f "$ZSHRC" ] || return 0
  # Delete from MARK_BEGIN through MARK_END inclusive (handles the inner copy too).
  local tmp; tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    BEGIN { skip=0 }
    index($0, b)>0 { skip=1; next }
    skip && index($0, e)>0 { skip=0; next }
    !skip { print }
  ' "$ZSHRC" > "$tmp" && mv "$tmp" "$ZSHRC"
}

set_zsh_theme_line() {
  local theme="$1"
  if zshrc_has_theme_line; then
    sed -i.bak -E "s|^ZSH_THEME=.*|ZSH_THEME=\"${theme}\"|" "$ZSHRC"
  else
    echo "ZSH_THEME=\"${theme}\"" >> "$ZSHRC"
  fi
}

# ---------- verbs ----------
verb_install() {
  write_install_paths \
    --tool   "ZSH theme switcher" \
    --source "$SCRIPT_DIR/payload (zsh-theme command + helper functions)" \
    --temp   "$TMPDIR/scripts-fixer/zsh-theme-switcher" \
    --target "$HOME/.zshrc (marker block) + $HOME/.local/bin/zsh-theme"
  log_info "[61] Starting ZSH theme switcher installer"

  if [ ! -f "$ZSHRC" ]; then
    log_warn "[61] ~/.zshrc not found -- creating a minimal one"
    cat > "$ZSHRC" <<EOF
# Created by 61-install-zsh-theme-switcher
export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="$DEFAULT_THEME"
plugins=(git)
[ -f "\$ZSH/oh-my-zsh.sh" ] && source "\$ZSH/oh-my-zsh.sh"
EOF
  fi

  if ! omz_present; then
    log_warn "[61] Oh-My-Zsh not detected at ~/.oh-my-zsh -- the wired command will still work but theme changes only take effect once OMZ is installed (run script 60)."
  fi

  if zshrc_has_block; then
    log_ok "[61] Shell function '$FN_NAME' already present in $ZSHRC"
  else
    backup_zshrc
    inject_block
    log_ok "[61] Wired '$FN_NAME' shell function into $ZSHRC"
  fi

  if ! zshrc_has_theme_line; then
    set_zsh_theme_line "$DEFAULT_THEME"
    log_info "[61] Set initial ZSH_THEME=\"$DEFAULT_THEME\""
  fi

  mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
  log_ok "[61] Done. Open a new terminal (or 'source ~/.zshrc') and run: $FN_NAME"
  return 0
}

verb_check() {
  local ok=1 reason=""
  if ! zshrc_has_block; then ok=0; reason="wiring block missing"; fi
  if ! zshrc_has_theme_line; then ok=0; reason="${reason:+$reason; }ZSH_THEME line missing"; fi
  if [ "$ok" = "1" ]; then
    log_ok "[61] Verify OK ($FN_NAME wired + ZSH_THEME present)"
    return 0
  fi
  log_warn "[61] Verify FAILED ($reason)"
  return 1
}

verb_repair()    { remove_block; rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  remove_block
  rm -f "$INSTALLED_MARK"
  log_ok "[61] Removed wiring block from $ZSHRC (ZSH_THEME line preserved)"
}

verb_list() {
  jq -r '.themes[], .custom_themes[]' "$CONFIG"
}

verb_switch() {
  local theme="${1:-}"
  local force=0
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
    esac
  done

  if [ -z "$theme" ]; then
    log_err "[61] switch requires a theme name. Try: $0 list"
    return 2
  fi
  if [ "$force" = "0" ] && ! theme_in_config "$theme"; then
    log_warn "[61] Theme '$theme' is not in the configured list (use --force to bypass)"
    return 2
  fi
  if [ ! -f "$ZSHRC" ]; then
    log_file_error "$ZSHRC" "~/.zshrc does not exist; run 'install' first"
    return 1
  fi
  log_info "[61] Switching ZSH_THEME to '$theme' in $ZSHRC"
  set_zsh_theme_line "$theme"
  log_ok "[61] ZSH_THEME set to '$theme'. Run 'exec zsh' or open a new terminal to apply."
}

# ---------- arg parsing ----------
VERB="${1:-install}"
shift || true

# Support: --theme NAME --no-prompt   (per spec §2 row 2)
if [ "$VERB" = "install" ]; then
  THEME=""; NO_PROMPT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --theme)     THEME="$2"; shift 2 ;;
      --no-prompt) NO_PROMPT=1; shift ;;
      *)           shift ;;
    esac
  done
  verb_install
  if [ -n "$THEME" ]; then
    verb_switch "$THEME" $( [ "$NO_PROMPT" = "1" ] && echo --force )
  fi
  exit 0
fi

case "$VERB" in
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  list)      verb_list ;;
  switch)    verb_switch "$@" ;;
  *)         log_err "[61] Unknown verb: $VERB (expected install|check|repair|uninstall|list|switch)"; exit 2 ;;
esac
