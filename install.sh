#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  Scripts Fixer -- One-liner bootstrap installer (Unix/macOS)
#  Usage:  curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v7/main/install.sh | bash
#
#  Auto-discovery: probes scripts-fixer-vN repos (N = current+1..current+30)
#  in parallel and redirects to the newest published version.
#  Spec: spec/install-bootstrap/readme.md
#  Disable with: --no-upgrade  or  SCRIPTS_FIXER_NO_UPGRADE=1
#  Version check: --version (shows current and latest, no install)
#  Dry-run:       --dry-run  (prints every step but mutates nothing)
# --------------------------------------------------------------------------
set -e

OWNER="alimtvnetwork"
BASE="scripts-fixer"
CURRENT=8   # <-- bump this when this file is copied into a new -vN repo
FALLBACK="$HOME/scripts-fixer"
REPO="https://github.com/$OWNER/$BASE-v$CURRENT.git"

PROBE_MAX="${SCRIPTS_FIXER_PROBE_MAX:-30}"
if ! [[ "$PROBE_MAX" =~ ^[0-9]+$ ]] || [ "$PROBE_MAX" -lt 1 ] || [ "$PROBE_MAX" -gt 100 ]; then
    PROBE_MAX=30
fi

NO_UPGRADE=0
VERSION_MODE=0
DRY_RUN=0
HELP_MODE=0
for arg in "$@"; do
    case "$arg" in
        --no-upgrade) NO_UPGRADE=1 ;;
        --version|-V) VERSION_MODE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) HELP_MODE=1 ;;
    esac
done
if [ "${SCRIPTS_FIXER_NO_UPGRADE:-0}" = "1" ]; then NO_UPGRADE=1; fi

echo ""
echo "  Scripts Fixer -- Bootstrap Installer (v$CURRENT)"
echo ""

# -- Help mode -------------------------------------------------------------
if [ "$HELP_MODE" = "1" ]; then
    cat <<'EOF'
  Usage: install.sh [--version|-V] [--help|-h] [--no-upgrade] [--dry-run]

  Flags:
    --version, -V    Print bootstrap repo version + payload semver, then exit.
                     Also probes for newer scripts-fixer-vN repos and reports
                     the highest one available without redirecting.
    --help, -h       Show this help and exit.
    --no-upgrade     Skip auto-discovery; install from the current repo.
    --dry-run        Print every step but mutate nothing.

  Env:
    SCRIPTS_FIXER_NO_UPGRADE=1   Same as --no-upgrade
    SCRIPTS_FIXER_PROBE_MAX=N    How many vN+k to probe (default 30, max 100)
    SCRIPTS_FIXER_REDIRECTED=1   Internal loop guard, set after one redirect
EOF
    echo ""
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "  [DRYRUN] Dry-run mode enabled -- no files will be cloned, removed, or copied."
    echo ""
fi

# -- Helper: fetch payload semver from a repo's scripts/version.json -------
# Args: <repo-vN-name>   (e.g. scripts-fixer-v8)
# Echoes: "X.Y.Z" on success, "(unknown)" on any failure (network, missing
#         file, malformed JSON). Never fails the caller -- version reporting
#         must remain best-effort.
fetch_payload_semver() {
    local repo_name="$1"
    local url="https://raw.githubusercontent.com/$OWNER/$repo_name/main/scripts/version.json"
    local raw
    if ! command -v curl >/dev/null 2>&1; then
        echo "(unknown)"
        return 0
    fi
    raw="$(curl -fsSL -m 5 "$url" 2>/dev/null)" || { echo "(unknown)"; return 0; }
    [ -z "$raw" ] && { echo "(unknown)"; return 0; }
    # Best-effort JSON parse without requiring jq: grep the "version" field.
    local ver
    ver="$(printf '%s' "$raw" \
        | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    if [ -z "$ver" ]; then
        echo "(unknown)"
    else
        echo "$ver"
    fi
}

