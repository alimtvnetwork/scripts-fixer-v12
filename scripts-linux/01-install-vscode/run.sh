#!/usr/bin/env bash
# 01-install-vscode
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="01"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 01-install-vscode"; exit 1; }

INSTALLED_MARK="$ROOT/.installed/01.ok"
FINGERPRINT_FILE="$ROOT/.installed/01.fingerprint"

verify_installed() { command -v code >/dev/null 2>&1; }

# --- Scope detection -------------------------------------------------------
# Cleanup is bounded by THREE sources of truth, in priority order:
#   1. Override env vars VSCODE_CLEAN_METHODS / VSCODE_CLEAN_EDITIONS
#      (space-separated). Highest priority -- escape hatch for ops.
#   2. .installed/01.fingerprint -- written at install time. Captures the
#      method + edition + version + timestamp of THIS script's install.
#      Used so that reinstalling via a different method later doesn't make
#      uninstall lose track of the original.
#   3. Live detection via config.json -> scope.methodProbes / editionProbes.
#      Probes apt (dpkg -s), snap (snap list), flatpak (flatpak list),
#      and presence of method-specific install dirs.
#
# Outputs (exported for downstream helpers):
#   SCOPE_METHODS   = space-separated list of detected install methods
#                     ("apt snap" / "flatpak" / "tarball" / "" if none)
#   SCOPE_EDITIONS  = space-separated list of detected editions
#                     ("stable" / "insiders" / "stable insiders" / "")
#   SCOPE_SOURCE    = "override" | "fingerprint" | "live"
#
# When SCOPE_METHODS is empty, ALL cleanup helpers go into REPORT-ONLY
# mode -- they list what they WOULD touch but make no changes. This is
# the safe default when we can't prove anything was installed.
_resolve_install_scope() {
    has_jq || { log_warn "[01] jq not available -- scope detection disabled"; SCOPE_METHODS=""; SCOPE_EDITIONS=""; SCOPE_SOURCE="none"; return 0; }

    # 1. Override env wins.
    if [ -n "${VSCODE_CLEAN_METHODS:-}" ] || [ -n "${VSCODE_CLEAN_EDITIONS:-}" ]; then
        SCOPE_METHODS="${VSCODE_CLEAN_METHODS:-}"
        SCOPE_EDITIONS="${VSCODE_CLEAN_EDITIONS:-stable insiders}"
        SCOPE_SOURCE="override"
        log_info "[01][scope] using override: methods='$SCOPE_METHODS' editions='$SCOPE_EDITIONS'"
        return 0
    fi

    # 2. Fingerprint from a previous install we did.
    if [ -f "$FINGERPRINT_FILE" ]; then
        local fp_methods fp_editions fp_version fp_ts
        fp_methods=$(jq  -r '.methods   // "" | if type=="array" then join(" ") else . end' "$FINGERPRINT_FILE" 2>/dev/null || echo "")
        fp_editions=$(jq -r '.editions  // "" | if type=="array" then join(" ") else . end' "$FINGERPRINT_FILE" 2>/dev/null || echo "")
        fp_version=$(jq  -r '.version   // "unknown"' "$FINGERPRINT_FILE" 2>/dev/null || echo "unknown")
        fp_ts=$(jq       -r '.installedAt // "unknown"' "$FINGERPRINT_FILE" 2>/dev/null || echo "unknown")
        if [ -n "$fp_methods" ]; then
            SCOPE_METHODS="$fp_methods"
            SCOPE_EDITIONS="${fp_editions:-stable}"
            SCOPE_SOURCE="fingerprint"
            log_info "[01][scope] using fingerprint: methods='$SCOPE_METHODS' editions='$SCOPE_EDITIONS' version='$fp_version' installed='$fp_ts'"
            return 0
        fi
        log_warn "[01][scope] fingerprint at $FINGERPRINT_FILE has empty .methods -- falling through to live detection"
    fi

    # 3. Live detection.
    local methods="" editions=""

    # apt
    if is_debian_family 2>/dev/null && is_apt_pkg_installed code 2>/dev/null; then
        methods="$methods apt"
    elif is_debian_family 2>/dev/null && is_apt_pkg_installed code-insiders 2>/dev/null; then
        methods="$methods apt"
    elif [ -d /usr/share/code ] || [ -d /usr/share/code-insiders ]; then
        methods="$methods apt"
    fi

    # snap
    if command -v snap >/dev/null 2>&1; then
        if snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx 'code\|code-insiders' 2>/dev/null; then
            methods="$methods snap"
        elif [ -d /snap/code/current ] || [ -d /snap/code-insiders/current ]; then
            methods="$methods snap"
        fi
    fi

    # flatpak
    if command -v flatpak >/dev/null 2>&1; then
        if flatpak list --app --columns=application 2>/dev/null | grep -qx 'com.visualstudio.code\|com.visualstudio.code.insiders' 2>/dev/null; then
            methods="$methods flatpak"
        fi
    fi
    [ -d /var/lib/flatpak/app/com.visualstudio.code ]                  && methods="$methods flatpak"
    [ -d /var/lib/flatpak/app/com.visualstudio.code.insiders ]         && methods="$methods flatpak"
    [ -d "$HOME/.local/share/flatpak/app/com.visualstudio.code" ]      && methods="$methods flatpak"

    # tarball / opt
    [ -d /opt/visual-studio-code ]      && methods="$methods tarball"
    [ -d /opt/VSCode-linux-x64 ]        && methods="$methods tarball"
    [ -d "$HOME/.local/opt/vscode" ]    && methods="$methods tarball"

    # Editions
    if command -v code >/dev/null 2>&1            || \
       [ -f /usr/share/applications/code.desktop ] || \
       [ -f "$HOME/.local/share/applications/code.desktop" ]; then
        editions="$editions stable"
    fi
    if command -v code-insiders >/dev/null 2>&1            || \
       [ -f /usr/share/applications/code-insiders.desktop ] || \
       [ -f "$HOME/.local/share/applications/code-insiders.desktop" ]; then
        editions="$editions insiders"
    fi

    # Dedupe + trim.
    SCOPE_METHODS=$(printf '%s\n' $methods  | awk '!seen[$0]++' | xargs echo)
    SCOPE_EDITIONS=$(printf '%s\n' $editions | awk '!seen[$0]++' | xargs echo)
    SCOPE_SOURCE="live"
    if [ -z "$SCOPE_METHODS" ]; then
        log_warn "[01][scope] live detection found NO VS Code install (no apt pkg, no snap, no flatpak, no /opt) -- cleanup will run in REPORT-ONLY mode (no files modified). Use VSCODE_CLEAN_METHODS=apt VSCODE_CLEAN_EDITIONS=stable to force scrub."
    else
        log_info "[01][scope] live detection: methods='$SCOPE_METHODS' editions='${SCOPE_EDITIONS:-<none>}'"
    fi
    return 0
}

