#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  fix-and-verify-legacy-refs.sh
#  One-command pipeline:
#    1. Dry-run the fixer to PREVIEW what would change
#    2. APPLY the rewrite (scripts-fixer-v8/v9/v10 -> v11)
#    3. Run the scanner; FAIL the whole command unless it reports PASS
#
#  Use this when you want a single safe command that previews, fixes, and
#  proves the repo is clean afterwards. If any step errors out, the whole
#  pipeline exits non-zero and no further steps run.
#
#  Usage:
#    bash tools/fix-and-verify-legacy-refs.sh
#    SKIP_APPLY=1 bash tools/fix-and-verify-legacy-refs.sh   # preview + scan only
#    REPORT_FILE=my-report.json bash tools/fix-and-verify-legacy-refs.sh
#
#  Exit codes:
#    0 = dry-run + apply succeeded AND scanner reports PASS
#    1 = post-apply scanner reports FAIL (legacy refs still present)
#    2 = error in dry-run or apply step (exact file/path + reason logged)
# --------------------------------------------------------------------------
set -u

CYN=$'\e[36m'; GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; MAG=$'\e[35m'; RST=$'\e[0m'
step()  { printf '\n%s== %s ==%s\n' "$MAG" "$*" "$RST"; }
info()  { printf '%s[info ]%s %s\n' "$CYN" "$RST" "$*"; }
ok()    { printf '%s[ ok  ]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[warn ]%s %s\n' "$YLW" "$RST" "$*"; }
fail()  { printf '%s[fail ]%s %s\n' "$RED" "$RST" "$*"; }
file_error() { printf '%s[fail ]%s file=%s reason=%s\n' "$RED" "$RST" "$1" "$2"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXER="$SCRIPT_DIR/fix-legacy-fixer-refs.sh"
SCANNER="$SCRIPT_DIR/scan-legacy-fixer-refs.sh"
SKIP_APPLY="${SKIP_APPLY:-0}"

for required in "$FIXER" "$SCANNER"; do
  if [ ! -f "$required" ]; then
    file_error "$required" "required script missing"
    exit 2
  fi
done

# --- Step 1: dry-run preview ----------------------------------------------
step "Step 1/3  dry-run preview"
info "running: DRY_RUN=1 bash $FIXER"
if ! DRY_RUN=1 bash "$FIXER"; then
  rc=$?
  fail "dry-run preview failed (exit $rc) -- aborting before any writes"
  exit 2
fi
ok "dry-run preview completed cleanly"

# --- Step 2: apply (skippable) --------------------------------------------
if [ "$SKIP_APPLY" = "1" ]; then
  step "Step 2/3  apply  (SKIPPED via SKIP_APPLY=1)"
  warn "skipping apply step -- repo will not be modified"
else
  step "Step 2/3  apply rewrite"
  info "running: bash $FIXER"
  if ! bash "$FIXER"; then
    rc=$?
    fail "apply step failed (exit $rc) -- see logs above for exact file + reason"
    exit 2
  fi
  ok "apply step completed"
fi

# --- Step 3: scanner verdict (gates exit code) ----------------------------
step "Step 3/3  post-apply scanner (PASS required)"
info "running: bash $SCANNER"
if bash "$SCANNER"; then
  ok "scanner reports PASS -- repo is clean"
  exit 0
else
  rc=$?
  if [ "$rc" = "1" ]; then
    fail "scanner reports FAIL -- legacy scripts-fixer-v8/v9/v10 references still present"
    exit 1
  fi
  fail "scanner errored (exit $rc)"
  exit 2
fi
