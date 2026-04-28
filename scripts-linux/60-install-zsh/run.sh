#!/usr/bin/env bash
# 60-install-zsh
# Installs zsh + Oh-My-Zsh, deploys curated .zshrc payloads, auto-backs up
# any existing config, and clones custom plugins (zsh-autosuggestions etc).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="60"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
PAYLOAD_BASE="$SCRIPT_DIR/payload/zshrc-base"
PAYLOAD_EXTRAS="$SCRIPT_DIR/payload/zshrc-extras"
INSTALLED_MARK="$ROOT/.installed/60.ok"
BACKUP_DIR="$HOME/.zsh-backups"
EXTRAS_MARKER_BEGIN="# >>> lovable zsh extras >>>"
EXTRAS_MARKER_END="# <<< lovable zsh extras <<<"

[ -f "$CONFIG" ]         || { log_file_error "$CONFIG"         "config.json missing for 60-install-zsh"; exit 1; }
[ -f "$PAYLOAD_BASE" ]   || { log_file_error "$PAYLOAD_BASE"   "payload/zshrc-base missing"; exit 1; }
[ -f "$PAYLOAD_EXTRAS" ] || { log_file_error "$PAYLOAD_EXTRAS" "payload/zshrc-extras missing"; exit 1; }
has_jq || { log_err "[60] jq required to read config"; exit 1; }

APT_PKG=$(jq -r '.install.apt'             "$CONFIG")
DEFAULT_THEME=$(jq -r '.default_theme'     "$CONFIG")
OMZ_URL=$(jq -r '.omz_install_url'         "$CONFIG")
DO_DEPLOY_BASE=$(jq -r '.deploy_zshrc'     "$CONFIG")
DO_DEPLOY_EXTRAS=$(jq -r '.deploy_extras'  "$CONFIG")
DO_BACKUP=$(jq -r '.backup_existing_zshrc' "$CONFIG")
DO_CHSH=$(jq -r '.set_default_shell'       "$CONFIG")

OMZ_DIR="$HOME/.oh-my-zsh"
ZSHRC="$HOME/.zshrc"

# ---------- helpers ----------
ts_now() { date '+%Y%m%d-%H%M%S'; }

verify_installed() {
  command -v zsh >/dev/null 2>&1 \
    && [ -d "$OMZ_DIR" ] \
    && [ -f "$ZSHRC" ]
}

backup_path() {
  # Choose a unique backup folder for this run.
  local ts; ts=$(ts_now)
  echo "$BACKUP_DIR/$ts"
}

backup_existing_config() {
  [ "$DO_BACKUP" = "true" ] || return 0
  local dest; dest=$(backup_path)
  local backed_up=0
  mkdir -p "$dest" || { log_file_error "$dest" "cannot create backup dir"; return 1; }

  if [ -f "$ZSHRC" ]; then
    cp -p "$ZSHRC" "$dest/.zshrc" && {
      log_info "[60] Backed up $ZSHRC -> $dest/.zshrc"
      backed_up=1
    }
  fi
  if [ -d "$OMZ_DIR" ]; then
    # Only metadata-snapshot the OMZ dir (full clone is huge); copy custom/ which holds user config
    if [ -d "$OMZ_DIR/custom" ]; then
      cp -rp "$OMZ_DIR/custom" "$dest/oh-my-zsh-custom" 2>/dev/null && {
        log_info "[60] Backed up $OMZ_DIR/custom -> $dest/oh-my-zsh-custom"
        backed_up=1
      }
    fi
    # Record OMZ HEAD so we know which version was replaced
    if [ -d "$OMZ_DIR/.git" ]; then
      (cd "$OMZ_DIR" && git rev-parse HEAD 2>/dev/null) > "$dest/oh-my-zsh.HEAD" || true
    fi
  fi

  if [ "$backed_up" = "0" ]; then
    rmdir "$dest" 2>/dev/null || true
    log_info "[60] Nothing to back up (no existing ~/.zshrc or ~/.oh-my-zsh)"
  fi
  return 0
}

