#!/usr/bin/env bash
# 67-vscode-cleanup-linux
#
# Detects which method was used to install VS Code on this Linux/Ubuntu
# machine (apt | snap | deb | tarball | user-config) and removes ONLY the
# matching files, packages, and configuration. Apply by default; pass
# --dry-run for a preview. Path/package allow-list lives in config.json --
# nothing outside that file is ever touched. Manifest is written to
# .logs/67/<TS>/manifest.json mirroring the schema used by scripts 65 & 66.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="67"

. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/confirm.sh"
. "$ROOT/_shared/verify.sh"
. "$SCRIPT_DIR/helpers/detect.sh"
. "$SCRIPT_DIR/helpers/remove.sh"

CONFIG="$SCRIPT_DIR/config.json"
LOGS_ROOT="${LOGS_OVERRIDE:-$ROOT/.logs/67}"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOGS_ROOT/$TS"
ROWS_TSV="$RUN_DIR/rows.tsv"
PLAN_TSV="$RUN_DIR/plan.tsv"
VERIFY_TSV="$RUN_DIR/verify.tsv"
export ROWS_TSV

# --------------------------------------------------------------------- args
VERB=""; DRY_RUN=0; SCOPE=""; ONLY_CSV=""; SKIP_DETECT=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    run|detect|resolve|list|help|--help|-h) [ -z "$VERB" ] && VERB="$1"; shift ;;
    --dry-run|-n)            DRY_RUN=1; shift ;;
    --scope)                 SCOPE="$2"; shift 2 ;;
    --scope=*)               SCOPE="${1#--scope=}"; shift ;;
    --system)                SCOPE="system"; shift ;;
    --user)                  SCOPE="user"; shift ;;
    --only)                  ONLY_CSV="$2"; shift 2 ;;
    --only=*)                ONLY_CSV="${1#--only=}"; shift ;;
    --skip-detect)           SKIP_DETECT=1; shift ;;
    --yes|-y)                ASSUME_YES=1; shift ;;
    --no-color)              export NO_COLOR=1; shift ;;
    *) log_warn "Unknown flag: $1"; shift ;;
  esac
done
[ -z "$VERB" ] && VERB="run"
export DRY_RUN

# --------------------------------------------------------------------- bootstrap
_jq() {
  if command -v jq >/dev/null 2>&1; then jq "$@" "$CONFIG"
  else
    log_err "jq is required by script 67 but is not installed. Install with: sudo apt-get install -y jq"
    return 1
  fi
}

ensure_run_dir() {
  if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
    log_file_error "$RUN_DIR" "mkdir failed (permission or filesystem error)"
    return 1
  fi
  printf '%s\n' "$0 $*" > "$RUN_DIR/command.txt" 2>/dev/null \
    || log_file_error "$RUN_DIR/command.txt" "write failed"
  : > "$ROWS_TSV"
  ln -sfn "$TS" "$LOGS_ROOT/latest" 2>/dev/null || true
}

if [ ! -f "$CONFIG" ]; then
  log_file_error "$CONFIG" "config.json missing -- aborting"
  exit 2
fi

# --------------------------------------------------------------------- subverb: help
if [ "$VERB" = "help" ] || [ "$VERB" = "--help" ] || [ "$VERB" = "-h" ]; then
  cat <<'EOF'

  vscode-cleanup-linux (script 67) -- detect & remove VS Code on Linux

  USAGE
    scripts-linux/run.sh 67 [run|detect|list|help] [flags]

  VERBS
    run        Detect install methods, then remove the matching artifacts (default).
    detect     Detect-only: print which install methods are present, no changes.
    resolve    Detect-only, print a SINGLE classification line + exit code:
                 0 = exactly one method present
                 1 = multiple methods present (prints all, picks the most specific)
                 2 = none detected
                 3 = jq missing or other internal error
               Output format (machine-parseable, single line):
                 method=<id>  edition=<stable|insiders|both>  detail='<probe detail>'
    list       Print the catalog of methods + their detection probes + removal steps.
    help       This help.

  FLAGS
    --dry-run, -n         Preview every targeted package/path. No deletions.
    --yes, -y             Skip the plan-then-confirm prompt (for CI / scripted use).
                          In apply mode the script first builds a plan, prints it
                          as a tree + table, and asks for confirmation. Pass --yes
                          to bypass the prompt. --dry-run never prompts.
    --scope user|system   user   = ~/.config, ~/.vscode, ~/.vscode-server, per-user shims only.
                          system = + apt/snap/dpkg removal + /usr/bin shims + /etc/apt sources.
                          Default: 'auto' = system if root, else user.
    --system, --user      Shortcuts for --scope system / --scope user.
    --only A,B,C          Limit to comma-separated method ids:
                            apt, snap, deb, tarball, binary, user-config
    --skip-detect         Run all methods listed in --only without first probing.
                          (Use only when you know which method was used.)
    --no-color            Disable ANSI colour output.

  EXAMPLES
    scripts-linux/run.sh 67 detect
    scripts-linux/run.sh 67 --dry-run
    scripts-linux/run.sh 67 --only user-config
    sudo scripts-linux/run.sh 67 --system

