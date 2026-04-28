#!/usr/bin/env bash
# 66-vscode-menu-cleanup-mac
#
# macOS-only surgical cleanup of every "registry-equivalent" VS Code
# launch surface:
#
#   * Finder Quick Actions / Services workflows
#   * LaunchAgents / LaunchDaemons that reference VS Code
#   * Login Items (open-at-login) pointing at Code.app / Code - Insiders.app
#   * 'code' / 'code-insiders' shell shims in PATH
#   * vscode:// / vscode-insiders:// LaunchServices URL handlers
#
# Apply by default; pass --dry-run for a preview. Path allow-list lives in
# config.json -- nothing outside that file is ever touched. Manifest is
# written to .logs/66/<TS>/manifest.json mirroring script 65's schema.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="66"

. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"
. "$ROOT/_shared/confirm.sh"
. "$ROOT/_shared/verify.sh"
. "$SCRIPT_DIR/helpers/match.sh"
. "$SCRIPT_DIR/helpers/sweep.sh"

CONFIG="$SCRIPT_DIR/config.json"
LOG_MSGS="$SCRIPT_DIR/log-messages.json"
LOGS_ROOT="${LOGS_OVERRIDE:-$ROOT/.logs/66}"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOGS_ROOT/$TS"
ROWS_TSV="$RUN_DIR/rows.tsv"
PLAN_TSV="$RUN_DIR/plan.tsv"
VERIFY_TSV="$RUN_DIR/verify.tsv"
export ROWS_TSV

# --------------------------------------------------------------------- args
VERB=""; DRY_RUN=0; SCOPE=""; ONLY_CSV=""; EDITION_FILTER=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    run|list|help|--help|-h) [ -z "$VERB" ] && VERB="$1"; shift ;;
    --dry-run|-n)            DRY_RUN=1; shift ;;
    --scope)                 SCOPE="$2"; shift 2 ;;
    --scope=*)               SCOPE="${1#--scope=}"; shift ;;
    --system)                SCOPE="system"; shift ;;
    --user)                  SCOPE="user"; shift ;;
    --only)                  ONLY_CSV="$2"; shift 2 ;;
    --only=*)                ONLY_CSV="${1#--only=}"; shift ;;
    --edition)               EDITION_FILTER="$2"; shift 2 ;;
    --edition=*)             EDITION_FILTER="${1#--edition=}"; shift ;;
    --yes|-y)                ASSUME_YES=1; shift ;;
    --no-color)              export NO_COLOR=1; shift ;;
    *) log_warn "Unknown flag: $1"; shift ;;
  esac
done
[ -z "$VERB" ] && VERB="run"
export DRY_RUN

