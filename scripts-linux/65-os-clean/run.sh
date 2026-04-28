#!/usr/bin/env bash
# 65-os-clean -- Cross-OS user/system cleanup for Linux + macOS.
# Apply by default; pass --dry-run for a preview. Subverbs:
#   run | list-categories | help
#
# Per-run logs:    $ROOT/.logs/65/<TS>/{command.txt,manifest.json,session.log}
# Manifest schema mirrors Windows scripts/os/helpers/clean.ps1 results so
# downstream dashboards can consume both with one parser.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="65"

. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/confirm.sh"
. "$ROOT/_shared/verify.sh"
. "$SCRIPT_DIR/helpers/sweep.sh"
. "$SCRIPT_DIR/helpers/categories.sh"

CONFIG="$SCRIPT_DIR/config.json"
LOG_MSGS="$SCRIPT_DIR/log-messages.json"
# LOGS_OVERRIDE lets the smoke test redirect logs into a sandbox so a
# CI run never touches the real $ROOT/.logs/65 tree.
LOGS_ROOT="${LOGS_OVERRIDE:-$ROOT/.logs/65}"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOGS_ROOT/$TS"

# ---------- arg parse -----------------------------------------------------
VERB=""
DRY_RUN=0
APPLY_FORCED=0
ONLY_CSV=""
EXCLUDE_CSV=""
ASSUME_YES=0
JSON_OUT=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    run|list-categories|help|--help|-h) [ -z "$VERB" ] && VERB="$1"; shift ;;
    --dry-run|-n)     DRY_RUN=1; shift ;;
    --apply)          APPLY_FORCED=1; shift ;;
    --only)           ONLY_CSV="$2"; shift 2 ;;
    --only=*)         ONLY_CSV="${1#--only=}"; shift ;;
    --exclude)        EXCLUDE_CSV="$2"; shift 2 ;;
    --exclude=*)      EXCLUDE_CSV="${1#--exclude=}"; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --json)           JSON_OUT=1; shift ;;
    --no-color)       export NO_COLOR=1; shift ;;
    --quiet|-q)       QUIET=1; shift ;;
    --)               shift; break ;;
    *)
      log_warn "Unknown flag: $1"
      shift
      ;;
  esac
done
[ -z "$VERB" ] && VERB="run"

# In --json mode, route ALL log output to stderr so stdout contains only
# the JSON document. Re-point fd 1 -> 2 from this point on, except where
# we explicitly print the JSON document.
if [ "$JSON_OUT" -eq 1 ]; then
  exec 3>&1 1>&2
fi

# ---------- bootstrap -----------------------------------------------------
ensure_run_dir() {
  if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
    log_file_error "$RUN_DIR" "mkdir failed (permission or filesystem error)"
    return 1
  fi
  printf '%s\n' "$0 $*" > "$RUN_DIR/command.txt" 2>/dev/null \
    || log_file_error "$RUN_DIR/command.txt" "write failed"
  ln -sfn "$TS" "$LOGS_ROOT/latest" 2>/dev/null || true
}

osc_init "$CONFIG" || exit 2
ensure_run_dir

OS="$(osc_os)"
MODE_LABEL="apply"
SW_DRY_RUN=0
if [ "$DRY_RUN" -eq 1 ]; then
  MODE_LABEL="dry-run"
  SW_DRY_RUN=1
fi
export SW_DRY_RUN

# Helpers for destructive consent + filters.
_destructive_required=()
while IFS= read -r line; do [ -n "$line" ] && _destructive_required+=("$line"); done < <(osc_destructive_requires_yes)

_excluded=()
while IFS= read -r line; do [ -n "$line" ] && _excluded+=("$line"); done < <(osc_excluded_default)
if [ -n "$EXCLUDE_CSV" ]; then
  IFS=',' read -r -a _xtra <<<"$EXCLUDE_CSV"
  for x in "${_xtra[@]}"; do [ -n "$x" ] && _excluded+=("$x"); done
fi

_only=()
if [ -n "$ONLY_CSV" ]; then
  IFS=',' read -r -a _only <<<"$ONLY_CSV"
fi