apt_install_packages() {
  if ! is_debian_family || ! is_apt_available; then
    log_err "[60] apt-get + Debian/Ubuntu required"; return 1
  fi
  log_info "[60] Installing apt packages: $APT_PKG"
  if sudo apt-get install -y $APT_PKG; then
    return 0
  fi
  log_err "[60] apt install failed for: $APT_PKG"
  return 1
}

install_omz() {
  if [ -d "$OMZ_DIR" ]; then
    log_ok "[60] Oh-My-Zsh already present at $OMZ_DIR"
    return 0
  fi
  has_curl || { log_err "[60] curl required to install Oh-My-Zsh"; return 1; }
  log_info "[60] Installing Oh-My-Zsh (unattended) from $OMZ_URL"
  # RUNZSH=no  -> don't drop into zsh after install
  # CHSH=no    -> don't change default shell (we honor config.set_default_shell)
  # KEEP_ZSHRC=yes -> don't overwrite ~/.zshrc (we deploy our own next)
  if RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL "$OMZ_URL")"; then
    log_ok "[60] Oh-My-Zsh installed at $OMZ_DIR"
    return 0
  fi
  log_err "[60] Oh-My-Zsh installer returned non-zero"
  return 1
}

clone_custom_plugins() {
  local n
  n=$(jq -r '.custom_plugins | length' "$CONFIG")
  [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i name repo dest dest_resolved
  for i in $(seq 0 $((n-1))); do
    name=$(jq -r ".custom_plugins[$i].name" "$CONFIG")
    repo=$(jq -r ".custom_plugins[$i].repo" "$CONFIG")
    dest=$(jq -r ".custom_plugins[$i].dest" "$CONFIG")
    # Expand ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom} and friends
    dest_resolved=$(eval echo "$dest")
    if [ -d "$dest_resolved" ]; then
      log_ok "[60] Plugin '$name' already present at $dest_resolved"
      continue
    fi
    mkdir -p "$(dirname "$dest_resolved")" || { log_file_error "$(dirname "$dest_resolved")" "cannot create plugin parent"; continue; }
    log_info "[60] Cloning custom plugin '$name' -> $dest_resolved"
    if ! git clone --depth=1 "$repo" "$dest_resolved"; then
      log_err "[60] git clone failed for plugin '$name' from $repo"
    fi
  done
}

deploy_base_zshrc() {
  [ "$DO_DEPLOY_BASE" = "true" ] || { log_info "[60] deploy_zshrc=false -- skipping base deploy"; return 0; }
  cp -f "$PAYLOAD_BASE" "$ZSHRC" || { log_file_error "$ZSHRC" "cannot write ~/.zshrc"; return 1; }
  # Ensure the chosen default theme is actually set in the deployed file.
  if grep -qE '^ZSH_THEME=' "$ZSHRC"; then
    sed -i.bak -E "s|^ZSH_THEME=.*|ZSH_THEME=\"${DEFAULT_THEME}\"|" "$ZSHRC"
    rm -f "$ZSHRC.bak"
  else
    echo "ZSH_THEME=\"${DEFAULT_THEME}\"" >> "$ZSHRC"
  fi
  log_ok "[60] Deployed payload/zshrc-base -> $ZSHRC (theme=$DEFAULT_THEME)"
}

append_extras_zshrc() {
  [ "$DO_DEPLOY_EXTRAS" = "true" ] || { log_info "[60] deploy_extras=false -- skipping extras append"; return 0; }
  if grep -Fq "$EXTRAS_MARKER_BEGIN" "$ZSHRC" 2>/dev/null; then
    log_ok "[60] zshrc-extras block already present (marker found) -- skipping append"
    return 0
  fi
  local n; n=$(wc -l < "$PAYLOAD_EXTRAS")
  {
    echo ""
    echo "$EXTRAS_MARKER_BEGIN"
    cat "$PAYLOAD_EXTRAS"
    echo ""
    echo "$EXTRAS_MARKER_END"
  } >> "$ZSHRC"
  log_ok "[60] Appended payload/zshrc-extras to $ZSHRC ($n new lines)"
}

verify_theme() {
  local theme_file="$OMZ_DIR/themes/${DEFAULT_THEME}.zsh-theme"
  if [ -f "$theme_file" ]; then return 0; fi
  log_warn "[60] Configured theme '$DEFAULT_THEME' not found at $theme_file (OMZ may bundle it under a different name)"
}

# ---------- validation ----------
# Each check pushes a "PASS|FAIL|WARN<TAB>label<TAB>detail" row into VAL_ROWS.
# Returns 0 if there are zero FAIL rows, 1 otherwise. WARN rows never fail.
VAL_ROWS=()
VAL_FAIL=0
VAL_WARN=0

_val_add() {
  # $1 = PASS|FAIL|WARN  $2 = label  $3 = detail
  VAL_ROWS+=("$1"$'\t'"$2"$'\t'"$3")
  case "$1" in
    FAIL) VAL_FAIL=$((VAL_FAIL+1)) ;;
    WARN) VAL_WARN=$((VAL_WARN+1)) ;;
  esac
}