EOF
  exit 0
fi

# --------------------------------------------------------------------- subverb: list
if [ "$VERB" = "list" ]; then
  printf '\n  vscode-cleanup-linux :: catalog\n'
  printf '  %s\n' "$(printf '=%.0s' {1..70})"
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    case "$m" in _*) continue ;; esac
    label=$(_jq -r ".detectors.\"$m\".label")
    printf '  -- method: %-12s  %s\n' "$m" "$label"
    printf '     probes:\n'
    _jq -r ".detectors.\"$m\".probes[] | \"       \" + .kind + \"  \" + (.pkg // .path // \"-\")"
    printf '     actions:\n'
    _jq -r ".actions.\"$m\".steps[] | \"       \" + .kind + \"  \" + (.path // ((.pkgs // []) | join(\",\")) // \"-\")"
    printf '\n'
  done < <(_jq -r '.detectors | keys[]')
  exit 0
fi

# --------------------------------------------------------------------- run guards
ENABLED="$(_jq -r '.enabled')"
if [ "$ENABLED" != "true" ]; then
  log_warn "Script disabled in config.json (set 'enabled': true to run). Aborting."
  exit 0
fi

OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
if [ "$OS_NAME" != "Linux" ]; then
  log_err "This script targets Linux only. Detected OS: $OS_NAME. Aborting (no changes made)."
  exit 2
fi

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
export IS_ROOT
REQUESTED_SCOPE="$SCOPE"
if [ -z "$REQUESTED_SCOPE" ]; then
  REQUESTED_SCOPE="$(_jq -r '.defaultScope // "auto"')"
fi
RESOLVED_SCOPE="$REQUESTED_SCOPE"
case "$REQUESTED_SCOPE" in
  auto)
    if [ "$IS_ROOT" -eq 1 ]; then RESOLVED_SCOPE="system"; else RESOLVED_SCOPE="user"; fi ;;
  user|system) ;;
  *)
    log_err "Invalid --scope value '$REQUESTED_SCOPE'. Use one of: auto, user, system."
    exit 2 ;;
esac

ensure_run_dir

log_info "===== vscode-cleanup-linux (script 67) ====="
log_info "Resolved scope: requested='$REQUESTED_SCOPE', resolved='$RESOLVED_SCOPE' (root=$IS_ROOT)."
if [ "$VERB" != "detect" ] && [ "$VERB" != "resolve" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "DRY-RUN mode: no changes will be made."
  else
    log_info "APPLY mode: changes will be made. Pass --dry-run to preview only."
  fi
fi

# --------------------------------------------------------------------- detect phase
ALL_METHODS=()
while IFS= read -r m; do
  [ -z "$m" ] && continue
  case "$m" in _*) continue ;; esac
  ALL_METHODS+=("$m")
done < <(_jq -r '.detectors | keys[]')

# --only filter (intersection with detector keys)
ONLY_IDS=()
if [ -n "$ONLY_CSV" ]; then
  IFS=',' read -r -a ONLY_IDS <<<"$ONLY_CSV"
fi
_in_only() {
  [ "${#ONLY_IDS[@]}" -eq 0 ] && return 0
  local x="$1" y
  for y in "${ONLY_IDS[@]}"; do [ "$x" = "$y" ] && return 0; done
  return 1
}