_is_excluded() { osc_in_list "$1" "${_excluded[@]:-}"; }
_is_only_match() {
  [ "${#_only[@]}" -eq 0 ] && return 0
  osc_in_list "$1" "${_only[@]}"
}
_needs_yes() { osc_in_list "$1" "${_destructive_required[@]:-}"; }

# ---------- subverb: list-categories --------------------------------------
if [ "$VERB" = "list-categories" ]; then
  printf '\n  os-clean (script 65) :: defined categories on %s\n' "$OS"
  printf '  %s\n' "$(printf '=%.0s' {1..60})"
  while IFS= read -r cat; do
    [ -z "$cat" ] && continue
    label=$(osc_field "$cat" "label")
    bucket=$(osc_field "$cat" "bucket")
    destr=$(osc_field "$cat" "destructive")
    osonly=$(osc_field "$cat" "osOnly")
    cmd=$(osc_field "$cat" "command")
    flag=""
    [ "$destr" = "true" ] && flag=" [destructive]"
    [ -n "$cmd" ] && [ "$cmd" != "null" ] && flag="$flag [cmd:$cmd]"
    [ -n "$osonly" ] && [ "$osonly" != "null" ] && flag="$flag [linux-only]"
    printf '  %-18s  %s  %s%s\n' "$cat" "$bucket" "$label" "$flag"
  done < <(osc_category_ids)
  exit 0
fi

# ---------- subverb: help -------------------------------------------------
if [ "$VERB" = "help" ] || [ "$VERB" = "--help" ] || [ "$VERB" = "-h" ]; then
  cat <<'EOF'

  os-clean (script 65) -- cross-OS cleanup

  USAGE
    scripts-linux/run.sh 65 [run|list-categories|help] [flags]

  FLAGS
    --dry-run         preview only (no deletions, no package mutations)
    --apply           force apply mode (default)
    --only A,B,C      limit to these categories
    --exclude A,B,C   skip these categories
    --yes             pre-approve destructive categories (trash, logs-system)
    --json            emit a single JSON object on stdout
    --no-color        disable ANSI colours
    --quiet           suppress per-item locked-path notes

  EXAMPLES
    scripts-linux/run.sh 65
    scripts-linux/run.sh 65 --dry-run
    scripts-linux/run.sh 65 --only caches-user,pkg-bun
    scripts-linux/run.sh 65 --yes --only trash

EOF
  exit 0
fi

# ---------- subverb: run --------------------------------------------------
log_info "===== os-clean (script 65) on $OS -- mode=$MODE_LABEL ====="
if [ "$DRY_RUN" -eq 1 ]; then
  log_info "DRY-RUN mode: no changes will be made."
else
  log_info "APPLY mode: changes will be made. Pass --dry-run to preview only."
fi

# Validate --only ids before any deletions.
if [ "${#_only[@]}" -gt 0 ]; then
  all_ids=()
  while IFS= read -r line; do [ -n "$line" ] && all_ids+=("$line"); done < <(osc_category_ids)
  for want in "${_only[@]}"; do
    if ! osc_in_list "$want" "${all_ids[@]}"; then
      log_err "Unknown category '$want' (not in config.categories). Aborting before any deletions."
      exit 2
    fi
  done
fi

# Per-category result rows accumulated for the manifest.
ROWS_TSV="$RUN_DIR/rows.tsv"   # status \t cat \t label \t bucket \t count \t bytes \t locked
# Per-target rows from the sweep helpers, populated when SW_TARGETS_TSV is
# exported (see helpers/sweep.sh). Used to build PLAN_TSV (for confirm)
# and to feed _shared/verify.sh.
TARGETS_TSV="$RUN_DIR/targets.tsv"  # status \t kind \t target \t bytes \t detail
PLAN_TSV="$RUN_DIR/plan.tsv"        # bucket \t kind \t target \t detail
VERIFY_TSV="$RUN_DIR/verify.tsv"    # populated by verify_run
: > "$ROWS_TSV"
: > "$TARGETS_TSV" || log_file_error "$TARGETS_TSV" "failed to truncate targets TSV"
: > "$PLAN_TSV"    || log_file_error "$PLAN_TSV"    "failed to truncate plan TSV"
export SW_TARGETS_TSV="$TARGETS_TSV"

TOTAL_COUNT=0
TOTAL_BYTES=0
TOTAL_LOCKED=0

_emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$ROWS_TSV"
}

_run_category() {
  local cat="$1"
  local label bucket destr osonly mode cmd preserve req_sudo
  label=$(osc_field "$cat" "label")
  bucket=$(osc_field "$cat" "bucket")
  destr=$(osc_field "$cat" "destructive")
  osonly=$(osc_field "$cat" "osOnly")
  mode=$(osc_field "$cat" "mode")
  cmd=$(osc_field "$cat" "command")
  preserve=$(osc_field "$cat" "preserveSubdirs")
  req_sudo=$(osc_field "$cat" "requiresSudo")

  # Filter: --only / --exclude.
  if ! _is_only_match "$cat"; then
    log_info "[$cat] skipped (does not match --only filter)"
    _emit_row "skip" "$cat" "$label" "$bucket" 0 0 0
    return 0
  fi
  if _is_excluded "$cat"; then
    log_info "[$cat] skipped (excluded via config or --exclude)"
    _emit_row "skip" "$cat" "$label" "$bucket" 0 0 0
    return 0
  fi
  if [ -n "$osonly" ] && [ "$osonly" != "null" ] && [ "$osonly" != "$OS" ]; then
    log_info "[$cat] skipped (osOnly=$osonly, current=$OS)"
    _emit_row "skip" "$cat" "$label" "$bucket" 0 0 0
    return 0
  fi
  if [ "$destr" = "true" ] && [ "$ASSUME_YES" -ne 1 ] && _needs_yes "$cat"; then
    log_warn "[$cat] destructive category requires --yes. Skipping."
    _emit_row "skip" "$cat" "$label" "$bucket" 0 0 0
    return 0
  fi

  log_info "[$cat] $label ($bucket) -- scanning"
  sweep_reset

  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
    # Command-driven category (apt/brew/journalctl/etc).
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_info "[$cat] skipped (command '$cmd' not on PATH)"
      _emit_row "skip" "$cat" "$label" "$bucket" 0 0 0
      return 0
    fi
    local sizepath
    sizepath=$(osc_field "$cat" "sizePath")
    [ "$sizepath" = "null" ] && sizepath=""
    sizepath=$(eval printf '%s' "\"$sizepath\"" 2>/dev/null || true)
    local argv=()
    if [ "$DRY_RUN" -eq 1 ]; then
      while IFS= read -r tok; do [ -n "$tok" ] && argv+=("$tok"); done < <(osc_cmd_array "$cat" "dryCmd")
    else
      while IFS= read -r tok; do [ -n "$tok" ] && argv+=("$tok"); done < <(osc_cmd_array "$cat" "applyCmd")
    fi
    if [ "${#argv[@]}" -eq 0 ]; then
      log_warn "[$cat] no $( [ "$DRY_RUN" -eq 1 ] && echo dryCmd || echo applyCmd ) defined -- skipping"
      _emit_row "skip" "$cat" "$label" "$bucket" 0 0 0
      return 0
    fi
    log_info "[$cat] running: ${argv[*]}"
    sweep_command "$sizepath" "${argv[@]}" >/dev/null 2>&1 || true
  else
    # Path-driven category.
    local pp
    while IFS= read -r pp; do
      [ -z "$pp" ] && continue
      case "$mode" in
        glob)
          # Either an absolute glob OR a parent dir + globPatterns.
          if [ -d "$pp" ]; then
            # Apply each globPattern under this dir.
            local pat
            while IFS= read -r pat; do
              [ -z "$pat" ] && continue
              sweep_glob "$pat" --root "$pp"
            done < <(_osc_query ".categories.\"$cat\".globPatterns[]" 2>/dev/null)
          else
            sweep_glob "$pp"
          fi
          ;;
        contents|*)
          if [ "$preserve" != "null" ] && [ -n "$preserve" ]; then
            local preserve_csv
            # jq pretty-prints the array across multiple lines; strip every
            # bracket/quote/space/newline so the result is a clean CSV.
            preserve_csv=$(printf '%s' "$preserve" | tr -d '[]" \n\r\t' )
            sweep_contents "$pp" --preserve "$preserve_csv"
          else
            sweep_contents "$pp"
          fi
          ;;
      esac
    done < <(osc_paths_for_os "$cat" "$OS")
  fi

  local human; human=$(sweep_human_bytes "$_SW_BYTES")
  local status="ok"
  [ "$DRY_RUN" -eq 1 ] && status="dry-run"
  [ "$_SW_LOCKED" -gt 0 ] && status="warn"

  if [ "$DRY_RUN" -eq 1 ]; then
    log_ok "[$cat] DRY-RUN: would free ${human} across ${_SW_COUNT} item(s)"
  else
    log_ok "[$cat] freed ${human} across ${_SW_COUNT} item(s) (locked: ${_SW_LOCKED})"
  fi
  if [ "$QUIET" -ne 1 ] && [ -n "$_SW_LOCKS" ]; then
    printf '%s' "$_SW_LOCKS" | while IFS='|' read -r p r; do
      [ -n "$p" ] && log_warn "  locked: $p ($r)"
    done
  fi

  TOTAL_COUNT=$((TOTAL_COUNT + _SW_COUNT))
  TOTAL_BYTES=$((TOTAL_BYTES + _SW_BYTES))
  TOTAL_LOCKED=$((TOTAL_LOCKED + _SW_LOCKED))
  _emit_row "$status" "$cat" "$label" "$bucket" "$_SW_COUNT" "$_SW_BYTES" "$_SW_LOCKED"
}