_val_check_file() { # label, path
  if [ -f "$2" ]; then _val_add PASS "$1" "$2"; else _val_add FAIL "$1" "$2 missing"; fi
}
_val_check_dir()  { # label, path
  if [ -d "$2" ]; then _val_add PASS "$1" "$2"; else _val_add FAIL "$1" "$2 missing"; fi
}
_val_check_grep() { # label, pattern, file, [warn|fail]
  local sev="${4:-FAIL}"
  if [ ! -f "$3" ]; then _val_add "$sev" "$1" "$3 missing (cannot grep)"; return; fi
  if grep -qE -- "$2" "$3"; then _val_add PASS "$1" "found in $3"
  else _val_add "$sev" "$1" "pattern not found in $3: $2"
  fi
}

validate_zshrc() {
  VAL_ROWS=(); VAL_FAIL=0; VAL_WARN=0

  # 1. zsh binary
  if command -v zsh >/dev/null 2>&1; then
    _val_add PASS "zsh in PATH" "$(command -v zsh)"
  else
    _val_add FAIL "zsh in PATH" "zsh binary not found"
  fi

  # 2. Oh-My-Zsh paths
  _val_check_dir  "OMZ root"        "$OMZ_DIR"
  _val_check_file "OMZ entrypoint"  "$OMZ_DIR/oh-my-zsh.sh"
  _val_check_dir  "OMZ themes dir"  "$OMZ_DIR/themes"
  _val_check_dir  "OMZ custom dir"  "$OMZ_DIR/custom"
  _val_check_dir  "OMZ plugins dir" "$OMZ_DIR/plugins"

  # 3. ~/.zshrc + structural lines
  _val_check_file "~/.zshrc deployed" "$ZSHRC"
  _val_check_grep "export ZSH= line"        '^export ZSH='        "$ZSHRC"
  _val_check_grep "ZSH_THEME= line"         '^ZSH_THEME='         "$ZSHRC"
  _val_check_grep "plugins=(...) line"      '^plugins=\('         "$ZSHRC"
  _val_check_grep "source oh-my-zsh.sh"     'source[[:space:]]+\$ZSH/oh-my-zsh\.sh' "$ZSHRC"

  # 4. Configured default theme actually exists (built-in or under custom/themes)
  local theme_builtin="$OMZ_DIR/themes/${DEFAULT_THEME}.zsh-theme"
  local theme_custom="$OMZ_DIR/custom/themes/${DEFAULT_THEME}.zsh-theme"
  if [ -f "$theme_builtin" ]; then
    _val_add PASS "theme '$DEFAULT_THEME' resolvable" "$theme_builtin"
  elif [ -f "$theme_custom" ]; then
    _val_add PASS "theme '$DEFAULT_THEME' resolvable" "$theme_custom (custom)"
  else
    _val_add WARN "theme '$DEFAULT_THEME' resolvable" "not found in themes/ or custom/themes/"
  fi

  # 5. Theme actually wired in ~/.zshrc matches default_theme
  if [ -f "$ZSHRC" ]; then
    local active_theme
    active_theme=$(grep -E '^ZSH_THEME=' "$ZSHRC" | head -n1 | sed -E 's/^ZSH_THEME="?([^"]*)"?.*/\1/')
    if [ -z "$active_theme" ]; then
      _val_add WARN "active ZSH_THEME wired"  "no ZSH_THEME value parsed"
    elif [ "$active_theme" = "$DEFAULT_THEME" ]; then
      _val_add PASS "active ZSH_THEME wired"  "$active_theme"
    else
      _val_add WARN "active ZSH_THEME wired"  "expected '$DEFAULT_THEME', got '$active_theme'"
    fi
  fi

  # 6. Custom plugins from config.json:custom_plugins[]
  local n; n=$(jq -r '.custom_plugins | length' "$CONFIG" 2>/dev/null || echo 0)
  if [ "$n" -gt 0 ] 2>/dev/null; then
    local i name dest dest_resolved
    for i in $(seq 0 $((n-1))); do
      name=$(jq -r ".custom_plugins[$i].name" "$CONFIG")
      dest=$(jq -r ".custom_plugins[$i].dest" "$CONFIG")
      dest_resolved=$(eval echo "$dest")
      if [ -d "$dest_resolved" ]; then
        _val_add PASS "custom plugin '$name'" "$dest_resolved"
      else
        _val_add FAIL "custom plugin '$name'" "$dest_resolved missing"
      fi
    done
  fi

  # 7. Plugin names declared in plugins=(...) inside ~/.zshrc actually exist on disk
  if [ -f "$ZSHRC" ]; then
    local plugin_line
    plugin_line=$(grep -E '^plugins=\(' "$ZSHRC" | head -n1)
    if [ -n "$plugin_line" ]; then
      local body; body=$(echo "$plugin_line" | sed -E 's/^plugins=\(([^)]*)\).*/\1/')
      local p
      for p in $body; do
        [ -z "$p" ] && continue
        if [ -d "$OMZ_DIR/plugins/$p" ] || [ -d "$OMZ_DIR/custom/plugins/$p" ]; then
          _val_add PASS "plugin '$p' resolvable" "found"
        else
          _val_add WARN "plugin '$p' resolvable" "not in plugins/ or custom/plugins/"
        fi
      done
    fi
  fi

  # 8. Extras markers (only if deploy_extras=true)
  if [ "$DO_DEPLOY_EXTRAS" = "true" ] && [ -f "$ZSHRC" ]; then
    local has_begin=0 has_end=0
    grep -Fq "$EXTRAS_MARKER_BEGIN" "$ZSHRC" && has_begin=1
    grep -Fq "$EXTRAS_MARKER_END"   "$ZSHRC" && has_end=1
    if [ "$has_begin" = "1" ] && [ "$has_end" = "1" ]; then
      # Verify ordering: BEGIN must come before END
      local ln_begin ln_end
      ln_begin=$(grep -nF "$EXTRAS_MARKER_BEGIN" "$ZSHRC" | head -n1 | cut -d: -f1)
      ln_end=$(  grep -nF "$EXTRAS_MARKER_END"   "$ZSHRC" | head -n1 | cut -d: -f1)
      if [ "$ln_begin" -lt "$ln_end" ]; then
        _val_add PASS "extras markers" "BEGIN line $ln_begin < END line $ln_end"
      else
        _val_add FAIL "extras markers" "BEGIN line $ln_begin not before END line $ln_end"
      fi
    else
      _val_add FAIL "extras markers" "BEGIN=$has_begin END=$has_end (both must be 1)"
    fi
  fi

  # 9. Render report
  local total=${#VAL_ROWS[@]}
  local pass_n=$(( total - VAL_FAIL - VAL_WARN ))
  log_info "[60] === zshrc validation report ($total checks: $pass_n PASS / $VAL_WARN WARN / $VAL_FAIL FAIL) ==="
  local row sev label detail
  for row in "${VAL_ROWS[@]}"; do
    sev="${row%%$'\t'*}"; rest="${row#*$'\t'}"
    label="${rest%%$'\t'*}"; detail="${rest#*$'\t'}"
    case "$sev" in
      PASS) log_ok   "[60] [PASS] $label -- $detail" ;;
      WARN) log_warn "[60] [WARN] $label -- $detail" ;;
      FAIL) log_err  "[60] [FAIL] $label -- $detail" ;;
    esac
  done
  log_info "[60] === end of validation ==="

  if [ "$VAL_FAIL" -gt 0 ]; then
    log_err "[60] zshrc validation FAILED ($VAL_FAIL hard errors). Run '60 repair' to redeploy."
    return 1
  fi
  log_ok "[60] zshrc validation OK ($pass_n checks passed${VAL_WARN:+, $VAL_WARN warnings})"
  return 0
}