log_info "===== detect phase (read-only) ====="
DETECTED_METHODS=()
DETECT_HITS_TSV="$RUN_DIR/detect-hits.tsv"
: > "$DETECT_HITS_TSV"

for m in "${ALL_METHODS[@]}"; do
  if ! _in_only "$m"; then
    log_info "  [$m] skipped (not in --only)"
    continue
  fi
  hit_count=0
  N=$(_jq -r ".detectors.\"$m\".probes | length")
  i=0
  while [ "$i" -lt "$N" ]; do
    kind=$(_jq -r ".detectors.\"$m\".probes[$i].kind")
    arg=$(_jq  -r ".detectors.\"$m\".probes[$i].pkg // .detectors.\"$m\".probes[$i].path // empty")
    # Some probe kinds (cmd-no-pkg-owner, symlink-into-roots) need a list of
    # tarball roots so they don't double-classify a tarball install as 'binary'.
    # We pass them via env var DETECT_PROBE_ROOTS as colon-separated paths.
    roots_csv=$(_jq -r ".detectors.\"$m\".probes[$i].roots // [] | join(\":\")")
    if [ -n "$roots_csv" ]; then
      export DETECT_PROBE_ROOTS="$roots_csv"
    else
      unset DETECT_PROBE_ROOTS
    fi
    if line=$(detect_run_probe "$m" "$kind" "$arg"); then
      printf '%s\n' "$line" >> "$DETECT_HITS_TSV"
      detail=$(printf '%s' "$line" | awk -F'\t' '{print $3}')
      log_ok "  detected '$m' via $kind: $detail"
      hit_count=$((hit_count+1))
    fi
    i=$((i+1))
  done
  if [ "$hit_count" -gt 0 ]; then
    DETECTED_METHODS+=("$m")
  else
    if [ "$SKIP_DETECT" -eq 1 ] && [ "${#ONLY_IDS[@]}" -gt 0 ]; then
      log_warn "  '$m' not detected, but --skip-detect is set with --only -> queued for removal anyway"
      DETECTED_METHODS+=("$m")
    else
      log_info "  '$m' not detected on this system"
    fi
  fi
done

joined="$(IFS=,; printf '%s' "${DETECTED_METHODS[*]:-}")"
log_info "Detect summary: ${#DETECTED_METHODS[@]}/${#ALL_METHODS[@]} method(s) present -> [${joined}]"

if [ "$VERB" = "detect" ]; then
  # Write a small detect-only manifest and exit.
  manifest="$RUN_DIR/manifest.json"
  {
    printf '{"script":"67-vscode-cleanup-linux","os":"Linux","mode":"detect-only","scope":"%s","timestamp":"%s","detected":[' \
      "$RESOLVED_SCOPE" "$TS"
    first=1
    for m in "${DETECTED_METHODS[@]:-}"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s"' "$m"
    done
    printf ']}\n'
  } > "$manifest" 2>/dev/null || log_file_error "$manifest" "manifest write failed"
  log_info "Manifest written: $manifest"
  exit 0
fi