# -- Version check mode (discover + report, no clone) ----------------------
if [ "$VERSION_MODE" = "1" ]; then
    RANGE_END=$((CURRENT + PROBE_MAX))
    CURRENT_SEMVER="$(fetch_payload_semver "$BASE-v$CURRENT")"
    echo "  [VERSION] Bootstrap repo : $BASE-v$CURRENT"
    echo "  [VERSION] Payload semver : $CURRENT_SEMVER"
    echo "  [SCAN] Probing v$((CURRENT + 1))..v$RANGE_END for newer releases (parallel)..."

    probe_one() {
        local n=$1
        local url="https://raw.githubusercontent.com/$OWNER/$BASE-v$n/main/install.sh"
        if curl -fsI -m 5 "$url" >/dev/null 2>&1; then
            echo "$n"
        fi
    }
    export -f probe_one
    export OWNER BASE

    LATEST=$(seq $((CURRENT + 1)) "$RANGE_END" \
        | xargs -P 20 -I{} bash -c 'probe_one "$@"' _ {} 2>/dev/null \
        | sort -n | tail -1)

    if [ -n "$LATEST" ] && [ "$LATEST" -gt "$CURRENT" ]; then
        LATEST_SEMVER="$(fetch_payload_semver "$BASE-v$LATEST")"
        echo "  [FOUND]    Newer repo     : $BASE-v$LATEST"
        echo "  [FOUND]    Newer semver   : $LATEST_SEMVER"
        echo "  [RESOLVED] Would redirect to $BASE-v$LATEST"
    else
        echo "  [OK] You're on the latest ($BASE-v$CURRENT, semver $CURRENT_SEMVER)"
    fi
    echo ""
    echo "  (Use without --version flag to actually install)"
    exit 0
fi

# -- Auto-discovery: probe for newer -vN repos -------------------------------
if [ "${SCRIPTS_FIXER_REDIRECTED:-0}" = "1" ]; then
    echo "  [SKIP] Auto-discovery skipped (already redirected)."
elif [ "$NO_UPGRADE" = "1" ]; then
    echo "  [SKIP] Auto-discovery disabled."
elif ! command -v curl &>/dev/null; then
    echo "  [SKIP] curl unavailable -- skipping discovery."
else
    RANGE_END=$((CURRENT + PROBE_MAX))
    echo "  [SCAN] Currently on v$CURRENT. Probing v$((CURRENT + 1))..v$RANGE_END for newer releases (parallel)..."

    probe_one() {
        local n=$1
        local url="https://raw.githubusercontent.com/$OWNER/$BASE-v$n/main/install.sh"
        if curl -fsI -m 5 "$url" >/dev/null 2>&1; then
            echo "$n"
        fi
    }
    export -f probe_one
    export OWNER BASE

    LATEST=$(seq $((CURRENT + 1)) "$RANGE_END" \
        | xargs -P 20 -I{} bash -c 'probe_one "$@"' _ {} 2>/dev/null \
        | sort -n | tail -1)

    if [ -n "$LATEST" ] && [ "$LATEST" -gt "$CURRENT" ]; then
        echo "  [FOUND] Newer version available: v$LATEST"
        if [ "$DRY_RUN" = "1" ]; then
            echo "  [DRYRUN] Would redirect to $BASE-v$LATEST  (skipped)"
        else
            echo "  [REDIRECT] Switching to $BASE-v$LATEST..."
            echo ""
            export SCRIPTS_FIXER_REDIRECTED=1
            NEW_URL="https://raw.githubusercontent.com/$OWNER/$BASE-v$LATEST/main/install.sh"
            if curl -fsSL "$NEW_URL" | bash; then
                exit 0
            else
                echo "  [WARN] Failed to run v$LATEST installer -- falling back to v$CURRENT"
            fi
        fi
    else
        echo "  [OK] You're on the latest (v$CURRENT). Continuing..."
    fi
    echo ""
fi

# -- Check git is available ---------------------------------------------------
if ! command -v git &>/dev/null; then
    echo "  [ERROR] git is not installed. Install Git first, then re-run."
    echo "          https://git-scm.com/downloads"
    exit 1
fi

