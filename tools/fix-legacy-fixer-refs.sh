#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  fix-legacy-fixer-refs.sh
#  One-command auto-fix: rewrites scripts-fixer-v8/v9/v10 -> scripts-fixer-v11
#  across every text file in the repo (including lockfiles).
#
#  Usage:
#    ./tools/fix-legacy-fixer-refs.sh                # apply changes
#    DRY_RUN=1 ./tools/fix-legacy-fixer-refs.sh      # preview only
#    FIX_TARGET=v11 FIX_VERSIONS="8 9 10" ./tools/fix-legacy-fixer-refs.sh
# --------------------------------------------------------------------------
set -u

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

if [ ! -d "$REPO_ROOT" ]; then
  file_error "$REPO_ROOT" "repo root does not exist"
  exit 2
fi

info "repo:     $REPO_ROOT"
info "rewrite:  $(for v in $FIX_VERSIONS; do printf 'scripts-fixer-v%s ' "$v"; done)-> scripts-fixer-$FIX_TARGET"
if [ "$DRY_RUN" = "1" ]; then info "mode:     dry-run"; else info "mode:     apply"; fi

# Build a single regex alternation: scripts-fixer-v(8|9|10)
alt="$(echo "$FIX_VERSIONS" | tr ' ' '|')"
match_re="scripts-fixer-v(${alt})"

# Skip patterns
prune_dirs='-name .git -o -name node_modules -o -name dist -o -name build -o -name .next -o -name .turbo -o -name .cache -o -name coverage -o -name .lovable'
skip_ext_re='\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|tgz|7z|rar|exe|dll|bin|lockb|woff2?|ttf|otf|mp3|mp4|mov|wav)$'
self_re='(fix|scan)-legacy-fixer-refs\.(sh|ps1)$'

changed_files=0
total_replacements=0
errors=0
summary_file="$(mktemp 2>/dev/null || echo /tmp/fix-legacy-summary.$$)"
: > "$summary_file"

while IFS= read -r -d '' f; do
  rel="${f#$REPO_ROOT/}"
  [[ "$rel" =~ $skip_ext_re ]] && continue
  [[ "$rel" =~ $self_re ]] && continue

  if ! grep -Eq "$match_re" "$f" 2>/dev/null; then
    continue
  fi

  # Count occurrences before rewriting
  count=$(grep -Eo "$match_re" "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ -z "$count" ] || [ "$count" = "0" ] && continue

  if [ "$DRY_RUN" != "1" ]; then
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