# Iterate categories. Wrapped in a function so plan-then-confirm can run
# the loop twice: once in forced dry-run to build the plan, once in apply
# to actually do the work.
_iterate_all_categories() {
  : > "$ROWS_TSV"     || log_file_error "$ROWS_TSV"     "failed to truncate rows TSV"
  : > "$TARGETS_TSV"  || log_file_error "$TARGETS_TSV"  "failed to truncate targets TSV"
  TOTAL_COUNT=0
  TOTAL_BYTES=0
  TOTAL_LOCKED=0
  while IFS= read -r cat; do
    [ -z "$cat" ] && continue
    _run_category "$cat" || log_warn "Category '$cat' raised an error -- continuing."
  done < <(osc_category_ids)
}

# ---------- plan -> confirm -> apply phasing -------------------------------
# Behaviour:
#   * --dry-run        -> single dry-run pass, no plan/confirm wrapper
#   * apply (default)  -> forced dry-run pass first (PLAN), render plan tree
#                         + table, prompt operator (or honour --yes), then
#                         reset and run the real APPLY pass.
# Aborting at the prompt leaves the plan TSV on disk for inspection and
# skips the verify phase (nothing was applied).
APPLY_ABORTED=0
if [ "$DRY_RUN" -eq 1 ]; then
  log_info "===== single dry-run pass (no plan/confirm wrapper needed) ====="
  _iterate_all_categories
else
  log_info "===== plan phase -- nothing will be removed yet ====="
  SW_DRY_RUN=1; export SW_DRY_RUN
  _iterate_all_categories

  # Convert TARGETS_TSV (status\tkind\ttarget\tbytes\tdetail) into the
  # PLAN_TSV schema confirm_render_plan expects (bucket\tkind\ttarget\tdetail).
  # 65's per-target rows are not category-tagged at the sweep layer; we
  # default the bucket to "user" (correct for the vast majority of
  # categories) and override to "command" for command-driven targets that
  # are emitted with a "cmd:..." synthetic target name.
  : > "$PLAN_TSV"
  while IFS=$'\t' read -r status kind target bytes detail; do
    [ "$status" = "would" ] || continue
    # Heuristic bucket: command-driven targets (target prefix "cmd:") fall
    # under the bucket of their owning category, but since 65 doesn't tag
    # them in the TARGETS_TSV directly we default to "user" (matches the
    # vast majority of categories) and let the operator inspect the
    # detail column.
    plan_bucket="user"
    case "$target" in cmd:*) plan_bucket="command" ;; esac
    confirm_plan_add "$PLAN_TSV" "$plan_bucket" "$kind" "$target" "$detail"
  done < "$TARGETS_TSV"

  confirm_render_plan "$PLAN_TSV" "Planned os-clean actions"

  if ! confirm_prompt "$PLAN_TSV" "$ASSUME_YES"; then
    log_warn "Apply phase aborted. The plan above was NOT executed."
    log_info "Plan file kept for inspection: $PLAN_TSV"
    APPLY_ABORTED=1
    MODE_LABEL="aborted"
  else
    log_info "===== apply phase ====="
    SW_DRY_RUN=0; export SW_DRY_RUN
    _iterate_all_categories
  fi
