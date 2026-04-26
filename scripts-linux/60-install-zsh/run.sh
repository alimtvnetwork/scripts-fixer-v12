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
    echo "$EXTRAS_MARKER_END"
  } >> "$ZSHRC"
  log_ok "[60] Appended payload/zshrc-extras to $ZSHRC ($n new lines)"
}

verify_theme() {
  local theme_file="$OMZ_DIR/themes/${DEFAULT_THEME}.zsh-theme"
  if [ -f "$theme_file" ]; then return 0; fi
  log_warn "[60] Configured theme '$DEFAULT_THEME' not found at $theme_file (OMZ may bundle it under a different name)"
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
  log_info "[60] Starting Oh-My-Zsh installer flow"

  if verify_installed && [ -f "$INSTALLED_MARK" ]; then
    log_ok "[60] Already installed"
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
  log_ok "[60] Repair complete"
}

verb_uninstall() {
  log_warn "[60] To remove cleanly, use script 62-install-zsh-clear (when available)"
  log_info "[60] This verb only clears the install marker; it does NOT touch $OMZ_DIR or $ZSHRC."
  rm -f "$INSTALLED_MARK"
}

# ---------- arg parsing ----------
case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[60] Unknown verb: $1 (expected install|check|repair|uninstall)"; exit 2 ;;
esac