# -- Helper: test if a directory is "safe" to clone into --------------------
# Unsafe = a system root, /, or any path that fails a write-probe.
test_cwd_is_safe() {
    local p="$1"
    [ -z "$p" ] && return 1

    # Drive root / filesystem root
    if [ "$p" = "/" ]; then
        return 1
    fi

    # Common protected/system paths (macOS + Linux)
    case "$p" in
        /bin|/bin/*|/sbin|/sbin/*|/usr|/usr/*|/etc|/etc/*|/var|/var/*|/boot|/boot/*|/sys|/sys/*|/proc|/proc/*|/System|/System/*|/Library|/Library/*|/Applications|/Applications/*)
            return 1
            ;;
    esac

    # Write probe
    local probe="$p/.scripts-fixer-write-probe.$$"
    if touch "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null
        return 0
    fi
    return 1
}

# -- Resolve target folder (CWD-aware with safe fallback) -------------------
# Sets globals: TARGET, REASON, IS_INSIDE
resolve_target_folder() {
    local cwd="$1"
    local fallback="$2"
    local leaf
    leaf="$(basename "$cwd")"

    # 1. CWD's leaf folder name == 'scripts-fixer' -> target = CWD itself
    if [ "$leaf" = "scripts-fixer" ]; then
        TARGET="$cwd"
        REASON="cwd-is-target"
        IS_INSIDE=1
        return 0
    fi

    # 2. CWD contains a 'scripts-fixer' subfolder -> target = that subfolder
    if [ -d "$cwd/scripts-fixer" ]; then
        TARGET="$cwd/scripts-fixer"
        REASON="cwd-has-sibling"
        IS_INSIDE=0
        return 0
    fi

    # 3. CWD is "safe" -> target = <CWD>/scripts-fixer
    if test_cwd_is_safe "$cwd"; then
        TARGET="$cwd/scripts-fixer"
        REASON="cwd-safe"
        IS_INSIDE=0
        return 0
    fi

    # 4. Otherwise -> fallback to $HOME/scripts-fixer
    TARGET="$fallback"
    REASON="fallback-home"
    IS_INSIDE=0
    return 0
}

# -- Helper: invoke git clone with stderr captured to a temp file ------------
invoke_git_clone() {
    local repo_url="$1"
    local target_path="$2"

    echo "  [GIT] Cloning from : $repo_url"
    echo "  [GIT] Cloning into : $target_path"

    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRYRUN] git clone --quiet $repo_url $target_path  (skipped)"
        return 0
    fi

    local err_file
    err_file="$(mktemp 2>/dev/null || echo "/tmp/scripts-fixer-git-err.$$")"

    git clone --quiet "$repo_url" "$target_path" 2>"$err_file"
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "  [ERROR] git clone exit code: $exit_code"
        if [ -s "$err_file" ]; then
            echo "          Git stderr:"
            sed 's/^/            /' "$err_file"
        fi
    fi
    rm -f "$err_file" 2>/dev/null
    return $exit_code
}

# -- Helper: try to remove a folder, return 0 on success, 1 on failure -------
remove_folder_safe() {
    local path="$1"
    if [ ! -e "$path" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRYRUN] rm -rf $path  (skipped)"
        return 0
    fi
    if rm -rf "$path" 2>/dev/null; then
        return 0
    fi
    echo "  [WARN] Could not remove $path"
    echo "         Reason: insufficient permissions or files in use."
    return 1
}

# -- Resolve target (CWD-aware) ----------------------------------------------
CWD="$(pwd)"
resolve_target_folder "$CWD" "$FALLBACK"
FOLDER="$TARGET"

echo ""
echo "  [LOCATE] Current directory : $CWD"
echo "  [LOCATE] Target folder     : $FOLDER"
case "$REASON" in
    cwd-is-target)
        echo "  [LOCATE] You are INSIDE a 'scripts-fixer' folder -- cloning back into the same path."
        ;;
    cwd-has-sibling)
        echo "  [LOCATE] A 'scripts-fixer' subfolder exists in CWD -- cloning into it."
        ;;
    cwd-safe)
        echo "  [LOCATE] CWD is writable -- cloning into <CWD>/scripts-fixer."
        ;;
    fallback-home)
        echo "  [LOCATE] CWD is a protected/system path -- falling back to \$HOME."
        ;;
esac

# -- Step out of folder if we're sitting inside it ---------------------------
if [ "$IS_INSIDE" = "1" ]; then
    PARENT="$(dirname "$CWD")"
    echo "  [CD] Stepping out to parent  : $PARENT"
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRYRUN] cd $PARENT  (skipped)"
    else
        cd "$PARENT" || {
            echo "  [ERROR] Could not cd to parent: $PARENT"
            exit 1
        }
    fi
fi

# -- Try to remove existing target folder ------------------------------------
REMOVED=1
if [ -e "$FOLDER" ]; then
    echo "  [CLEAN] Removing existing folder: $FOLDER"
    if remove_folder_safe "$FOLDER"; then
        echo "  [OK] Folder removed."
        REMOVED=1
    else
        echo "  [INFO] Direct removal failed -- will use TEMP staging fallback."
        REMOVED=0
    fi
fi

# -- Direct clone path (no conflict OR remove succeeded) ---------------------
if [ "$REMOVED" = "1" ]; then
    echo ""
    echo "  [>>] Direct clone into target..."
    if ! invoke_git_clone "$REPO" "$FOLDER"; then
        echo "          Repo   : $REPO"
        echo "          Target : $FOLDER"
        echo "          Verify the repo exists and your network is reachable."
        exit 1
    fi
    if [ "$DRY_RUN" = "0" ] && [ ! -d "$FOLDER/.git" ]; then
        echo "  [ERROR] Clone finished but .git missing in: $FOLDER"
        exit 1
    fi
    echo "  [OK] Cloned successfully into $FOLDER"
else
    # -- TEMP staging fallback (remove failed -- folder is locked) -----------
    STAMP="$(date +%Y%m%d-%H%M%S)"
    TEMP_DIR="${TMPDIR:-/tmp}/scripts-fixer-bootstrap-$STAMP"
    echo ""
    echo "  [TEMP] Staging clone path  : $TEMP_DIR"
    if ! invoke_git_clone "$REPO" "$TEMP_DIR"; then
        echo "          Repo   : $REPO"
        echo "          Target : $TEMP_DIR"
        exit 1
    fi
    if [ "$DRY_RUN" = "0" ] && [ ! -d "$TEMP_DIR/.git" ]; then
        echo "  [ERROR] Temp clone finished but .git missing in: $TEMP_DIR"
        exit 1
    fi
    echo "  [OK] Temp clone complete."

    # Copy contents over the locked folder (overwrite)
    echo "  [COPY] From : $TEMP_DIR"
    echo "  [COPY] To   : $FOLDER"
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRYRUN] mkdir -p $FOLDER && cp -a $TEMP_DIR/. $FOLDER/  (skipped)"
    else
        if [ ! -d "$FOLDER" ]; then
            mkdir -p "$FOLDER" || {
                echo "  [ERROR] Could not create target folder: $FOLDER"
                exit 1
            }
        fi
        # cp -a preserves attrs; trailing /. copies contents (incl. dotfiles)
        CP_ERR="/tmp/scripts-fixer-cp-err.$$"
        if cp -a "$TEMP_DIR/." "$FOLDER/" 2>"$CP_ERR"; then
            echo "  [OK] Files copied into $FOLDER"
        else
            echo "  [ERROR] Copy from temp failed."
            echo "          Source : $TEMP_DIR"
            echo "          Target : $FOLDER"
            if [ -s "$CP_ERR" ]; then
                echo "          Reason :"
                sed 's/^/            /' "$CP_ERR"
            fi
            rm -f "$CP_ERR" 2>/dev/null
            echo "          Files remain in temp -- copy manually if needed: $TEMP_DIR"
            exit 1
        fi
        rm -f "$CP_ERR" 2>/dev/null
    fi

    # Best-effort cleanup of temp staging
    if remove_folder_safe "$TEMP_DIR"; then
        echo "  [CLEAN] Temp staging removed."
    else
        echo "  [WARN] Temp staging not removed: $TEMP_DIR"
    fi
fi

echo ""
echo "  [CD] Entering              : $FOLDER"
if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "  [DRYRUN] cd $FOLDER && pwsh ./run.ps1  (skipped)"
    echo "  [DRYRUN] No changes were made. Re-run without --dry-run to actually install."
    echo ""
    exit 0
fi

echo ""
echo "  Done! To get started:"
echo "    cd $FOLDER"
echo "    pwsh ./run.ps1"
echo ""