# --------------------------------------------------------------------- bootstrap
_jq() {
  if command -v jq >/dev/null 2>&1; then jq -r "$@" "$CONFIG"
  else
    # Last-ditch fallback: python (preinstalled on macOS).
    python3 -c "
import json,sys
cfg=json.load(open('$CONFIG'))
def get(d,p):
  for k in p.split('.'):
    if k.isdigit(): d=d[int(k)]
    else: d=d.get(k) if isinstance(d,dict) else None
    if d is None: return ''
  return d
print(get(cfg,'''$1''') if '$1'.startswith('.') is False else json.dumps(cfg))
"
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

  vscode-menu-cleanup-mac (script 66) -- surgical macOS cleanup

  USAGE
    scripts-linux/run.sh 66 [run|list|help] [flags]

  FLAGS
    --dry-run, -n         Preview every targeted path/label/handler. No deletions.
    --yes, -y             Skip the plan-then-confirm prompt (for CI / scripted use).
                          In apply mode the script first builds a plan, prints it
                          as a tree + table, and asks for confirmation. Pass --yes
                          to bypass the prompt. --dry-run never prompts.
    --scope user|system   user = ~/Library only (no sudo).
                          system = + /Library, /usr/local, /opt/homebrew (needs sudo).
                          Default: 'auto' = system if running as root, else user.
    --system, --user      Shortcuts for --scope system / --scope user.
    --only A,B,C          Limit to comma-separated category ids (see `list`).
    --edition stable|insiders
                          Only consider one VS Code edition.
    --no-color            Disable ANSI colour output.

  EXAMPLES
    scripts-linux/run.sh 66 --dry-run
    scripts-linux/run.sh 66 --only services,loginitems
    sudo scripts-linux/run.sh 66 --system
    scripts-linux/run.sh 66 list

EOF
  exit 0
fi

# --------------------------------------------------------------------- subverb: list
if [ "$VERB" = "list" ]; then
  printf '\n  vscode-menu-cleanup-mac :: defined categories\n'
  printf '  %s\n' "$(printf '=%.0s' {1..70})"
  for sc in user system; do
    printf '  -- scope: %s\n' "$sc"
    while IFS=$'\t' read -r id label; do
      [ -z "$id" ] && continue
      printf '    %-22s %s\n' "$id" "$label"
    done < <(_jq -r ".targets.${sc} // [] | .[] | [.id,.label] | @tsv")
  done
  printf '\n'
  exit 0
fi

# --------------------------------------------------------------------- run guards
ENABLED="$(_jq -r '.enabled')"
if [ "$ENABLED" != "true" ]; then
  log_warn "Script disabled in config.json (set 'enabled': true to run). Aborting."
  exit 0
fi

OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
if [ "$OS_NAME" != "Darwin" ]; then
  log_err "This script targets macOS only. Detected OS: $OS_NAME. Aborting (no changes made)."
  exit 2
fi

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
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

write_install_paths \
  --tool   "VS Code menu cleanup (macOS, scope=$RESOLVED_SCOPE)" \
  --source "$SCRIPT_DIR/config.json (path allow-list of Quick Actions/LaunchAgents/Login Items/URL handlers)" \
  --temp   "$ROOT/.logs/66/<TS>" \
  --target "Removed: Services workflows + LaunchAgents/Daemons + Login Items + 'code'/'code-insiders' shims + vscode:// URL handlers"
log_info "===== vscode-menu-cleanup-mac (script 66) ====="
log_info "Resolved scope: requested='$REQUESTED_SCOPE', resolved='$RESOLVED_SCOPE' (root=$IS_ROOT)."
if [ "$DRY_RUN" -eq 1 ]; then
  log_info "DRY-RUN mode: no changes will be made."
else
  log_info "APPLY mode: changes will be made. Pass --dry-run to preview only."
fi

# --------------------------------------------------------------------- editions
EDITION_NAMES=()
while IFS= read -r ed; do
  [ -z "$ed" ] && continue
  if [ -n "$EDITION_FILTER" ] && [ "$ed" != "$EDITION_FILTER" ]; then continue; fi
  EDITION_NAMES+=("$ed")
done < <(_jq -r '.editions | keys[]')

if [ "${#EDITION_NAMES[@]}" -eq 0 ]; then
  log_err "No editions matched filter '--edition $EDITION_FILTER'. Aborting before any deletions."
  exit 2
fi

APP_NAMES=(); BUNDLE_IDS=(); SHIM_NAMES=(); URL_SCHEMES=()
for ed in "${EDITION_NAMES[@]}"; do
  APP_NAMES+=("$(_jq -r ".editions.${ed}.appName")")
  BUNDLE_IDS+=("$(_jq -r ".editions.${ed}.bundleId")")
  while IFS= read -r s; do [ -n "$s" ] && SHIM_NAMES+=("$s"); done < <(_jq -r ".editions.${ed}.shimNames[]?")
  while IFS= read -r u; do [ -n "$u" ] && URL_SCHEMES+=("$u"); done < <(_jq -r ".editions.${ed}.urlSchemes[]?")
done

# Filters from --only.
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

# --------------------------------------------------------------------- run
REMOVED=0; WOULD=0; MISSING=0; FAILED=0; SKIPPED=0

_count_rows() {
  local s
  while IFS=$'\t' read -r s _; do
    case "$s" in
      removed) REMOVED=$((REMOVED+1)) ;;
      would)   WOULD=$((WOULD+1)) ;;
      missing) MISSING=$((MISSING+1)) ;;
      failed)  FAILED=$((FAILED+1)) ;;
      skipped) SKIPPED=$((SKIPPED+1)) ;;
    esac
  done < "$ROWS_TSV"
}

