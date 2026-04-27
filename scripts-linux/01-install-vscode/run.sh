#!/usr/bin/env bash
# 01-install-vscode
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="01"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 01-install-vscode"; exit 1; }

INSTALLED_MARK="$ROOT/.installed/01.ok"

verify_installed() { command -v code >/dev/null 2>&1; }

# --- MIME cleanup -----------------------------------------------------------
# Scrub VS Code's shell-integration MIME defaults (the apt/snap postinst hooks
# register code.desktop as the default handler for dozens of text/source MIME
# types, and VS Code itself adds more on first launch). We touch ONLY the
# files listed in config.json -> mimeCleanup, and inside each file we remove
# ONLY the exact .desktop tokens from the allow-list -- never wholesale
# deletion, never sibling associations.
_clean_mime_defaults() {
    has_jq || { log_warn "[01] jq not available -- skipping MIME cleanup"; return 0; }

    local enabled
    enabled=$(jq -r '.mimeCleanup.enabled // false' "$CONFIG")
    if [ "$enabled" != "true" ]; then
        log_info "[01] mimeCleanup.enabled=false -- skipping MIME defaults scrub"
        return 0
    fi

    # Read allow-list into arrays. ${HOME} expansion is done here so the
    # config file stays portable across users.
    mapfile -t DESKTOPS  < <(jq -r '.mimeCleanup.desktopFiles[]' "$CONFIG")
    mapfile -t USR_FILES < <(jq -r '.mimeCleanup.userFiles[]'    "$CONFIG")
    mapfile -t SYS_FILES < <(jq -r '.mimeCleanup.systemFiles[]'  "$CONFIG")
    mapfile -t CACHES    < <(jq -r '.mimeCleanup.cacheFiles[]'   "$CONFIG")

    if [ "${#DESKTOPS[@]}" -eq 0 ]; then
        log_warn "[01] mimeCleanup.desktopFiles is empty -- nothing to scrub"
        return 0
    fi

    log_info "[01] Scrubbing MIME defaults for: ${DESKTOPS[*]}"

    # Build a single sed -e chain that:
    #   1. Drops any "<mime>=<desktop>" line where <desktop> matches the
    #      allow-list (defaults.list / [Default Applications] format).
    #   2. Strips matching tokens from semicolon-separated lists like
    #      "<mime>=foo.desktop;code.desktop;bar.desktop;" preserving siblings.
    #   3. Deletes any leftover "<mime>=" line with no value.
    local sed_args=()
    local d esc
    for d in "${DESKTOPS[@]}"; do
        # Escape regex metacharacters in the .desktop name.
        esc=$(printf '%s' "$d" | sed -e 's/[][\.^$*+?(){}|/]/\\&/g')
        # 1. whole-line "key=<desktop>" or "key=<desktop>;"
        sed_args+=( -e "/^[^=]*=${esc};\?$/d" )
        # 2a. <desktop> at start of value list
        sed_args+=( -e "s/=${esc};/=/" )
        # 2b. <desktop> in middle/end of value list
        sed_args+=( -e "s/;${esc};/;/g" )
        sed_args+=( -e "s/;${esc}$//" )
    done
    # 3. drop "key=" with empty RHS left behind
    sed_args+=( -e '/^[^=]*=$/d' )

    _scrub_one_file() {
        local raw="$1" sudo_pfx="$2" path mode_pre mode_post
        # Expand ${HOME} (the only var we promise to expand in config).
        path="${raw//\$\{HOME\}/$HOME}"
        if [ ! -f "$path" ]; then
            log_info "[01]   skip (not present): $path"
            return 0
        fi
        mode_pre=$(stat -c '%a' "$path" 2>/dev/null || echo "")
        local tmp
        tmp=$(mktemp /tmp/01-mime.XXXXXX) || { log_file_error "/tmp" "mktemp failed for MIME scrub of $path"; return 1; }
        if ! $sudo_pfx sed "${sed_args[@]}" "$path" > "$tmp"; then
            log_file_error "$path" "sed scrub failed -- original NOT modified"
            rm -f "$tmp"; return 1
        fi
        # cmp is in coreutils on every supported distro; fall back to diff -q
        # if it's somehow missing.
        local _changed=1
        if command -v cmp >/dev/null 2>&1; then
            cmp -s "$path" "$tmp" && _changed=0
        else
            diff -q "$path" "$tmp" >/dev/null 2>&1 && _changed=0
        fi
        if [ "$_changed" -eq 0 ]; then
            log_info "[01]   no matching MIME entries in: $path"
            rm -f "$tmp"; return 0
        fi
        # Backup before overwriting.
        local ts backup
        ts=$(date +%Y%m%d-%H%M%S)
        backup="${path}.bak-01-${ts}"
        if ! $sudo_pfx cp -p "$path" "$backup"; then
            log_file_error "$backup" "backup copy failed -- aborting scrub of $path"
            rm -f "$tmp"; return 1
        fi
        if ! $sudo_pfx cp "$tmp" "$path"; then
            log_file_error "$path" "write-back failed after scrub (backup preserved at $backup)"
            rm -f "$tmp"; return 1
        fi
        rm -f "$tmp"
        # Preserve original mode if we know it.
        if [ -n "$mode_pre" ]; then
            $sudo_pfx chmod "$mode_pre" "$path" 2>/dev/null || true
        fi
        mode_post=$(stat -c '%a' "$path" 2>/dev/null || echo "?")
        log_ok "[01]   scrubbed: $path (mode $mode_post, backup: $backup)"
        return 0
    }

    local f rc=0
    for f in "${USR_FILES[@]}"; do
        _scrub_one_file "$f" "" || rc=1
    done
    for f in "${SYS_FILES[@]}"; do
        _scrub_one_file "$f" "sudo" || rc=1
    done

    # Refresh the desktop/MIME caches so file managers stop offering Code as
    # the default. We never DELETE the cache files (other apps need them) --
    # we just rebuild them.
    if command -v update-desktop-database >/dev/null 2>&1; then
        log_info "[01] Refreshing desktop database (update-desktop-database)"
        sudo update-desktop-database -q 2>/dev/null || \
            log_warn "[01] update-desktop-database failed (non-fatal)"
        if [ -d "$HOME/.local/share/applications" ]; then
            update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
        fi
    fi
    if command -v xdg-mime >/dev/null 2>&1; then
        log_info "[01] xdg-mime cache refresh hint: per-MIME defaults can be re-set with 'xdg-mime default <app>.desktop <mimetype>'"
    fi

    # Touch (not delete) the cache files just to advertise what we left alone.
    local c
    for c in "${CACHES[@]}"; do
        local cp="${c//\$\{HOME\}/$HOME}"
        [ -f "$cp" ] && log_info "[01]   left cache file in place: $cp"
    done

    if [ "$rc" -ne 0 ]; then
        log_warn "[01] MIME cleanup completed with one or more file errors (see above)"
    else
        log_ok "[01] MIME cleanup complete"
    fi
    return 0
}