# Returns 0 (true) if the given comma/space-separated tag list intersects
# the active scope dimension. $1 = "methods" or "editions", $2... = tags.
_scope_matches() {
    local dim="$1"; shift
    local active=""
    case "$dim" in
        methods)  active="$SCOPE_METHODS" ;;
        editions) active="$SCOPE_EDITIONS" ;;
        *)        return 1 ;;
    esac
    # Empty active scope -> nothing matches (report-only mode).
    [ -z "$active" ] && return 1
    local want a w
    for want in "$@"; do
        for a in $active; do
            if [ "$want" = "$a" ]; then return 0; fi
        done
    done
    return 1
}

# Returns 0 if we should perform actual writes; 1 for report-only mode.
_scope_can_modify() {
    [ -n "$SCOPE_METHODS" ]
}

# Write a fingerprint when we successfully install. Captures method,
# edition, version, timestamp, and the apt/snap channel/source.
_write_install_fingerprint() {
    local method="$1" edition="${2:-stable}" version source
    version=$(code --version 2>/dev/null | head -1 || echo "unknown")
    case "$method" in
        apt)
            source=$(dpkg-query -W -f='${Version}|${Source}|${Maintainer}\n' code 2>/dev/null || echo "unknown")
            ;;
        snap)
            source=$(snap info code 2>/dev/null | awk '/^tracking:/ {print $2; exit}')
            ;;
        *)  source="unknown" ;;
    esac
    mkdir -p "$ROOT/.installed"
    cat > "$FINGERPRINT_FILE" <<EOF
{
  "methods": ["$method"],
  "editions": ["$edition"],
  "version": "$version",
  "source": "$source",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "installedBy": "scripts-linux/01-install-vscode/run.sh"
}
EOF
    log_info "[01] Wrote install fingerprint: $FINGERPRINT_FILE (method=$method edition=$edition version=$version)"
}