_process_category() {
  local sc="$1"; local idx="$2"
  local id label mode
  id="$(_jq    -r ".targets.${sc}[${idx}].id")"
  label="$(_jq -r ".targets.${sc}[${idx}].label")"
  mode="$(_jq  -r ".targets.${sc}[${idx}].mode")"

  if ! _in_only "$id"; then
    log_info "[$id] skipped (does not match --only filter)"
    _emit_row "skipped" "$id" "filter" "" "not in --only"
    return 0
  fi
  local req_sudo
  req_sudo="$(_jq -r ".targets.${sc}[${idx}].requiresSudo // false")"
  if [ "$req_sudo" = "true" ] && [ "$IS_ROOT" -ne 1 ]; then
    log_warn "[$id] requires sudo for $sc-scope cleanup (re-run with sudo, or use --scope user). Skipping."
    _emit_row "skipped" "$id" "sudo" "" "requires root"
    return 0
  fi

  log_info "[$id] $label -- scanning"

  case "$mode" in
    glob)
      local root pat
      root="$(_jq -r ".targets.${sc}[${idx}].root")"
      root="$(eval printf '%s' "\"$root\"")"
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        sweep_glob_under "$id" "$root" "$pat"
      done < <(_jq -r ".targets.${sc}[${idx}].patterns[]?")
      ;;
    launchctl)
      local root domain
      root="$(_jq -r ".targets.${sc}[${idx}].root")"
      root="$(eval printf '%s' "\"$root\"")"
      domain="$(_jq -r ".targets.${sc}[${idx}].domain // \"gui\"")"
      local needles=()
      while IFS= read -r n; do [ -n "$n" ] && needles+=("$n"); done \
        < <(_jq -r ".targets.${sc}[${idx}].matchProgramSubstrings[]?")
      sweep_launchctl "$id" "$root" "$domain" "${needles[@]}"
      ;;
    loginitem)
      sweep_loginitem "$id" "${APP_NAMES[@]}"
      ;;
    shim)
      local roots=()
      while IFS= read -r r; do
        [ -z "$r" ] && continue
        r="$(eval printf '%s' "\"$r\"")"
        roots+=("$r")
      done < <(_jq -r ".targets.${sc}[${idx}].roots[]?")
      local r s
      for r in "${roots[@]}"; do
        for s in "${SHIM_NAMES[@]}"; do
          sweep_shim "$id" "$r" "$s"
        done
      done
      ;;
    lsregister)
      local schemes_csv bundles_csv
      schemes_csv="$(IFS=,; printf '%s' "${URL_SCHEMES[*]}")"
      bundles_csv="$(IFS=,; printf '%s' "${BUNDLE_IDS[*]}")"
      sweep_lsregister "$id" "schemes:$schemes_csv" "bundles:$bundles_csv"
      ;;
    *)
      log_warn "[$id] unknown mode '$mode' -- skipping (config.json bug?)"
      _emit_row "skipped" "$id" "mode" "" "unknown mode '$mode'"
      ;;
  esac
}

# Iterate scopes. 'system' only runs when resolved scope == 'system'.
# Wrapped in a function so we can call it twice (plan pass + apply pass).
_run_all_categories() {
  local sc N i
  for sc in user system; do
    if [ "$sc" = "system" ] && [ "$RESOLVED_SCOPE" != "system" ]; then
      log_info "[scope:system] skipped (resolved scope='$RESOLVED_SCOPE'; pass --scope system or run as root to include /Library + /usr/local + /opt/homebrew)"
      continue
    fi
    N="$(_jq -r ".targets.${sc} | length")"
    i=0
    while [ "$i" -lt "$N" ]; do
      _process_category "$sc" "$i"
      i=$((i+1))
    done
  done
}

# In apply mode: do a forced dry-run pass first to build the plan, render
# the tree + table, then prompt. If approved (or --yes), reset rows and
# re-run for real. In dry-run mode: just one pass.
APPLY_ABORTED=0
if [ "$DRY_RUN" -eq 1 ]; then
  _run_all_categories