install_via_ms_repo() {
  log_info "[01] Adding Microsoft apt repo + key"
  has_curl || { log_err "[01] curl required for Microsoft key"; return 1; }
  local key_tmp keyring="/usr/share/keyrings/packages.microsoft.gpg"
  key_tmp=$(mktemp /tmp/microsoft.gpg.XXXXXX) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$key_tmp"; then
    log_file_error "$key_tmp" "failed to fetch/dearmor Microsoft GPG key"
    return 1
  fi
  sudo install -D -o root -g root -m 644 "$key_tmp" "$keyring" || { log_file_error "$keyring" "install of GPG keyring failed"; return 1; }
  rm -f "$key_tmp"
  echo "deb [arch=amd64,arm64,armhf signed-by=$keyring] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y code
}

install_via_snap() {
  log_info "[01] Installing code via snap classic"
  sudo snap install code --classic
}

verb_install() {
  log_info "[01] Starting VS Code installer"
  if verify_installed; then
    log_ok "[01] VS Code already installed"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    return 0
  fi
  if is_debian_family && is_apt_available; then
    if install_via_ms_repo; then
      log_ok "[01] VS Code installed via Microsoft apt repo"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
    log_warn "[01] apt path failed -- trying snap fallback"
  fi
  if is_snap_available; then
    if install_via_snap; then
      log_ok "[01] VS Code installed via snap"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      return 0
    fi
  fi
  log_err "[01] No supported install method"
  return 1
}

verb_check() {
  if verify_installed; then log_ok "[01] code detected: $(code --version 2>/dev/null | head -1)"; return 0; fi
  log_warn "[01] code not on PATH"; return 1
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

verb_uninstall() {
  if is_apt_pkg_installed code; then sudo apt-get remove -y code; fi
  if is_snap_pkg_installed code; then sudo snap remove code; fi
  _clean_mime_defaults
  rm -f "$INSTALLED_MARK"
  log_ok "[01] VS Code uninstalled"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[01] Unknown verb: $1"; exit 2 ;;
esac