fi

# ---------- verify --------------------------------------------------------
# Independent post-cleanup verification. Re-probes every removed/would
# target (file or dir) using _shared/verify.sh and emits a pass/fail
# report. Skipped only when the operator aborted at the prompt
# (APPLY_ABORTED=1) -- in dry-run we still verify so the operator can
# see "would these targets actually be gone if I applied?".
VERIFY_PASSES=0; VERIFY_FAILS=0; VERIFY_SKIPS=0
_mode_for_verify="$MODE_LABEL"
if [ "$APPLY_ABORTED" = "1" ]; then
  log_info "===== verify phase skipped (run aborted at confirmation prompt) ====="
else
  log_info "===== verify phase (re-probing every targeted item) ====="
  # Reshape TARGETS_TSV (status\tkind\ttarget\tbytes\tdetail) into the
  # verify_run input schema (status\tbucket\tkind\ttarget\tdetail).
  verify_input="$RUN_DIR/verify-input.tsv"
  : > "$verify_input" || log_file_error "$verify_input" "failed to truncate verify-input TSV"
  while IFS=$'\t' read -r vs vk vt vb vd; do
    [ -z "$vs" ] && continue
    vbucket="user"
    case "$vt" in cmd:*) vbucket="command" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$vs" "$vbucket" "$vk" "$vt" "$vd" >> "$verify_input"
  done < "$TARGETS_TSV"
  verify_run    "$verify_input" "$VERIFY_TSV" "$_mode_for_verify"
  verify_render "$VERIFY_TSV"   "os-clean verification report"
fi

# ---------- summary -------------------------------------------------------
human_total=$(sweep_human_bytes "$TOTAL_BYTES")

# verify_run (above) already populated $VERIFY_PASSES / $VERIFY_FAILS /
# $VERIFY_SKIPS as side-effect globals, so we just default them when
# verification was skipped (aborted run) and surface them in the summary.
VERIFY_PASSES="${VERIFY_PASSES:-0}"
VERIFY_FAILS="${VERIFY_FAILS:-0}"
VERIFY_SKIPS="${VERIFY_SKIPS:-0}"

if [ "$JSON_OUT" -eq 1 ]; then
  # Emit a single JSON document on the original stdout (fd 3 was opened
  # at the top of the script when --json was active; everything else is
  # already redirected to stderr).
  if command -v jq >/dev/null 2>&1; then
    awk -F'\t' 'BEGIN{print "["} NR>1{print ","} {
      printf "{\"status\":\"%s\",\"category\":\"%s\",\"label\":\"%s\",\"bucket\":\"%s\",\"count\":%s,\"bytes\":%s,\"locked\":%s}",
             $1,$2,$3,$4,$5,$6,$7
    } END{print "]"}' "$ROWS_TSV" > "$RUN_DIR/rows.json"
    jq -n \
      --arg os "$OS" --arg mode "$MODE_LABEL" --arg ts "$TS" \
      --argjson rows "$(cat "$RUN_DIR/rows.json")" \
      --argjson totalCount "$TOTAL_COUNT" \
      --argjson totalBytes "$TOTAL_BYTES" \
      --argjson totalLocked "$TOTAL_LOCKED" \
      '{os:$os,mode:$mode,timestamp:$ts,totals:{count:$totalCount,bytes:$totalBytes,locked:$totalLocked},rows:$rows}' >&3
  else
    {
      printf '{"os":"%s","mode":"%s","timestamp":"%s","totals":{"count":%s,"bytes":%s,"locked":%s},"rows":[' \
        "$OS" "$MODE_LABEL" "$TS" "$TOTAL_COUNT" "$TOTAL_BYTES" "$TOTAL_LOCKED"
      first=1
      while IFS=$'\t' read -r s c l b cnt by lk; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        # Rough JSON escaping for label (no newlines/quotes expected from config).
        l_esc=$(printf '%s' "$l" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"status":"%s","category":"%s","label":"%s","bucket":"%s","count":%s,"bytes":%s,"locked":%s}' \
          "$s" "$c" "$l_esc" "$b" "$cnt" "$by" "$lk"
      done < "$ROWS_TSV"
      printf ']}\n'
    } >&3
  fi