else
  log_info "===== plan phase (scope=$RESOLVED_SCOPE) -- nothing will be removed yet ====="
  DRY_RUN=1; export DRY_RUN
  _run_all_categories

  : > "$PLAN_TSV"
  while IFS=$'\t' read -r status id kind target detail; do
    [ "$status" = "would" ] || continue
    confirm_plan_add "$PLAN_TSV" "$id" "$kind" "$target" "$detail"
  done < "$ROWS_TSV"

  confirm_render_plan "$PLAN_TSV" "Planned macOS VS Code menu cleanup"

  if ! confirm_prompt "$PLAN_TSV" "$ASSUME_YES"; then
    log_warn "Apply phase aborted. The plan above was NOT executed."
    log_info "Plan file kept for inspection: $PLAN_TSV"
    APPLY_ABORTED=1
  else
    log_info "===== apply phase (apply, scope=$RESOLVED_SCOPE) ====="
    : > "$ROWS_TSV"
    DRY_RUN=0; export DRY_RUN
    _run_all_categories
  fi
fi

_count_rows

# --------------------------------------------------------------------- summary
_mode_label() {
  if [ "$APPLY_ABORTED" = "1" ]; then echo "aborted"
  elif [ "$DRY_RUN" -eq 1 ]; then echo "dry-run"
  else echo "apply"; fi
}
printf '\n  ===== summary (%s, scope=%s) =====\n' "$(_mode_label)" "$RESOLVED_SCOPE"
printf '  %-9s  %-22s  %-12s  %s\n' "STATUS" "CATEGORY" "KIND" "TARGET"
printf '  %s\n' "$(printf '%.0s-' {1..95})"
while IFS=$'\t' read -r s id kind target detail; do
  printf '  %-9s  %-22s  %-12s  %s\n' "$s" "$id" "$kind" "$target"
done < "$ROWS_TSV"
printf '  %s\n' "$(printf '%.0s-' {1..95})"
printf '  TOTALS: removed=%d  would-remove=%d  missing=%d  skipped=%d  failed=%d\n\n' \
  "$REMOVED" "$WOULD" "$MISSING" "$SKIPPED" "$FAILED"

# --------------------------------------------------------------------- verify
# Independent post-cleanup verification: re-probes every removed/would target
# (workflow files, launchctl plists, shims, login items, LaunchServices URL
# handlers) and emits a pass/fail report. This catches the cases where a
# helper returned 0 but the OS still has the entry registered (e.g. macOS
# caches a Login Item until logout, or lsregister -u failed silently).
VERIFY_PASSES=0; VERIFY_FAILS=0; VERIFY_SKIPS=0
_mode_for_verify=""
if   [ "$APPLY_ABORTED" = "1" ]; then _mode_for_verify="aborted"
elif [ "$DRY_RUN" -eq 1 ];        then _mode_for_verify="dry-run"
else                                   _mode_for_verify="apply"
fi
if [ "$APPLY_ABORTED" = "1" ]; then
  log_info "===== verify phase skipped (run aborted at confirmation prompt) ====="
else
  log_info "===== verify phase (re-probing every targeted item) ====="
  verify_run    "$ROWS_TSV" "$VERIFY_TSV" "$_mode_for_verify"
  verify_render "$VERIFY_TSV" "vscode-menu-cleanup-mac verification report"
fi

# --------------------------------------------------------------------- manifest
manifest="$RUN_DIR/manifest.json"
{
  printf '{"script":"66-vscode-menu-cleanup-mac","os":"macOS","mode":"%s","scope":"%s","timestamp":"%s","totals":{"removed":%d,"would":%d,"missing":%d,"skipped":%d,"failed":%d},"rows":[' \
    "$(_mode_label)" "$RESOLVED_SCOPE" "$TS" \
    "$REMOVED" "$WOULD" "$MISSING" "$SKIPPED" "$FAILED"
  first=1
  while IFS=$'\t' read -r s id kind target detail; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    t_esc=$(printf '%s' "$target"  | sed 's/\\/\\\\/g; s/"/\\"/g')
    d_esc=$(printf '%s' "$detail"  | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"status":"%s","category":"%s","kind":"%s","target":"%s","detail":"%s"}' \
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
      printf '{"result":"%s","category":"%s","kind":"%s","target":"%s","detail":"%s"}' \
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
# Verification failures take priority over a clean apply phase: even if every
# helper returned 0, an independent re-probe found targets still present, so
# the cleanup is NOT actually complete.
if [ "${VERIFY_FAILS:-0}" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  log_warn "Apply finished, but post-cleanup verification reported ${VERIFY_FAILS} target(s) still present. See verify report above and verify.tsv: $VERIFY_TSV"
  exit 3
fi
log_ok "Done."
exit 0