# --- Scoped allow-list reader ----------------------------------------------
# Read a jq array path and return only entries that match the active scope.
# Each array entry can be either:
#   "string"                                  (no scope tags -> always allowed)
#   { "name": "...", "methods":[...], "editions":[...] }
#   { "path": "...", "methods":[...], "editions":[...] }
# Outputs one matching value per line (the .name, .path, or the bare string).
# Args: $1 = jq path (e.g. '.mimeCleanup.desktopFiles'), $2 = key for the
# value field (defaults to "name"; pass "path" for path-style arrays).
# Outputs lines on stdout. Caller mapfiles them.
_scoped_filter() {
    local jq_path="$1" value_key="${2:-name}"
    local methods_json editions_json
    # Convert space-separated scope to JSON arrays for jq.
    methods_json=$(printf '%s\n' $SCOPE_METHODS  | jq -R . | jq -s .)
    editions_json=$(printf '%s\n' $SCOPE_EDITIONS | jq -R . | jq -s .)
    jq -r --argjson m "$methods_json" --argjson e "$editions_json" --arg vk "$value_key" "
        ${jq_path}[]
        | if type == \"string\" then
              {value: ., methods: null, editions: null}
          else
              {value: (.[\$vk] // .name // .path // \"\"),
               methods: (.methods // null),
               editions: (.editions // null)}
          end
        | select(
            (.methods  == null or any(.methods[];  IN(\$m[])))
            and
            (.editions == null or any(.editions[]; IN(\$e[])))
          )
        | .value
    " "$CONFIG"
}
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

    # Scope-filtered allow-lists. desktopFiles + systemFiles carry per-method
    # tags; userFiles + cacheFiles are shared across all methods.
    mapfile -t DESKTOPS  < <(_scoped_filter '.mimeCleanup.desktopFiles' name)
    mapfile -t USR_FILES < <(jq -r '.mimeCleanup.userFiles[]'  "$CONFIG")
    mapfile -t SYS_FILES < <(_scoped_filter '.mimeCleanup.systemFiles' path)
    mapfile -t CACHES    < <(jq -r '.mimeCleanup.cacheFiles[]' "$CONFIG")

    if [ "${#DESKTOPS[@]}" -eq 0 ]; then
        log_warn "[01] No desktopFiles match active scope (methods='$SCOPE_METHODS' editions='$SCOPE_EDITIONS') -- skipping MIME defaults scrub"
        return 0
    fi

    if _scope_can_modify; then
        log_info "[01] Scrubbing MIME defaults for (scope: $SCOPE_SOURCE/${SCOPE_METHODS}/${SCOPE_EDITIONS}): ${DESKTOPS[*]}"
    else
        log_info "[01] REPORT-ONLY -- would scrub MIME defaults for: ${DESKTOPS[*]}"
    fi

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
        elif command -v diff >/dev/null 2>&1; then
            diff -q "$path" "$tmp" >/dev/null 2>&1 && _changed=0
        elif command -v md5sum >/dev/null 2>&1; then
            local h1 h2
            h1=$($sudo_pfx md5sum "$path" | awk '{print $1}')
            h2=$(md5sum "$tmp" | awk '{print $1}')
            [ "$h1" = "$h2" ] && _changed=0
        else
            local s1 s2
            s1=$($sudo_pfx cat "$path"); s2=$(cat "$tmp")
            [ "$s1" = "$s2" ] && _changed=0
        fi
        if [ "$_changed" -eq 0 ]; then
            log_info "[01]   no matching MIME entries in: $path"
            rm -f "$tmp"; return 0
        fi
        if ! _scope_can_modify; then
            log_info "[01]   REPORT-ONLY -- would scrub: $path"
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

# --- VS Code .desktop entry scrub ------------------------------------------
# `code --install-extension <id>` (and the apt/snap postinst hooks) write
# `MimeType=`, `Actions=`, and `[Desktop Action <name>]` group blocks into
# VS Code's OWN .desktop files (e.g. /usr/share/applications/code.desktop,
# ~/.local/share/applications/code-url-handler.desktop). After uninstall
# those files may already be gone, but on snap removal and on partial
# uninstalls the per-user copies survive and still claim MIME ownership.
#
# This helper STRIPS only:
#   * `MimeType=...` lines (entire line)
#   * `Actions=...`  lines (entire line)
#   * any `[Desktop Action <name>]` group block, from the group header
#     through (but not including) the next group header or EOF
#
# It PRESERVES every other key (Name, GenericName, Comment, Exec, TryExec,
# Icon, Type, Categories, StartupNotify, StartupWMClass, Keywords,
# NoDisplay, Hidden, OnlyShowIn, NotShowIn, X-*, etc.) so the launcher
# entry itself keeps working until the package is fully removed.
#
# It NEVER touches a .desktop file whose basename is not in
# `mimeCleanup.desktopFiles[]`. Unrelated entries (firefox.desktop,
# gimp.desktop, anything else in /usr/share/applications) are left
# byte-for-byte intact.
_clean_vscode_desktop_entries() {
    has_jq || { log_warn "[01] jq not available -- skipping .desktop entry scrub"; return 0; }

    local enabled
    enabled=$(jq -r '.mimeCleanup.enabled // false' "$CONFIG")
    if [ "$enabled" != "true" ]; then
        log_info "[01] mimeCleanup.enabled=false -- skipping .desktop entry scrub"
        return 0
    fi

    mapfile -t DESKTOPS < <(_scoped_filter '.mimeCleanup.desktopFiles' name)
    mapfile -t DIRS     < <(_scoped_filter '.mimeCleanup.desktopEntryDirs' path)

    if [ "${#DESKTOPS[@]}" -eq 0 ]; then
        log_warn "[01] No desktopFiles match active scope (methods='$SCOPE_METHODS' editions='$SCOPE_EDITIONS') -- skipping .desktop entry scrub"
        return 0
    fi
    if [ "${#DIRS[@]}" -eq 0 ]; then
        log_warn "[01] No desktopEntryDirs match active scope (methods='$SCOPE_METHODS') -- skipping .desktop entry scrub"
        return 0
    fi

    if _scope_can_modify; then
        log_info "[01] Scrubbing MimeType=/Actions= from VS Code .desktop files (scope: ${SCOPE_METHODS}/${SCOPE_EDITIONS})"
    else
        log_info "[01] REPORT-ONLY -- would scrub MimeType=/Actions= from: ${DESKTOPS[*]}"
    fi

    # awk program: strip MimeType=/Actions= lines AND drop any
    # [Desktop Action <name>] group block until the next group header.
    # Preserves [Desktop Entry] and any other [GroupName] block.
    local awk_prog='
        /^\[Desktop Action / { in_action = 1; next }
        /^\[/                { in_action = 0; print; next }
        in_action            { next }
        /^[[:space:]]*MimeType[[:space:]]*=/ { next }
        /^[[:space:]]*Actions[[:space:]]*=/  { next }
        { print }
    '

    _scrub_one_desktop_file() {
        local path="$1" sudo_pfx="$2" mode_pre tmp
        if [ ! -f "$path" ]; then
            return 0
        fi
        # Sanity: only operate on Desktop Entry files. If the first line
        # isn't "[Desktop Entry]" or a comment, refuse to touch it.
        local first
        first=$($sudo_pfx head -1 "$path" 2>/dev/null || echo "")
        case "$first" in
            "[Desktop Entry]"|"#"*|"") ;;
            *)
                log_warn "[01]   refuse to scrub non-DesktopEntry file: $path (first line: ${first:0:40})"
                return 0
                ;;
        esac
        mode_pre=$(stat -c '%a' "$path" 2>/dev/null || echo "")
        tmp=$(mktemp /tmp/01-deskent.XXXXXX) || { log_file_error "/tmp" "mktemp failed for .desktop scrub of $path"; return 1; }
        if ! $sudo_pfx awk "$awk_prog" "$path" > "$tmp"; then
            log_file_error "$path" "awk scrub failed -- original NOT modified"
            rm -f "$tmp"; return 1
        fi
        local _changed=1
        if command -v cmp >/dev/null 2>&1; then
            cmp -s "$path" "$tmp" && _changed=0
        elif command -v diff >/dev/null 2>&1; then
            diff -q "$path" "$tmp" >/dev/null 2>&1 && _changed=0
        elif command -v md5sum >/dev/null 2>&1; then
            local h1 h2
            h1=$($sudo_pfx md5sum "$path" | awk '{print $1}')
            h2=$(md5sum "$tmp" | awk '{print $1}')
            [ "$h1" = "$h2" ] && _changed=0
        else
            # Last-resort: byte-for-byte string compare via shell read.
            local s1 s2
            s1=$($sudo_pfx cat "$path"); s2=$(cat "$tmp")
            [ "$s1" = "$s2" ] && _changed=0
        fi
        if [ "$_changed" -eq 0 ]; then
            log_info "[01]   no MimeType=/Actions= in: $path"
            rm -f "$tmp"; return 0
        fi
        if ! _scope_can_modify; then
            log_info "[01]   REPORT-ONLY -- would scrub .desktop entries from: $path"
            rm -f "$tmp"; return 0
        fi
        local ts backup
        ts=$(date +%Y%m%d-%H%M%S)
        backup="${path}.bak-01de-${ts}"
        if ! $sudo_pfx cp -p "$path" "$backup"; then
            log_file_error "$backup" "backup copy failed -- aborting scrub of $path"
            rm -f "$tmp"; return 1
        fi
        if ! $sudo_pfx cp "$tmp" "$path"; then
            log_file_error "$path" "write-back failed after .desktop scrub (backup preserved at $backup)"
            rm -f "$tmp"; return 1
        fi
        rm -f "$tmp"
        if [ -n "$mode_pre" ]; then
            $sudo_pfx chmod "$mode_pre" "$path" 2>/dev/null || true
        fi
        log_ok "[01]   scrubbed .desktop entries from: $path (backup: $backup)"
        return 0
    }

    local rc=0 dir d_raw d_path basename sudo_pfx
    for d_raw in "${DIRS[@]}"; do
        dir="${d_raw//\$\{HOME\}/$HOME}"
        if [ ! -d "$dir" ]; then
            log_info "[01]   skip dir (not present): $dir"
            continue
        fi
        # Decide sudo: HOME-rooted dirs no, anything else yes.
        case "$dir" in
            "$HOME"/*) sudo_pfx="" ;;
            *)         sudo_pfx="sudo" ;;
        esac
        for basename in "${DESKTOPS[@]}"; do
            d_path="$dir/$basename"
            _scrub_one_desktop_file "$d_path" "$sudo_pfx" || rc=1
        done
    done

    # Refresh the desktop database so the (now MimeType-less) entries no
    # longer claim ownership. We already did this in _clean_mime_defaults
    # but call again is cheap and idempotent.
    if command -v update-desktop-database >/dev/null 2>&1; then
        sudo update-desktop-database -q 2>/dev/null || true
        [ -d "$HOME/.local/share/applications" ] && \
            update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
    fi

    if [ "$rc" -ne 0 ]; then
        log_warn "[01] .desktop entry scrub completed with one or more file errors (see above)"
    else
        log_ok "[01] .desktop entry scrub complete"
    fi
    return 0
}

# --- Context menu cleanup --------------------------------------------------
# Removes the "Open with Code" Nautilus / Nemo / Caja shell scripts and
# Thunar uca.xml.d entries, plus the helper shims VS Code itself drops
# under its install tree (e.g. resources/app/bin/code-context.sh).
#
# STRICT rules:
#   * We delete a file ONLY when its BASENAME matches one of the
#     allow-listed names AND its PARENT DIR is one of the allow-listed
#     locations. No globbing, no recursion, no "rm -rf <dir>".
#   * Sibling scripts the user wrote themselves (e.g. an "Open with
#     Sublime" script next to "Open with Code") are byte-for-byte
#     untouched.
#   * Directories themselves are NEVER removed -- only matching files
#     inside them.
#   * Each delete is preceded by a `.bak-01ctx-<ts>` snapshot copy so
#     the user can restore if needed.
_clean_context_menu_entries() {
    has_jq || { log_warn "[01] jq not available -- skipping context menu cleanup"; return 0; }

    local enabled
    enabled=$(jq -r '.mimeCleanup.contextMenu.enabled // false' "$CONFIG")
    if [ "$enabled" != "true" ]; then
        log_info "[01] mimeCleanup.contextMenu.enabled=false -- skipping context menu cleanup"
        return 0
    fi

    mapfile -t SCRIPT_NAMES < <(_scoped_filter '.mimeCleanup.contextMenu.fileNames'       name)
    mapfile -t SCRIPT_DIRS  < <(jq -r '.mimeCleanup.contextMenu.searchDirs[]? // empty'   "$CONFIG")
    mapfile -t ACTION_NAMES < <(_scoped_filter '.mimeCleanup.contextMenu.actionFileNames' name)
    mapfile -t ACTION_DIRS  < <(_scoped_filter '.mimeCleanup.contextMenu.actionDirs'      path)
    mapfile -t INT_NAMES    < <(jq -r '.mimeCleanup.contextMenu.integrationFiles[]? // empty' "$CONFIG")
    mapfile -t INT_ROOTS    < <(_scoped_filter '.mimeCleanup.contextMenu.integrationRoots' path)

    if _scope_can_modify; then
        log_info "[01] Context menu cleanup (scope: ${SCOPE_SOURCE}/${SCOPE_METHODS}/${SCOPE_EDITIONS}): ${#SCRIPT_NAMES[@]} script names, ${#ACTION_NAMES[@]} action names, ${#INT_ROOTS[@]} integration roots"
    else
        log_info "[01] REPORT-ONLY context menu scan: ${#SCRIPT_NAMES[@]} script names, ${#ACTION_NAMES[@]} action names, ${#INT_ROOTS[@]} integration roots"
    fi

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local rc=0 removed=0

    _ctx_remove_one() {
        # $1 = full path, $2 = sudo prefix ("" or "sudo"), $3 = label for log
        local path="$1" sudo_pfx="$2" label="$3"
        if [ ! -e "$path" ]; then
            return 0
        fi
        # Refuse to delete a directory -- our allow-list is files only.
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            log_warn "[01]   refuse to delete directory (allow-list is files only): $path"
            return 0
        fi
        if ! _scope_can_modify; then
            log_info "[01]   REPORT-ONLY -- would remove $label: $path"
            return 0
        fi
        # Snapshot before delete so the user can recover.
        local backup="${path}.bak-01ctx-${ts}"
        if ! $sudo_pfx cp -p "$path" "$backup" 2>/dev/null; then
            # Symlinks: cp -p preserves the link itself; a follow-up rm is
            # still safe. Only fail hard if the file actually existed and
            # we couldn't snapshot it.
            if [ -L "$path" ]; then
                log_info "[01]   $label is a symlink -- removing without backup: $path"
            else
                log_file_error "$backup" "snapshot copy failed -- NOT deleting $path"
                return 1
            fi
        fi
        if ! $sudo_pfx rm -f "$path"; then
            log_file_error "$path" "$label removal failed (backup at $backup)"
            return 1
        fi
        log_ok "[01]   removed $label: $path${backup:+ (backup: $backup)}"
        removed=$((removed+1))
        return 0
    }

    _ctx_sudo_for() {
        # Decide sudo prefix based on path location.
        case "$1" in
            "$HOME"/*) printf '' ;;
            *)         printf 'sudo' ;;
        esac
    }

    # 1. Nautilus / Nemo / Caja / Thunar shell-script integrations.
    local d_raw d basename path sudo_pfx
    for d_raw in "${SCRIPT_DIRS[@]}"; do
        d="${d_raw//\$\{HOME\}/$HOME}"
        if [ ! -d "$d" ]; then
            continue
        fi
        sudo_pfx="$(_ctx_sudo_for "$d")"
        for basename in "${SCRIPT_NAMES[@]}"; do
            path="$d/$basename"
            _ctx_remove_one "$path" "$sudo_pfx" "context-menu script" || rc=1
        done
    done

    # 2. Nautilus/Nemo/Caja XML/.desktop action files.
    for d_raw in "${ACTION_DIRS[@]}"; do
        d="${d_raw//\$\{HOME\}/$HOME}"
        if [ ! -d "$d" ]; then
            continue
        fi
        sudo_pfx="$(_ctx_sudo_for "$d")"
        for basename in "${ACTION_NAMES[@]}"; do
            path="$d/$basename"
            _ctx_remove_one "$path" "$sudo_pfx" "file-manager action" || rc=1
        done
    done

    # 3. VS Code install-tree integration scripts.
    for d_raw in "${INT_ROOTS[@]}"; do
        d="${d_raw//\$\{HOME\}/$HOME}"
        if [ ! -d "$d" ]; then
            continue
        fi
        sudo_pfx="$(_ctx_sudo_for "$d")"
        for basename in "${INT_NAMES[@]}"; do
            path="$d/$basename"
            _ctx_remove_one "$path" "$sudo_pfx" "VS Code integration shim" || rc=1
        done
    done

    if [ "$rc" -ne 0 ]; then
        log_warn "[01] Context menu cleanup completed with $removed file(s) removed and one or more errors (see above)"
    else
        log_ok "[01] Context menu cleanup complete ($removed file(s) removed)"
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
  write_install_paths \
    --tool   "Visual Studio Code" \
    --source "Microsoft apt repo (packages.microsoft.com) | snap | rpm" \
    --temp   "/var/cache/apt/archives | $TMPDIR/scripts-fixer/vscode" \
    --target "/usr/bin/code"
  log_info "[01] Starting VS Code installer"
  if verify_installed; then
    log_ok "[01] VS Code already installed"
    mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
    # Don't overwrite an existing fingerprint -- it tracks the ORIGINAL
    # install method. Only write one if missing (legacy / external install).
    if [ ! -f "$FINGERPRINT_FILE" ]; then
        local detected_method=""
        if   is_apt_pkg_installed code 2>/dev/null;  then detected_method="apt"
        elif is_snap_pkg_installed code 2>/dev/null; then detected_method="snap"
        else detected_method="unknown"
        fi
        _write_install_fingerprint "$detected_method" "stable"
    fi
    return 0
  fi
  if is_debian_family && is_apt_available; then
    if install_via_ms_repo; then
      log_ok "[01] VS Code installed via Microsoft apt repo"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      _write_install_fingerprint "apt" "stable"
      return 0
    fi
    log_warn "[01] apt path failed -- trying snap fallback"
  fi
  if is_snap_available; then
    if install_via_snap; then
      log_ok "[01] VS Code installed via snap"
      mkdir -p "$ROOT/.installed" && touch "$INSTALLED_MARK"
      _write_install_fingerprint "snap" "stable"
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

# Show the resolved install scope (method + edition + source) without
# touching anything. Useful for ops to dry-run the cleanup decision.
verb_scope() {
    _resolve_install_scope
    log_info "[01][scope] source:   $SCOPE_SOURCE"
    log_info "[01][scope] methods:  ${SCOPE_METHODS:-<none>}"
    log_info "[01][scope] editions: ${SCOPE_EDITIONS:-<none>}"
    if [ -f "$FINGERPRINT_FILE" ]; then
        log_info "[01][scope] fingerprint:"
        cat "$FINGERPRINT_FILE" | sed 's/^/    /' >&2
    else
        log_info "[01][scope] fingerprint: <missing -- $FINGERPRINT_FILE>"
    fi
    if ! _scope_can_modify; then
        log_warn "[01][scope] empty scope -> cleanup would run in REPORT-ONLY mode"
    fi
    return 0
}

verb_repair() { rm -f "$INSTALLED_MARK"; verb_install; }

# --- State verification ----------------------------------------------------
# Probe every surface that the cleaners touch and emit one TSV row per
# finding to stdout. Format (tab-separated):
#   <category>\t<key>\t<status>\t<detail>
# where:
#   category = desktop-file | mime-default | mime-association
#            | nautilus-script | nemo-script | caja-script
#            | fm-action | integration-shim | xdg-mime-default
#   key      = a stable identifier for the row (path or "mime:handler")
#   status   = PRESENT
#   detail   = freeform context (which file, which line, etc.)
#
# This is read-only -- no files are modified. Used both standalone
# (verb_verify) and as the before/after probes around uninstall.
_collect_state_snapshot() {
    local out="$1"
    : > "$out"

    # 1. VS Code .desktop files in any known applications dir.
    local dirs=(
        "$HOME/.local/share/applications"
        "/usr/share/applications"
        "/var/lib/snapd/desktop/applications"
        "/var/lib/flatpak/exports/share/applications"
        "$HOME/.local/share/flatpak/exports/share/applications"
    )
    local names=(
        code.desktop code-url-handler.desktop code_code.desktop
        code-insiders.desktop code-insiders-url-handler.desktop code_code-insiders.desktop
        com.visualstudio.code.desktop com.visualstudio.code.insiders.desktop
    )
    local d n p
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for n in "${names[@]}"; do
            p="$d/$n"
            if [ -f "$p" ]; then
                printf 'desktop-file\t%s\tPRESENT\tfile exists\n' "$p" >> "$out"
                # Sub-probe: does it still claim MimeType= or Actions=?
                if grep -qE '^[[:space:]]*MimeType[[:space:]]*=' "$p" 2>/dev/null; then
                    local mt
                    mt=$(grep -m1 -E '^[[:space:]]*MimeType[[:space:]]*=' "$p" 2>/dev/null | head -c 120)
                    printf 'desktop-file-mimetype\t%s\tPRESENT\t%s\n' "$p" "$mt" >> "$out"
                fi
                if grep -qE '^[[:space:]]*Actions[[:space:]]*=' "$p" 2>/dev/null; then
                    printf 'desktop-file-actions\t%s\tPRESENT\tActions= line still set\n' "$p" >> "$out"
                fi
                if grep -qE '^\[Desktop Action ' "$p" 2>/dev/null; then
                    local count
                    count=$(grep -cE '^\[Desktop Action ' "$p" 2>/dev/null || echo 0)
                    printf 'desktop-file-action-block\t%s\tPRESENT\t%s [Desktop Action *] block(s)\n' "$p" "$count" >> "$out"
                fi
            fi
        done
    done

    # 2. mimeapps.list / defaults.list -- one row per code* handler line.
    local mime_files=(
        "$HOME/.config/mimeapps.list"
        "$HOME/.local/share/applications/mimeapps.list"
        "$HOME/.local/share/applications/defaults.list"
        "/usr/share/applications/mimeapps.list"
        "/usr/share/applications/defaults.list"
        "/etc/xdg/mimeapps.list"
    )
    local f line
    for f in "${mime_files[@]}"; do
        [ -f "$f" ] || continue
        # grep for any line whose RHS references a code* desktop file.
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf 'mime-association\t%s\tPRESENT\t%s\n' "$f" "$line" >> "$out"
        done < <(grep -nE '=.*\bcode(-insiders)?(_code(-insiders)?)?\.desktop' "$f" 2>/dev/null \
                | grep -v '^#' | head -50)
    done

    # 3. Nautilus / Nemo / Caja scripts directories.
    local script_dirs=(
        "nautilus:$HOME/.local/share/nautilus/scripts"
        "nautilus:$HOME/.gnome2/nautilus-scripts"
        "nemo:$HOME/.local/share/nemo/scripts"
        "caja:$HOME/.config/caja/scripts"
        "caja:$HOME/.local/share/caja/scripts"
    )
    local entry mgr base
    for entry in "${script_dirs[@]}"; do
        mgr="${entry%%:*}"; base="${entry#*:}"
        [ -d "$base" ] || continue
        # Find any file (or symlink) under the dir whose name OR content
        # references VS Code. Limit depth to 2 -- some scripts live in
        # subfolders like "Open with Code/launcher.sh".
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            local why="name"
            if ! basename "$p" | grep -qiE 'code|vscode'; then
                why="content"
            fi
            printf '%s-script\t%s\tPRESENT\tmatched-by:%s\n' "$mgr" "$p" "$why" >> "$out"
        done < <(find "$base" -maxdepth 2 \( -type f -o -type l \) 2>/dev/null \
                 | while read -r p; do
                       if basename "$p" | grep -qiE 'code|vscode'; then
                           echo "$p"
                       elif [ -r "$p" ] && [ "$(stat -c %s "$p" 2>/dev/null || echo 99999999)" -lt 65536 ]; then
                           grep -qiE '\b(code|code-insiders)\b' "$p" 2>/dev/null && echo "$p"
                       fi
                   done)
    done

    # 4. File-manager action files (.desktop / .nemo_action) referencing code.
    local action_dirs=(
        "$HOME/.local/share/file-manager/actions"
        "/usr/share/file-manager/actions"
        "$HOME/.local/share/nemo/actions"
        "/usr/share/nemo/actions"
        "$HOME/.config/caja/actions"
        "/usr/share/caja/actions"
    )
    for d in "${action_dirs[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            printf 'fm-action\t%s\tPRESENT\taction file references code\n' "$p" >> "$out"
        done < <(grep -ril -E '\b(code|code-insiders)\b' "$d" 2>/dev/null \
                 --include='*.desktop' --include='*.nemo_action' | head -20)
    done

    # 5. VS Code integration shims (code-context.sh etc.) inside install trees.
    local int_roots=(
        "/usr/share/code/resources/app/bin"
        "/usr/share/code-insiders/resources/app/bin"
        "/snap/code/current/usr/share/code/resources/app/bin"
        "/var/lib/flatpak/app/com.visualstudio.code/current/active/files/extra/vscode/bin"
        "/opt/visual-studio-code/bin"
        "$HOME/.vscode/bin"
        "$HOME/.vscode-insiders/bin"
    )
    local int_files=(code-context.sh code-shell-integration.sh open-with-code.sh)
    for d in "${int_roots[@]}"; do
        [ -d "$d" ] || continue
        for n in "${int_files[@]}"; do
            # Search up to 3 levels deep -- ~/.vscode/bin/<sha>/code-context.sh.
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                printf 'integration-shim\t%s\tPRESENT\tname=%s\n' "$p" "$n" >> "$out"
            done < <(find "$d" -maxdepth 3 -type f -name "$n" 2>/dev/null)
        done
    done

    # 6. xdg-mime defaults for common text/code MIME types -- the user-facing
    #    "what app opens .py / .json / .md right now?" answer.
    if command -v xdg-mime >/dev/null 2>&1; then
        local mt handler
        for mt in text/plain text/x-shellscript text/x-python text/x-c text/x-csrc \
                  text/x-c++src text/x-java application/json application/xml \
                  text/markdown text/html; do
            handler=$(xdg-mime query default "$mt" 2>/dev/null || true)
            if printf '%s' "$handler" | grep -qE '^code(-insiders)?(_code(-insiders)?)?\.desktop$|^com\.visualstudio\.code'; then
                printf 'xdg-mime-default\t%s\tPRESENT\thandler=%s\n' "$mt" "$handler" >> "$out"
            fi
        done
    fi
    return 0
}

# Pretty-print a before/after diff. Reads two snapshot TSVs.
# Categories with REMOVED rows -> green/ok. Still-PRESENT rows -> warn.
# New rows in after but not before -> warn (something appeared mid-run).
_print_state_diff() {
    local before="$1" after="$2"
    local before_count after_count removed_count still_count new_count
    before_count=$(wc -l < "$before" 2>/dev/null || echo 0)
    after_count=$(wc -l  < "$after"  2>/dev/null || echo 0)
    # Use sort+comm on the (category,key,detail) tuple. Drop the status
    # column because it's always PRESENT at probe time.
    local b_keys a_keys
    b_keys=$(mktemp); a_keys=$(mktemp)
    awk -F'\t' '{print $1"\t"$2"\t"$4}' "$before" | sort -u > "$b_keys"
    awk -F'\t' '{print $1"\t"$2"\t"$4}' "$after"  | sort -u > "$a_keys"
    removed_count=$(comm -23 "$b_keys" "$a_keys" | wc -l)
    still_count=$(  comm -12 "$b_keys" "$a_keys" | wc -l)
    new_count=$(    comm -13 "$b_keys" "$a_keys" | wc -l)

    log_info "[01][verify] ============================================================"
    log_info "[01][verify] BEFORE/AFTER cleanup state diff"
    log_info "[01][verify] ============================================================"
    log_info "[01][verify]   before: $before_count finding(s)"
    log_info "[01][verify]   after:  $after_count finding(s)"
    log_info "[01][verify]   ---"
    if [ "$removed_count" -gt 0 ]; then
        log_ok   "[01][verify]   REMOVED:    $removed_count  (cleaned up successfully)"
    else
        log_info "[01][verify]   REMOVED:    0"
    fi
    if [ "$still_count" -gt 0 ]; then
        log_warn "[01][verify]   STILL PRESENT: $still_count  (NOT removed -- see list below)"
    else
        log_ok   "[01][verify]   STILL PRESENT: 0  (all targeted entries gone)"
    fi
    if [ "$new_count" -gt 0 ]; then
        log_warn "[01][verify]   NEW:        $new_count  (appeared between snapshots)"
    fi
    log_info "[01][verify] ============================================================"

    if [ "$removed_count" -gt 0 ]; then
        log_info "[01][verify] --- REMOVED entries ---"
        comm -23 "$b_keys" "$a_keys" | while IFS=$'\t' read -r cat key det; do
            log_ok "[01][verify]   [-] $cat :: $key  ($det)"
        done
    fi
    if [ "$still_count" -gt 0 ]; then
        log_info "[01][verify] --- STILL PRESENT entries ---"
        comm -12 "$b_keys" "$a_keys" | while IFS=$'\t' read -r cat key det; do
            log_warn "[01][verify]   [!] $cat :: $key  ($det)"
        done
    fi
    if [ "$new_count" -gt 0 ]; then
        log_info "[01][verify] --- NEW entries ---"
        comm -13 "$b_keys" "$a_keys" | while IFS=$'\t' read -r cat key det; do
            log_warn "[01][verify]   [+] $cat :: $key  ($det)"
        done
    fi
    rm -f "$b_keys" "$a_keys"

    # Final verdict.
    if [ "$still_count" -eq 0 ] && [ "$new_count" -eq 0 ] && [ "$before_count" -gt 0 ]; then
        log_ok "[01][verify] VERDICT: clean -- no VS Code context-menu / MIME residue detected"
        return 0
    fi
    if [ "$before_count" -eq 0 ] && [ "$after_count" -eq 0 ]; then
        log_ok "[01][verify] VERDICT: clean -- nothing was present before or after"
        return 0
    fi
    log_warn "[01][verify] VERDICT: residue remains -- see STILL PRESENT list above"
    return 1
}

# Standalone verify verb -- single read-only snapshot, no diff.
verb_verify() {
    local snap
    snap=$(mktemp)
    log_info "[01][verify] Probing context-menu + MIME state (read-only)..."
    _collect_state_snapshot "$snap"
    local n
    n=$(wc -l < "$snap" 2>/dev/null || echo 0)
    if [ "$n" -eq 0 ]; then
        log_ok "[01][verify] No VS Code context-menu / MIME entries found on this system"
        rm -f "$snap"
        return 0
    fi
    log_warn "[01][verify] Found $n VS Code-related entries:"
    awk -F'\t' '{printf "[01][verify]   [*] %s :: %s  (%s)\n", $1, $2, $4}' "$snap" >&2
    rm -f "$snap"
    return 0
}

verb_uninstall() {
  _resolve_install_scope
  # BEFORE snapshot.
  local _before_snap _after_snap
  _before_snap=$(mktemp)
  _after_snap=$(mktemp)
  log_info "[01][verify] Capturing BEFORE snapshot..."
  _collect_state_snapshot "$_before_snap"
  log_info "[01][verify] BEFORE: $(wc -l < "$_before_snap") finding(s) recorded"

  if is_apt_pkg_installed code; then sudo apt-get remove -y code; fi
  if is_snap_pkg_installed code; then sudo snap remove code; fi
  _clean_mime_defaults
  _clean_vscode_desktop_entries
  _clean_context_menu_entries

  # AFTER snapshot + diff.
  log_info "[01][verify] Capturing AFTER snapshot..."
  _collect_state_snapshot "$_after_snap"
  _print_state_diff "$_before_snap" "$_after_snap" || true
  rm -f "$_before_snap" "$_after_snap"

  # Only delete the fingerprint AFTER the cleaners have used it.
  rm -f "$FINGERPRINT_FILE"
  rm -f "$INSTALLED_MARK"
  log_ok "[01] VS Code uninstalled"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  scope)     verb_scope ;;
  verify)    verb_verify ;;
  *) log_err "[01] Unknown verb: $1"; exit 2 ;;
esac
