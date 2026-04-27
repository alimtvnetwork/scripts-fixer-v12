#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  scan-legacy-fixer-refs.sh
#  Bash twin of scan-legacy-fixer-refs.ps1. Scans the repo for any leftover
#  references to legacy scripts-fixer generations (v8, v9, v10).
#
#  Usage:
#    bash tools/scan-legacy-fixer-refs.sh
#    SCAN_VERSIONS="8|9|10|11" bash tools/scan-legacy-fixer-refs.sh
#    SCAN_ROOT="/path/to/repo" bash tools/scan-legacy-fixer-refs.sh
#
#  Exit codes:
#    0 = PASS (no matches)
#    1 = FAIL (matches found)
#    2 = error (bad path, missing tool)
# --------------------------------------------------------------------------
set -u

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DEFAULT_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." 2>/dev/null && pwd)"
ROOT="${SCAN_ROOT:-$DEFAULT_ROOT}"
VERSIONS="${SCAN_VERSIONS:-8|9|10}"

# ANSI colors
C_RED="\033[31m"; C_GRN="\033[32m"; C_YEL="\033[33m"; C_CYN="\033[36m"; C_DIM="\033[2m"; C_RST="\033[0m"

log_file_error() {
    # CODE RED: every file/path error must include exact path + reason
    printf "%b  [FAIL] path: %s -- reason: %s%b\n" "$C_RED" "$1" "$2" "$C_RST" >&2
}

if [ ! -d "$ROOT" ]; then
    log_file_error "$ROOT" "directory does not exist"
    exit 2
fi

PATTERN="scripts-fixer-v(${VERSIONS})\b"

printf "\n  %bLegacy scripts-fixer reference scan%b\n" "$C_CYN" "$C_RST"
printf "  %b----------------------------------------%b\n" "$C_DIM" "$C_RST"
printf "  Root     : %s\n" "$ROOT"
printf "  Pattern  : %s\n" "$PATTERN"
printf "\n"

# Prefer ripgrep, fall back to grep -r
if command -v rg >/dev/null 2>&1; then
    # rg with --no-ignore so we audit EVERY tracked + untracked file.
    # Explicit "." path argument is required in some environments where
    # implicit-CWD search returns nothing.
    OUTPUT="$(cd "$ROOT" && rg --no-ignore --hidden --no-config \
        --glob '!.git' --glob '!node_modules' --glob '!dist' --glob '!build' \
        --glob '!.lovable/compliance-reports/**' \
        --glob '!tools/scan-legacy-fixer-refs.*' \
        -nH "$PATTERN" . 2>/dev/null || true)"
else
    OUTPUT="$(cd "$ROOT" && grep -RnHE \
        --binary-files=without-match \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build \
        --exclude='scan-legacy-fixer-refs.*' \
        "$PATTERN" . 2>/dev/null || true)"
fi

if [ -z "$OUTPUT" ]; then
    printf "\n  %b[ PASS ]%b No references to scripts-fixer-v(%s) found.\n\n" "$C_GRN" "$C_RST" "$VERSIONS"
    exit 0
fi

COUNT="$(printf "%s\n" "$OUTPUT" | wc -l | tr -d ' ')"
printf "\n  %b[ FAIL ]%b Found %s reference(s):\n\n" "$C_RED" "$C_RST" "$COUNT"

# Group by file
CURRENT_FILE=""
printf "%s\n" "$OUTPUT" | while IFS= read -r line; do
    file="${line%%:*}"
    rest="${line#*:}"
    if [ "$file" != "$CURRENT_FILE" ]; then
        printf "  %b%s%b\n" "$C_YEL" "$file" "$C_RST"
        CURRENT_FILE="$file"
    fi
    printf "    %s\n" "$rest"
done

# Summary by version
printf "\n  %bSummary:%b\n" "$C_CYN" "$C_RST"
printf "%s\n" "$OUTPUT" | grep -oE "scripts-fixer-v(${VERSIONS})\b" | sort | uniq -c \
    | while read -r n m; do printf "    %-22s %s\n" "$m" "$n"; done
printf "\n"
exit 1