maybe_chsh() {
  if [ "$DO_CHSH" != "true" ]; then
    log_info "[60] chsh skipped (set_default_shell=false in config.json)"
    return 0
  fi
  local zsh_path; zsh_path=$(command -v zsh)
  [ -n "$zsh_path" ] || { log_err "[60] zsh not in PATH; cannot chsh"; return 1; }
  if chsh -s "$zsh_path" 2>/dev/null; then
    log_ok "[60] Default shell changed to $zsh_path"
  else
    log_warn "[60] chsh failed (non-interactive shell, no PAM, or insufficient perms)"
  fi
}

# ---------- verbs ----------
verb_install() {
  write_install_paths \
    --tool   "zsh + Oh-My-Zsh + curated .zshrc" \
    --source "apt (zsh) + https://github.com/ohmyzsh/ohmyzsh + $SCRIPT_DIR/payload" \
    --temp   "$TMPDIR/scripts-fixer/zsh" \
    --target "/usr/bin/zsh + $HOME/.oh-my-zsh + $HOME/.zshrc (backup of prior)"
  log_info "[60] Starting Oh-My-Zsh installer flow"

  if verify_installed && [ -f "$INSTALLED_MARK" ]; then
    log_ok "[60] Already installed"
    validate_zshrc || true
    return 0
  fi

  backup_existing_config || true
  apt_install_packages   || return 1
  install_omz            || return 1
  clone_custom_plugins
  deploy_base_zshrc      || return 1
  append_extras_zshrc    || return 1
  verify_theme
  maybe_chsh

  mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
  validate_zshrc || log_warn "[60] Install completed but validation flagged issues -- review report above"
  log_ok "[60] Done. Open a new terminal and run 'zsh' (or set as default shell)."
  log_info "[60] Tip: also install script 61 for the 'zsh-theme' switcher command."
  return 0
}

