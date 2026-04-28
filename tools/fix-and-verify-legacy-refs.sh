#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  fix-and-verify-legacy-refs.sh
#  One-command pipeline:
#    1. Dry-run the fixer to PREVIEW what would change
#    2. APPLY the rewrite (scripts-fixer-v12/v9/v10 -> v11) with timestamped
#       backups under .legacy-fix-backups/<UTC-timestamp>/
#    3. Run the scanner; if it FAILS, AUTO-ROLLBACK from the backup so the
#       repo is restored to its pre-apply state.
#
#  Use this when you want a single safe command that previews, fixes, proves
#  the repo is clean afterwards, and self-heals on failure.
#
#  Usage:
#    bash tools/fix-and-verify-legacy-refs.sh
#    SKIP_APPLY=1 bash tools/fix-and-verify-legacy-refs.sh   # preview + scan only
#    NO_BACKUP=1  bash tools/fix-and-verify-legacy-refs.sh   # disable backups (no rollback safety net)
#    NO_ROLLBACK=1 bash tools/fix-and-verify-legacy-refs.sh  # keep changes even if scanner FAILs
#    REPORT_FILE=my-report.json bash tools/fix-and-verify-legacy-refs.sh
#
#  Exit codes:
#    0 = dry-run + apply succeeded AND scanner reports PASS
#    1 = post-apply scanner reports FAIL (auto-rollback was attempted unless
#        NO_ROLLBACK=1; rollback success/failure is logged either way)
#    2 = error in dry-run, apply, or rollback step (exact file/path + reason)
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
REPO_ROOT_RESOLVED="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXER="$SCRIPT_DIR/fix-legacy-fixer-refs.sh"
SCANNER="$SCRIPT_DIR/scan-legacy-fixer-refs.sh"
SKIP_APPLY="${SKIP_APPLY:-0}"
NO_BACKUP="${NO_BACKUP:-0}"
NO_ROLLBACK="${NO_ROLLBACK:-0}"
REPORT_FILE="${REPORT_FILE:-legacy-fix-report.json}"

for required in "$FIXER" "$SCANNER"; do
  if [ ! -f "$required" ]; then
    file_error "$required" "required script missing"
    exit 2
  fi
done