# --------------------------------------------------------------------- subverb: resolve
# Print a single classification line + structured exit code so callers (CI,
# other scripts, the toolkit's `vscode-resolve-linux` shortcut) can branch
# without having to parse the full detect output.
if [ "$VERB" = "resolve" ]; then
  # Specificity order: most-specific install method wins when several match.
  # apt > deb (apt implies an MS source file; deb is the bare dpkg case)
  # snap is independent
  # tarball > binary (a tarball root present implies tarball; a bare shim is binary)
  # user-config is auxiliary -- never the primary classification
  resolve_pick=""
  _has() { local x="$1" y; for y in "${DETECTED_METHODS[@]:-}"; do [ "$x" = "$y" ] && return 0; done; return 1; }
  if   _has apt;     then resolve_pick="apt"
  elif _has snap;    then resolve_pick="snap"
  elif _has deb;     then resolve_pick="deb"
  elif _has tarball; then resolve_pick="tarball"
  elif _has binary;  then resolve_pick="binary"
  elif _has user-config; then resolve_pick="user-config"
  fi

  # Edition: union of editions seen across all hits (parsed from probe detail).
  edition_seen=""
  if [ -s "$DETECT_HITS_TSV" ]; then
    if   grep -q 'code-insiders' "$DETECT_HITS_TSV" && grep -q -E '(pkg=code\b|cmd=code\b|path=.*Code[^-])' "$DETECT_HITS_TSV"; then
      edition_seen="both"
    elif grep -q 'code-insiders' "$DETECT_HITS_TSV"; then
      edition_seen="insiders"
    else
      edition_seen="stable"
    fi
  fi

  # First detail line for the picked method (for human context).
  resolve_detail=""
  if [ -n "$resolve_pick" ] && [ -s "$DETECT_HITS_TSV" ]; then
    resolve_detail=$(awk -F'\t' -v m="$resolve_pick" '$1==m {print $3; exit}' "$DETECT_HITS_TSV")
  fi

  # Manifest mirrors the 'detect' verb shape but adds a 'resolved' field.
  manifest="$RUN_DIR/manifest.json"
  {
    printf '{"script":"67-vscode-cleanup-linux","os":"Linux","mode":"resolve","scope":"%s","timestamp":"%s","resolved":"%s","edition":"%s","detected":[' \
      "$RESOLVED_SCOPE" "$TS" "${resolve_pick:-none}" "${edition_seen:-unknown}"
    first=1
    for m in "${DETECTED_METHODS[@]:-}"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s"' "$m"
    done
    printf ']}\n'
  } > "$manifest" 2>/dev/null || log_file_error "$manifest" "manifest write failed"

  # Single-line stdout output so callers can `read` it directly.
  if [ -z "$resolve_pick" ]; then
    printf "method=none  edition=unknown  detail='no VS Code install detected'\n"
    log_info "Manifest written: $manifest"
    exit 2
  fi

  printf "method=%s  edition=%s  detail='%s'\n" \
    "$resolve_pick" "${edition_seen:-unknown}" "${resolve_detail:-(no detail)}"
  log_info "Manifest written: $manifest"

  # Count primary methods (excluding user-config which is auxiliary) to decide
  # between exit 0 (single) and exit 1 (multiple coexisting installs).
  primary_count=0
  for m in "${DETECTED_METHODS[@]:-}"; do
    case "$m" in user-config) ;; *) primary_count=$((primary_count+1)) ;; esac
  done
  if [ "$primary_count" -gt 1 ]; then
    log_warn "Multiple primary install methods present (${primary_count}): [${joined}]. Picked '$resolve_pick' as the most specific. Exit code 1."
    exit 1
  fi
  exit 0
fi

if [ "${#DETECTED_METHODS[@]}" -eq 0 ]; then
  log_ok "No VS Code install methods detected on this machine. Nothing to do."
  exit 0
fi

# --------------------------------------------------------------------- apply phase
_run_step() {
  local method="$1" idx="$2"
  local kind path pkgs req
  kind=$(_jq -r ".actions.\"$method\".steps[$idx].kind")
  path=$(_jq -r ".actions.\"$method\".steps[$idx].path // empty")
  pkgs=$(_jq -r ".actions.\"$method\".steps[$idx].pkgs // [] | join(\",\")")
  req=$(_jq  -r ".actions.\"$method\".steps[$idx].requiresSudo // false")

  # Method-level requiresSudo applied as default if step doesn't override.
  if [ "$req" = "false" ]; then
    local mreq; mreq=$(_jq -r ".actions.\"$method\".requiresSudo // false")
    [ "$mreq" = "true" ] && req="true"
  fi

  # Skip system-scope steps when user scope was requested.
  if [ "$RESOLVED_SCOPE" = "user" ] && [ "$req" = "true" ]; then
    _emit_row "skipped" "$method" "$kind" "${path:-${pkgs:-(n/a)}}" "system step skipped (scope=user)"
    log_info "  [$method] skipped $kind (scope=user, step needs sudo): ${path:-$pkgs}"
    return 0
  fi

  case "$kind" in
    rm-file)     action_rm_file     "$method" "$path" "$req" ;;
    rm-shim)    action_rm_shim     "$method" "$path" "$req" ;;
    rm-dir)      action_rm_dir      "$method" "$path" "$req" ;;
    apt-purge)   action_apt_purge   "$method" "$pkgs" ;;
    apt-update)  action_apt_update  "$method" "$(_jq -r ".actions.\"$method\".steps[$idx].note // \"\"")" ;;
    snap-remove) action_snap_remove "$method" "$pkgs" ;;
    dpkg-remove) action_dpkg_remove "$method" "$pkgs" ;;
    *)
      _emit_row "skipped" "$method" "$kind" "(unknown)" "unknown action kind"
      log_warn "  [$method] unknown action kind '$kind' -- skipping (config.json bug?)"
      ;;
  esac
}