else
  printf '\n  ===== summary (%s) =====\n' "$MODE_LABEL"
  printf '  %-7s  %-22s  %-38s  %6s  %12s  %8s\n' "STATUS" "CATEGORY" "LABEL" "ITEMS" "BYTES" "VERIFIED"
  printf '  %s\n' "$(printf '%.0s-' {1..104})"
  while IFS=$'\t' read -r s c l b cnt by lk; do
    bh=$(sweep_human_bytes "$by")
    # Per-category verified marker: PASS if every targeted path under this
    # category passed re-probe, FAIL if any failed, "-" if no verify rows.
    vmark="-"
    if [ -s "$VERIFY_TSV" ]; then
      cat_fails=$(awk -F'\t' -v c="$c" '$1=="fail" && index($4, c) > 0 {n++} END{print n+0}' "$VERIFY_TSV" 2>/dev/null || echo 0)
      cat_pass=$(awk -F'\t' -v c="$c"  '$1=="pass" && index($4, c) > 0 {n++} END{print n+0}' "$VERIFY_TSV" 2>/dev/null || echo 0)
      if [ "$cat_fails" -gt 0 ]; then vmark="FAIL($cat_fails)"
      elif [ "$cat_pass" -gt 0 ]; then vmark="PASS($cat_pass)"
      fi
    fi
    printf '  %-7s  %-22s  %-38s  %6s  %12s  %8s\n' "$s" "$c" "$l" "$cnt" "$bh" "$vmark"
  done < "$ROWS_TSV"
  printf '  %s\n' "$(printf '%.0s-' {1..104})"
  printf '  TOTAL: %s item(s), %s (locked: %s)\n' "$TOTAL_COUNT" "$human_total" "$TOTAL_LOCKED"
  printf '  VERIFY: pass=%s fail=%s skipped=%s\n\n' "$VERIFY_PASSES" "$VERIFY_FAILS" "$VERIFY_SKIPS"
fi

# Always write the manifest, regardless of stdout mode.
manifest="$RUN_DIR/manifest.json"
{
  printf '{"os":"%s","mode":"%s","timestamp":"%s","totals":{"count":%s,"bytes":%s,"locked":%s},"rows":[' \
    "$OS" "$MODE_LABEL" "$TS" "$TOTAL_COUNT" "$TOTAL_BYTES" "$TOTAL_LOCKED"
  first=1
  while IFS=$'\t' read -r s c l b cnt by lk; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    l_esc=$(printf '%s' "$l" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"status":"%s","category":"%s","label":"%s","bucket":"%s","count":%s,"bytes":%s,"locked":%s}' \
      "$s" "$c" "$l_esc" "$b" "$cnt" "$by" "$lk"
  done < "$ROWS_TSV"
  printf '],"verification":{"pass":%s,"fail":%s,"skipped":%s,"rows":[' \
    "$VERIFY_PASSES" "$VERIFY_FAILS" "$VERIFY_SKIPS"
  vfirst=1
  if [ -s "$VERIFY_TSV" ]; then
    while IFS=$'\t' read -r vr vbk vk vt vd; do
      [ -z "$vr" ] && continue
      [ "$vfirst" -eq 1 ] || printf ','
      vfirst=0
      vt_esc=$(printf '%s' "$vt" | sed 's/\\/\\\\/g; s/"/\\"/g')
      vd_esc=$(printf '%s' "$vd" | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf '{"result":"%s","bucket":"%s","kind":"%s","target":"%s","detail":"%s"}' \
        "$vr" "$vbk" "$vk" "$vt_esc" "$vd_esc"
    done < "$VERIFY_TSV"
  fi
  printf ']}}\n'
} > "$manifest" 2>/dev/null \
  || log_file_error "$manifest" "manifest write failed"

if [ "$DRY_RUN" -eq 1 ]; then
  log_ok "Dry-run complete. $TOTAL_COUNT item(s), $human_total would be freed."
else
  log_ok "Done. $TOTAL_COUNT item(s), $human_total freed."
fi
exit 0