# Stable backup stamp shared across this whole pipeline run so we can find
# the directory the fixer created when we need to restore.
BACKUP_STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)"
export BACKUP_STAMP
case "${BACKUP_ROOT:-.legacy-fix-backups}" in
  /*) BACKUP_DIR_ABS="${BACKUP_ROOT:-.legacy-fix-backups}/$BACKUP_STAMP" ;;
  *)  BACKUP_DIR_ABS="$REPO_ROOT_RESOLVED/${BACKUP_ROOT:-.legacy-fix-backups}/$BACKUP_STAMP" ;;
esac

# --- Step 1: dry-run preview ----------------------------------------------
step "Step 1/3  dry-run preview"
info "running: DRY_RUN=1 REPORT_FILE=$REPORT_FILE bash $FIXER"
if ! DRY_RUN=1 REPORT_FILE="$REPORT_FILE" bash "$FIXER"; then
  rc=$?
  fail "dry-run preview failed (exit $rc) -- aborting before any writes"
  exit 2
fi
ok "dry-run preview completed cleanly"

# --- Step 2: apply (skippable, with backups by default) -------------------
if [ "$SKIP_APPLY" = "1" ]; then
  step "Step 2/3  apply  (SKIPPED via SKIP_APPLY=1)"
  warn "skipping apply step -- repo will not be modified"
  apply_ran=0
else
  if [ "$NO_BACKUP" = "1" ]; then
    step "Step 2/3  apply rewrite  (NO BACKUP -- rollback disabled)"
    warn "NO_BACKUP=1 -- post-apply rollback will NOT be possible"
    info "running: REPORT_FILE=$REPORT_FILE bash $FIXER"
    if ! REPORT_FILE="$REPORT_FILE" bash "$FIXER"; then
      rc=$?
      fail "apply step failed (exit $rc) -- see logs above for exact file + reason"
      exit 2
    fi
  else
    step "Step 2/3  apply rewrite  (with backups -> $BACKUP_DIR_ABS)"
    info "running: BACKUP=1 BACKUP_STAMP=$BACKUP_STAMP REPORT_FILE=$REPORT_FILE bash $FIXER"
    if ! BACKUP=1 BACKUP_STAMP="$BACKUP_STAMP" REPORT_FILE="$REPORT_FILE" bash "$FIXER"; then
      rc=$?
      fail "apply step failed (exit $rc) -- see logs above for exact file + reason"
      exit 2
    fi
  fi
  apply_ran=1
  ok "apply step completed"
fi

# --- Step 3: scanner verdict (gates exit code, triggers rollback) ---------
step "Step 3/3  post-apply scanner (PASS required)"
info "running: bash $SCANNER"
bash "$SCANNER"
scan_rc=$?
if [ "$scan_rc" = "0" ]; then
  ok "scanner reports PASS -- repo is clean"
  # Remove the backup directory if it ended up empty (no files were rewritten),
  # so successful no-op runs don't litter the repo.
  if [ -d "$BACKUP_DIR_ABS" ] && [ -z "$(ls -A "$BACKUP_DIR_ABS" 2>/dev/null)" ]; then
    rmdir "$BACKUP_DIR_ABS" 2>/dev/null || true
    # And the parent if it's now empty too
    parent_dir="$(dirname "$BACKUP_DIR_ABS")"
    [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir" 2>/dev/null)" ] && rmdir "$parent_dir" 2>/dev/null || true
  fi
  exit 0
fi
if [ "$scan_rc" != "1" ]; then
  fail "scanner errored (exit $scan_rc)"
  exit 2
fi

fail "scanner reports FAIL -- legacy scripts-fixer-v12/v9/v10 references still present"

# Decide whether to roll back.
can_rollback=1
[ "$apply_ran" = "0" ] && can_rollback=0
[ "$NO_BACKUP" = "1" ]  && can_rollback=0
[ "$NO_ROLLBACK" = "1" ] && can_rollback=0
[ -d "$BACKUP_DIR_ABS" ] || can_rollback=0

if [ "$can_rollback" != "1" ]; then
  if [ "$NO_ROLLBACK" = "1" ]; then
    warn "NO_ROLLBACK=1 -- leaving rewritten files in place"
  elif [ "$NO_BACKUP" = "1" ]; then
    warn "no backup was taken (NO_BACKUP=1) -- cannot auto-rollback"
  elif [ "$apply_ran" = "0" ]; then
    warn "apply step was skipped -- nothing to roll back"
  else
    file_error "$BACKUP_DIR_ABS" "backup directory not found -- cannot auto-rollback"
  fi
  exit 1
fi

# --- Auto-rollback: copy every backed-up file back over its original ------
step "Auto-rollback from $BACKUP_DIR_ABS"
restore_count=0
restore_errors=0
# Use a portable find that handles spaces. Mirror the backup tree under repo root.
while IFS= read -r -d '' bfile; do
  rel="${bfile#$BACKUP_DIR_ABS/}"
  dest="$REPO_ROOT_RESOLVED/$rel"
  ddir="$(dirname "$dest")"
  if ! mkdir -p "$ddir" 2>/dev/null; then
    file_error "$ddir" "cannot create restore parent dir"
    restore_errors=$((restore_errors+1))
    continue
  fi
  if ! cp -p "$bfile" "$dest" 2>/dev/null; then
    file_error "$dest" "restore copy failed (backup: $bfile)"
    restore_errors=$((restore_errors+1))
    continue
  fi
  restore_count=$((restore_count+1))
done < <(find "$BACKUP_DIR_ABS" -type f -print0 2>/dev/null)

if [ "$restore_errors" -gt 0 ]; then
  fail "rollback completed with $restore_errors error(s); $restore_count file(s) restored"
  fail "backup retained at: $BACKUP_DIR_ABS"
  exit 2
fi

ok "rollback restored $restore_count file(s) from $BACKUP_DIR_ABS"
warn "scanner FAILed -- repo is back to its pre-apply state. Investigate before retrying."
exit 1