verb_check() {
  local reason=""
  command -v zsh >/dev/null 2>&1 || reason="zsh not in PATH"
  [ -d "$OMZ_DIR" ] || reason="${reason:+$reason; }$OMZ_DIR missing"
  [ -f "$ZSHRC" ]   || reason="${reason:+$reason; }$ZSHRC missing"
  if [ -z "$reason" ]; then
    log_ok "[60] Verify OK (zsh present, $OMZ_DIR exists, $ZSHRC deployed)"
    return 0
  fi
  log_warn "[60] Verify FAILED ($reason)"
  return 1
}

verb_repair() {
  rm -f "$INSTALLED_MARK"
  # Force redeploy of payload + replug custom plugins; preserve OMZ install if present.
  log_info "[60] Repair: re-deploying ~/.zshrc payload and re-checking plugins"
  backup_existing_config || true
  clone_custom_plugins
  deploy_base_zshrc   || return 1
  append_extras_zshrc || return 1
  mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
  validate_zshrc || log_warn "[60] Repair completed but validation flagged issues -- review report above"
  log_ok "[60] Repair complete"
}

verb_uninstall() {
  log_warn "[60] To remove cleanly, use script 62-install-zsh-clear (safe restore + strip)"
  log_info "[60] This verb only clears the install marker; it does NOT touch $OMZ_DIR or $ZSHRC."
  rm -f "$INSTALLED_MARK"
}

# ---------- arg parsing ----------
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  validate)  validate_zshrc ;;
  uninstall) verb_uninstall ;;
  *) log_err "[60] Unknown verb: $1 (expected install|check|repair|validate|uninstall)"; exit 2 ;;
esac