# Run every queued step for every detected method. Honors current $DRY_RUN.
_run_all_steps() {
  for m in "${DETECTED_METHODS[@]}"; do
    N=$(_jq -r ".actions.\"$m\".steps | length")
    log_info "[$m] running $N step(s)"
    i=0
    while [ "$i" -lt "$N" ]; do
      _run_step "$m" "$i"
      i=$((i+1))
    done
  done
}

# In apply mode, do a forced dry-run pass first to build the plan, render
# tree + table, then prompt. If approved (or --yes), reset rows and re-run.
if [ "$DRY_RUN" -eq 1 ]; then
  log_info "===== apply phase (dry-run, scope=$RESOLVED_SCOPE) ====="
  _run_all_steps
else
  log_info "===== plan phase (scope=$RESOLVED_SCOPE) -- nothing will be removed yet ====="
  DRY_RUN=1; export DRY_RUN
  _run_all_steps

  # Extract every 'would' row from the dry-run rows file into the plan TSV
  # using the schema confirm_render_plan expects: bucket\tkind\ttarget\tdetail.
  : > "$PLAN_TSV"
  while IFS=$'\t' read -r status method kind target detail; do
    [ "$status" = "would" ] || continue
    confirm_plan_add "$PLAN_TSV" "$method" "$kind" "$target" "$detail"
  done < "$ROWS_TSV"

  confirm_render_plan "$PLAN_TSV" "Planned VS Code cleanup actions"

  if ! confirm_prompt "$PLAN_TSV" "$ASSUME_YES"; then
    log_warn "Apply phase aborted. The plan above was NOT executed."
    log_info "Plan file kept for inspection: $PLAN_TSV"
    # Manifest still gets written below so we have an audit trail of what
    # WOULD have happened. Mark mode as 'aborted' for the manifest header.
    APPLY_ABORTED=1
  else
    APPLY_ABORTED=0
    # Reset rows + re-run for real.
    log_info "===== apply phase (apply, scope=$RESOLVED_SCOPE) ====="
    : > "$ROWS_TSV"
    DRY_RUN=0; export DRY_RUN
    _run_all_steps
  fi
fi
APPLY_ABORTED="${APPLY_ABORTED:-0}"

# --------------------------------------------------------------------- summary
REMOVED=0; WOULD=0; MISSING=0; FAILED=0; SKIPPED=0
while IFS=$'\t' read -r s _; do
  case "$s" in
    removed) REMOVED=$((REMOVED+1)) ;;
    would)   WOULD=$((WOULD+1)) ;;
    missing) MISSING=$((MISSING+1)) ;;
    failed)  FAILED=$((FAILED+1)) ;;
    skipped) SKIPPED=$((SKIPPED+1)) ;;
  esac
done < "$ROWS_TSV"

printf '\n  ===== summary (%s, scope=%s) =====\n' "$(_mode_label)" "$RESOLVED_SCOPE"
printf '  %-9s  %-12s  %-12s  %s\n' "STATUS" "METHOD" "KIND" "TARGET"
printf '  %s\n' "$(printf '%.0s-' {1..95})"
while IFS=$'\t' read -r s id kind target detail; do
  printf '  %-9s  %-12s  %-12s  %s\n' "$s" "$id" "$kind" "$target"
done < "$ROWS_TSV"
printf '  %s\n' "$(printf '%.0s-' {1..95})"
printf '  TOTALS: removed=%d  would-remove=%d  missing=%d  skipped=%d  failed=%d\n\n' \
  "$REMOVED" "$WOULD" "$MISSING" "$SKIPPED" "$FAILED"

