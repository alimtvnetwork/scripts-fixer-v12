#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  fix-legacy-fixer-refs.sh
#  One-command auto-fix: rewrites scripts-fixer-v12/v9/v10 -> scripts-fixer-v12
#  across every text file in the repo (including lockfiles).
#
#  Usage:
#    ./tools/fix-legacy-fixer-refs.sh                # apply changes
#    DRY_RUN=1 ./tools/fix-legacy-fixer-refs.sh      # preview only
#    FIX_TARGET=v11 FIX_VERSIONS="8 9 10" ./tools/fix-legacy-fixer-refs.sh
#    FIX_PATHS="tools/ src/" ./tools/fix-legacy-fixer-refs.sh
#    ./tools/fix-legacy-fixer-refs.sh --paths tools/,src/
#
#  Path filter:
#    FIX_PATHS  : space-separated, repo-relative folders or files
#    --paths    : comma- or space-separated, repo-relative folders or files
#    Empty/unset = rewrite across the entire repo (default).
# --------------------------------------------------------------------------
set -u

# ---- CLI parsing (--paths) -------------------------------------------------
CLI_PATHS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --paths)     CLI_PATHS="${2:-}"; shift 2 ;;
        --paths=*)   CLI_PATHS="${1#--paths=}"; shift ;;
        *)           shift ;;
    esac