# --------------------------------------------------------------------- verify
# Independent post-cleanup verification. Re-probes every removed/would target
# (file, dir, shim, package, snap) and emits a pass/fail report. This is a
# second-source check -- if a deletion succeeded but the OS left an entry
# behind (postrm script, wrong path, sudo missing on a rm-shim) we surface
# it here as FAIL instead of declaring a successful run.
_mode_for_verify=""
if   [ "$APPLY_ABORTED" = "1" ]; then _mode_for_verify="aborted"
elif [ "$DRY_RUN" -eq 1 ];        then _mode_for_verify="dry-run"
else                                   _mode_for_verify="apply"
fi
VERIFY_PASSES=0; VERIFY_FAILS=0; VERIFY_SKIPS=0
if [ "$APPLY_ABORTED" = "1" ]; then
  log_info "===== verify phase skipped (run aborted at confirmation prompt) ====="
else
  log_info "===== verify phase (re-probing every targeted item) ====="
  verify_run    "$ROWS_TSV" "$VERIFY_TSV" "$_mode_for_verify"
  verify_render "$VERIFY_TSV" "vscode-cleanup-linux verification report"
fi

# --------------------------------------------------------------------- manifest
_mode_label() {
  if [ "$APPLY_ABORTED" = "1" ]; then echo "aborted"
  elif [ "$DRY_RUN" -eq 1 ]; then echo "dry-run"
  else echo "apply"; fi
}
manifest="$RUN_DIR/manifest.json"
{
  printf '{"script":"67-vscode-cleanup-linux","os":"Linux","mode":"%s","scope":"%s","timestamp":"%s","detected":[' \
    "$(_mode_label)" "$RESOLVED_SCOPE" "$TS"
  first=1
  for m in "${DETECTED_METHODS[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s"' "$m"
  done
  printf '],"totals":{"removed":%d,"would":%d,"missing":%d,"skipped":%d,"failed":%d},"rows":[' \
    "$REMOVED" "$WOULD" "$MISSING" "$SKIPPED" "$FAILED"
  first=1
  while IFS=$'\t' read -r s id kind target detail; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    t_esc=$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g')
    d_esc=$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"status":"%s","method":"%s","kind":"%s","target":"%s","detail":"%s"}' \
      "$s" "$id" "$kind" "$t_esc" "$d_esc"
  done < "$ROWS_TSV"
  printf '],"verification":{"totals":{"pass":%d,"fail":%d,"skipped":%d},"rows":[' \
    "${VERIFY_PASSES:-0}" "${VERIFY_FAILS:-0}" "${VERIFY_SKIPS:-0}"
  first=1
  if [ -f "$VERIFY_TSV" ]; then
    while IFS=$'\t' read -r vr vb vk vt vd; do
      [ -z "$vr" ] && continue
      [ "$first" -eq 1 ] || printf ','
      first=0
      vt_esc=$(printf '%s' "$vt" | sed 's/\\/\\\\/g; s/"/\\"/g')
      vd_esc=$(printf '%s' "$vd" | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf '{"result":"%s","method":"%s","kind":"%s","target":"%s","detail":"%s"}' \
        "$vr" "$vb" "$vk" "$vt_esc" "$vd_esc"
    done < "$VERIFY_TSV"
  fi
  printf ']}}\n'
} > "$manifest" 2>/dev/null \
  || log_file_error "$manifest" "manifest write failed"

log_info "Manifest written: $manifest"
if [ "$APPLY_ABORTED" = "1" ]; then
  log_warn "Run aborted by operator at the confirmation prompt. No changes were made."
  exit 2
fi
if [ "$FAILED" -gt 0 ]; then
  log_warn "Completed with $FAILED failure(s). See manifest for details."
  exit 1
fi
# Verification failures take priority over a clean apply phase: even if the
# remove helpers all returned 0, an independent re-probe found targets still
# present, so the cleanup is NOT actually complete.
if [ "${VERIFY_FAILS:-0}" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  log_warn "Apply finished, but post-cleanup verification reported ${VERIFY_FAILS} target(s) still present. See verify report above and verify.tsv: $VERIFY_TSV"
  exit 3
fi
log_ok "Done."
exit 0