done

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; MAG=$'\e[35m'; RST=$'\e[0m'
info()  { printf '%s[info ]%s %s\n' "$CYN" "$RST" "$*"; }
ok()    { printf '%s[ ok  ]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[warn ]%s %s\n' "$YLW" "$RST" "$*"; }
fail()  { printf '%s[fail ]%s %s\n' "$RED" "$RST" "$*"; }
file_error() { printf '%s[fail ]%s file=%s reason=%s\n' "$RED" "$RST" "$1" "$2"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FIX_TARGET="${FIX_TARGET:-v11}"
FIX_VERSIONS="${FIX_VERSIONS:-8 9 10}"
DRY_RUN="${DRY_RUN:-0}"
# JSON summary report. Set REPORT_FILE="" to suppress, or pass an absolute/
# relative path. Relative paths resolve against $REPO_ROOT.
REPORT_FILE="${REPORT_FILE-legacy-fix-report.json}"
# Timestamped backups: when BACKUP=1 each rewritten file is copied to
# $BACKUP_ROOT/<timestamp>/<repo-relative-path> BEFORE being overwritten.
# The chosen backup directory path is also written to the JSON report so
# orchestrators (or humans) can restore from it later.
BACKUP="${BACKUP:-0}"
BACKUP_ROOT="${BACKUP_ROOT:-.legacy-fix-backups}"
BACKUP_STAMP="${BACKUP_STAMP:-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)}"
RAW_PATHS="${CLI_PATHS:-${FIX_PATHS:-}}"

if [ ! -d "$REPO_ROOT" ]; then
  file_error "$REPO_ROOT" "repo root does not exist"
  exit 2
fi

# ---- Resolve & validate path filter ---------------------------------------
NORMALISED_PATHS="$(printf '%s' "$RAW_PATHS" | tr ',' ' ')"
PATH_FILTERS=()
for p in $NORMALISED_PATHS; do
  clean="${p#./}"
  clean="${clean%/}"
  [ -z "$clean" ] && continue
  abs="$REPO_ROOT/$clean"
  if [ ! -e "$abs" ]; then
    file_error "$abs" "path filter target does not exist (from --paths/FIX_PATHS=\"$p\")"
    exit 2
  fi
  PATH_FILTERS+=("$clean")
done

info "repo:     $REPO_ROOT"
info "rewrite:  $(for v in $FIX_VERSIONS; do printf 'scripts-fixer-v%s ' "$v"; done)-> scripts-fixer-$FIX_TARGET"
if [ "${#PATH_FILTERS[@]}" -gt 0 ]; then
  info "paths:    ${PATH_FILTERS[*]}"
else
  info "paths:    (entire repo)"
fi
if [ "$DRY_RUN" = "1" ]; then info "mode:     dry-run"; else info "mode:     apply"; fi

# Resolve backup directory (only used when BACKUP=1 AND not DRY_RUN)
case "$BACKUP_ROOT" in
  /*) backup_base="$BACKUP_ROOT" ;;
  *)  backup_base="$REPO_ROOT/$BACKUP_ROOT" ;;
esac
backup_dir="$backup_base/$BACKUP_STAMP"
backup_active=0
if [ "$BACKUP" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  if mkdir -p "$backup_dir" 2>/dev/null; then
    backup_active=1
    info "backup:   $backup_dir"
  else
    file_error "$backup_dir" "cannot create backup directory -- aborting"
    exit 2
  fi
fi

# Build a single regex alternation: scripts-fixer-v(8|9|10)
alt="$(echo "$FIX_VERSIONS" | tr ' ' '|')"
match_re="scripts-fixer-v(${alt})"

# Skip patterns
prune_dirs='-name .git -o -name node_modules -o -name dist -o -name build -o -name .next -o -name .turbo -o -name .cache -o -name coverage -o -name .lovable -o -name .legacy-fix-backups'
skip_ext_re='\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|tgz|7z|rar|exe|dll|bin|lockb|woff2?|ttf|otf|mp3|mp4|mov|wav)$'
self_re='-legacy-(fixer-refs|refs)\.(sh|ps1)$'
# Documentation files we never rewrite (they intentionally describe the migration).
docs_re='^tools/readme\.md$'

changed_files=0
total_replacements=0
errors=0
summary_file="$(mktemp 2>/dev/null || echo /tmp/fix-legacy-summary.$$)"
: > "$summary_file"

while IFS= read -r -d '' f; do
  rel="${f#$REPO_ROOT/}"
  [[ "$rel" =~ $skip_ext_re ]] && continue
  [[ "$rel" =~ $self_re ]] && continue
  rel_lc="$(printf '%s' "$rel" | tr 'A-Z' 'a-z')"
  [[ "$rel_lc" =~ $docs_re ]] && continue

  # Apply path filter (file must live under at least one allowed path)
  if [ "${#PATH_FILTERS[@]}" -gt 0 ]; then
    is_allowed=0
    for pf in "${PATH_FILTERS[@]}"; do
      if [ "$rel" = "$pf" ] || [[ "$rel" == "$pf"/* ]]; then
        is_allowed=1
        break
      fi
    done
    [ "$is_allowed" -eq 0 ] && continue
  fi

  if ! grep -Eq "$match_re" "$f" 2>/dev/null; then
    continue
  fi

  # Count occurrences before rewriting
  count=$(grep -Eo "$match_re" "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ -z "$count" ] || [ "$count" = "0" ] && continue

  if [ "$DRY_RUN" != "1" ]; then
    # Timestamped backup BEFORE we touch the file. Backup failure is fatal
    # for that file (we never want a half-backed rollback set).
    if [ "$backup_active" = "1" ]; then
      bdest="$backup_dir/$rel"
      bdir="$(dirname "$bdest")"
      if ! mkdir -p "$bdir" 2>/dev/null; then
        file_error "$bdir" "cannot create backup subdir"
        errors=$((errors+1))
        continue
      fi
      if ! cp -p "$f" "$bdest" 2>/dev/null; then
        file_error "$bdest" "backup copy failed (source: $f)"
        errors=$((errors+1))
        continue
      fi
    fi

    tmp="${f}.fixlegacy.$$"
    if ! sed -E "s/scripts-fixer-v(${alt})\b/scripts-fixer-${FIX_TARGET}/g" "$f" > "$tmp" 2>/dev/null; then
      file_error "$f" "sed rewrite failed"
      errors=$((errors+1))
      rm -f "$tmp"
      continue
    fi
    if ! mv "$tmp" "$f" 2>/dev/null; then
      file_error "$f" "replace failed (mv)"
      errors=$((errors+1))
      rm -f "$tmp"
      continue
    fi
  fi

  printf '  %4dx  %s\n' "$count" "$rel" >> "$summary_file"
  changed_files=$((changed_files+1))
  total_replacements=$((total_replacements+count))
done < <(find "$REPO_ROOT" \( $prune_dirs \) -prune -o -type f -print0 2>/dev/null)

echo
printf '%s========== summary ==========%s\n' "$MAG" "$RST"
cat "$summary_file"
echo '-----------------------------'
echo "files changed:    $changed_files"
echo "total rewrites:   $total_replacements"
echo "errors:           $errors"

# ---- JSON report ------------------------------------------------------------
if [ -n "$REPORT_FILE" ]; then
  case "$REPORT_FILE" in
    /*) report_path="$REPORT_FILE" ;;
    *)  report_path="$REPO_ROOT/$REPORT_FILE" ;;
  esac
  report_dir="$(dirname "$report_path")"
  if ! mkdir -p "$report_dir" 2>/dev/null; then
    file_error "$report_dir" "cannot create report directory"
  else
    mode_str="apply"
    [ "$DRY_RUN" = "1" ] && mode_str="dry-run"
    versions_json="$(echo "$FIX_VERSIONS" | tr -s ' ' | sed 's/^ *//; s/ *$//' | tr ' ' ',' )"
    versions_json="[${versions_json}]"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

    {
      printf '{\n'
      printf '  "tool": "fix-legacy-fixer-refs.sh",\n'
      printf '  "generatedAt": "%s",\n' "$ts"
      printf '  "repoRoot": "%s",\n' "$REPO_ROOT"
      printf '  "mode": "%s",\n' "$mode_str"
      printf '  "target": "scripts-fixer-%s",\n' "$FIX_TARGET"
      printf '  "legacyVersions": %s,\n' "$versions_json"
      backup_json="null"
      if [ "$backup_active" = "1" ]; then
        esc_bdir="$(printf '%s' "$backup_dir" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
        backup_json="\"$esc_bdir\""
      fi
      printf '  "backupDir": %s,\n' "$backup_json"
      printf '  "totals": { "filesChanged": %d, "totalReplacements": %d, "errors": %d },\n' \
             "$changed_files" "$total_replacements" "$errors"
      printf '  "files": ['
      first=1
      while IFS= read -r line; do
        # lines look like:  "  1234x  some/rel/path"
        cnt="$(echo "$line" | sed -E 's/^[[:space:]]*([0-9]+)x.*/\1/')"
        path="$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+x[[:space:]]+//')"
        # JSON-escape backslashes and double quotes in the path
        esc_path="$(printf '%s' "$path" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
        if [ $first -eq 1 ]; then
          printf '\n    { "path": "%s", "count": %s }' "$esc_path" "$cnt"
          first=0
        else
          printf ',\n    { "path": "%s", "count": %s }' "$esc_path" "$cnt"
        fi
      done < "$summary_file"
      [ $first -eq 0 ] && printf '\n  '
      printf ']\n'
      printf '}\n'
    } > "$report_path" 2>/dev/null

    if [ -s "$report_path" ]; then
      info "report:   $report_path"
    else
      file_error "$report_path" "failed to write JSON report"
    fi
  fi
fi

rm -f "$summary_file"

if [ "$DRY_RUN" = "1" ]; then warn "dry-run: no files were modified"; fi

if [ "$errors" -gt 0 ]; then exit 2; fi
if [ "$changed_files" -eq 0 ]; then
  ok "nothing to fix - repo already clean"
  exit 0
fi
[ "$DRY_RUN" = "1" ] && exit 0
ok "rewrote $total_replacements occurrence(s) across $changed_files file(s)"
exit 0
