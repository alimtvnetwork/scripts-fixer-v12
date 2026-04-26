#!/usr/bin/env bash
# 68-user-mgmt/orchestrate.sh -- THIN root orchestrator for user/group setup.
#
# Purpose: parse a unified JSON spec OR a small set of flags, then call the
# four existing leaf scripts in the CORRECT ORDER with a SHARED summary file
# so all four phases produce one consistent roll-up. This script intentionally
# contains NO business logic -- every create/modify/permission/SSH-key
# decision still lives in the leaves. If you need to change behavior, change
# the leaf, not this file.
#
# Order of operations (fixed -- groups must exist before users that reference
# them via --primary-group or --groups):
#   1. groups from CLI    -> add-group.sh        (one call per --group flag)
#   2. groups from JSON   -> add-group-from-json.sh
#   3. users  from CLI    -> add-user.sh         (one call per --user flag)
#   4. users  from JSON   -> add-user-from-json.sh
#
# Each phase is OPTIONAL. Missing inputs -> phase skipped (logged), not an error.
# Any phase returning non-zero -> orchestrator exits non-zero AFTER all phases
# have run, so a single bad record never aborts the rest of the batch.
#
# ---- Input shapes ----------------------------------------------------------
#
# (A) Unified JSON spec (recommended):
#       ./orchestrate.sh --spec /path/to/spec.json [--dry-run]
#     where spec.json is:
#       {
#         "groups": [ { "name": "devs", "gid": 2000 }, ... ],
#         "users":  [ { "name": "alice", "password": "...", "groups": ["devs"] }, ... ]
#       }
#     Either array may be omitted. If "groups" is present it is split into
#     a temporary file and handed to add-group-from-json.sh; same for users.
#
# (B) Separate JSON files (for users who already maintain them):
#       ./orchestrate.sh --groups-json g.json --users-json u.json [--dry-run]
#
# (C) Inline flags (no JSON at all):
#       ./orchestrate.sh \
#           --group "devs:2000" \
#           --group "ops:--system" \
#           --user  "alice:--password,Hunter2!,--sudo,--groups,devs" \
#           --user  "bob:--uid,1500,--shell,/bin/zsh"
#     Each --group / --user value is "<name>:<comma-separated-flags>".
#     Flags with embedded commas are NOT supported in inline form -- use a
#     JSON spec for that case.
#
# (D) Mix: any combination of A + B + C may be passed in one invocation.
#     Order is still enforced: ALL groups (CLI + JSON) before ANY user.
#
# ---- Examples --------------------------------------------------------------
#   sudo bash orchestrate.sh --spec ./examples/full-bootstrap.json --dry-run
#   sudo bash orchestrate.sh --group devs:2000 --user alice:--password,x,--sudo
#   sudo bash orchestrate.sh --groups-json g.json --users-json u.json

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

orch_usage() {
  cat <<'EOF'
Usage: orchestrate.sh [options]

JSON inputs (any combination, all optional):
  --spec FILE              Unified spec: { "groups": [...], "users": [...] }
  --groups-json FILE       JSON file accepted by add-group-from-json.sh
  --users-json  FILE       JSON file accepted by add-user-from-json.sh

Inline flag inputs (repeatable, all optional):
  --group "<name>:<flags>" One group; <flags> = comma-separated leaf-script flags
                           Example: --group "ops:--gid,2000,--system"
  --user  "<name>:<flags>" One user;  <flags> = comma-separated leaf-script flags
                           Example: --user "alice:--password,Hunter2!,--sudo"

Misc:
  --dry-run                Forwarded to every leaf; nothing changes on disk
  -h | --help              This help

Order is fixed: groups (CLI then JSON) before users (CLI then JSON).
No business logic lives here -- all real work happens in the leaf scripts.
EOF
}

# ---- arg parse -------------------------------------------------------------
ORCH_SPEC=""
ORCH_GROUPS_JSON=""
ORCH_USERS_JSON=""
ORCH_DRY_RUN="${UM_DRY_RUN:-0}"
ORCH_GROUPS_CLI=()   # entries like "name:flag1,flag2,..."
ORCH_USERS_CLI=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)       orch_usage; exit 0 ;;
    --spec)          ORCH_SPEC="${2:-}";         shift 2 ;;
    --groups-json)   ORCH_GROUPS_JSON="${2:-}";  shift 2 ;;
    --users-json)    ORCH_USERS_JSON="${2:-}";   shift 2 ;;
    --group)         ORCH_GROUPS_CLI+=("${2:-}"); shift 2 ;;
    --user)          ORCH_USERS_CLI+=("${2:-}");  shift 2 ;;
    --dry-run)       ORCH_DRY_RUN=1;             shift ;;
    --) shift; break ;;
    -*)
      log_err "unknown option: '$1' (failure: see --help for the full list)"
      exit 64 ;;
    *)
      log_err "unexpected positional: '$1' (failure: orchestrate.sh has no positionals)"
      exit 64 ;;
  esac
done

# Need at least one source of work.
if [ -z "$ORCH_SPEC" ] && [ -z "$ORCH_GROUPS_JSON" ] && [ -z "$ORCH_USERS_JSON" ] \
   && [ "${#ORCH_GROUPS_CLI[@]}" -eq 0 ] && [ "${#ORCH_USERS_CLI[@]}" -eq 0 ]; then
  log_err "no inputs supplied (failure: pass --spec, --groups-json, --users-json, --group, or --user)"
  orch_usage
  exit 64
fi

# Validate file inputs early with EXACT path + reason (CODE RED rule).
for _f_pair in "spec:$ORCH_SPEC" "groups-json:$ORCH_GROUPS_JSON" "users-json:$ORCH_USERS_JSON"; do
  _label="${_f_pair%%:*}"; _path="${_f_pair#*:}"
  if [ -n "$_path" ] && [ ! -f "$_path" ]; then
    log_file_error "$_path" "$_label JSON not found"
    exit 2
  fi
done

# jq is required only when JSON inputs are present.
_need_jq=0
[ -n "$ORCH_SPEC" ]        && _need_jq=1
[ -n "$ORCH_GROUPS_JSON" ] && _need_jq=1
[ -n "$ORCH_USERS_JSON" ]  && _need_jq=1
if [ "$_need_jq" = "1" ] && ! command -v jq >/dev/null 2>&1; then
  log_err "$(um_msg missingTool "jq")"
  exit 127
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$ORCH_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

# ---- shared logging context ------------------------------------------------
# All four leaves append to the same UM_SUMMARY_FILE so we get ONE roll-up
# instead of four. We export it BEFORE invoking any leaf and print it at the
# end ourselves -- the leaves' own um_summary_print calls become harmless
# extra prints because each phase will only show its own rows up to that
# point. To keep output clean we suppress per-phase printing by giving each
# phase its own short-lived file and merging them at the end.
ORCH_RUN_ID="$$-$(date +%s 2>/dev/null || echo 0)"
ORCH_SUMMARY_MERGED=$(mktemp -t 68-orch-summary.XXXXXX)
trap 'rm -f "$ORCH_SUMMARY_MERGED" "${ORCH_SPLIT_GROUPS:-}" "${ORCH_SPLIT_USERS:-}" 2>/dev/null || true' EXIT

# Helper: run a leaf with a private summary file and merge it into the master.
orch_run_leaf() {
  # $1 = phase label (for the section header)
  # $2.. = command + args
  local _label="$1"; shift
  local _phase_summary
  _phase_summary=$(mktemp -t "68-orch-phase.XXXXXX")
  log_info "================ phase: $_label ================"
  if UM_SUMMARY_FILE="$_phase_summary" "$@"; then
    :
  else
    ORCH_RC=1
  fi
  if [ -s "$_phase_summary" ]; then
    cat "$_phase_summary" >> "$ORCH_SUMMARY_MERGED"
  fi
  rm -f "$_phase_summary"
}

ORCH_RC=0

# ---- split unified --spec into a groups file + a users file ----------------
# We don't reimplement the JSON loader -- we just slice the spec and forward
# each half to the existing leaf, so any future JSON-shape change in either
# loader is picked up automatically.
ORCH_SPLIT_GROUPS=""
ORCH_SPLIT_USERS=""
if [ -n "$ORCH_SPEC" ]; then
  # Validate top-level shape first.
  if ! jq -e 'type=="object"' "$ORCH_SPEC" >/dev/null 2>&1; then
    log_err "spec must be a JSON object with optional 'groups' + 'users' arrays (file: $ORCH_SPEC)"
    exit 2
  fi
  if jq -e '.groups | type=="array"' "$ORCH_SPEC" >/dev/null 2>&1; then
    ORCH_SPLIT_GROUPS=$(mktemp -t 68-orch-groups.XXXXXX.json)
    if ! jq '{groups: .groups}' "$ORCH_SPEC" > "$ORCH_SPLIT_GROUPS" 2>/dev/null; then
      log_file_error "$ORCH_SPLIT_GROUPS" "could not write split groups file"
      exit 2
    fi
  fi
  if jq -e '.users | type=="array"' "$ORCH_SPEC" >/dev/null 2>&1; then
    ORCH_SPLIT_USERS=$(mktemp -t 68-orch-users.XXXXXX.json)
    if ! jq '{users: .users}' "$ORCH_SPEC" > "$ORCH_SPLIT_USERS" 2>/dev/null; then
      log_file_error "$ORCH_SPLIT_USERS" "could not write split users file"
      exit 2
    fi
  fi
  if [ -z "$ORCH_SPLIT_GROUPS" ] && [ -z "$ORCH_SPLIT_USERS" ]; then
    log_warn "spec '$ORCH_SPEC' contains neither 'groups' nor 'users' arrays -- nothing to do from it"
  fi
fi

# ---- helper: explode "name:flag1,flag2" into a positional argv -------------
# Embedded commas are NOT supported (use --spec for that case). This keeps
# the inline form predictable: split on ':' once, then split the tail on ','.
orch_explode_inline() {
  # $1 = "name:flag1,flag2,..."
  # echoes argv on stdout, one line per arg (caller mapfile's it back).
  local raw="$1"
  if [ -z "$raw" ]; then return 0; fi
  local name flags
  name="${raw%%:*}"
  if [ "$name" = "$raw" ]; then
    flags=""
  else
    flags="${raw#*:}"
  fi
  if [ -z "$name" ]; then
    log_warn "inline entry has empty name (input: '$raw') -- skipping"
    return 0
  fi
  printf '%s\n' "$name"
  if [ -n "$flags" ]; then
    local IFS=','
    # shellcheck disable=SC2086
    for tok in $flags; do
      [ -n "$tok" ] && printf '%s\n' "$tok"
    done
  fi
}

# ---- PHASE 1: inline groups (CLI) ------------------------------------------
if [ "${#ORCH_GROUPS_CLI[@]}" -gt 0 ]; then
  for entry in "${ORCH_GROUPS_CLI[@]}"; do
    [ -z "$entry" ] && continue
    mapfile -t _argv < <(orch_explode_inline "$entry")
    [ "${#_argv[@]}" -eq 0 ] && continue
    [ "$ORCH_DRY_RUN" = "1" ] && _argv+=(--dry-run)
    orch_run_leaf "group (cli) ${_argv[0]}" \
      bash "$SCRIPT_DIR/add-group.sh" "${_argv[@]}"
  done
fi

# ---- PHASE 2: groups from JSON (split spec OR --groups-json) --------------
for _gjson in "$ORCH_SPLIT_GROUPS" "$ORCH_GROUPS_JSON"; do
  if [ -n "$_gjson" ] && [ -f "$_gjson" ]; then
    _args=("$_gjson")
    [ "$ORCH_DRY_RUN" = "1" ] && _args+=(--dry-run)
    orch_run_leaf "groups (json) $_gjson" \
      bash "$SCRIPT_DIR/add-group-from-json.sh" "${_args[@]}"
  fi
done

# ---- PHASE 3: inline users (CLI) -------------------------------------------
if [ "${#ORCH_USERS_CLI[@]}" -gt 0 ]; then
  for entry in "${ORCH_USERS_CLI[@]}"; do
    [ -z "$entry" ] && continue
    mapfile -t _argv < <(orch_explode_inline "$entry")
    [ "${#_argv[@]}" -eq 0 ] && continue
    [ "$ORCH_DRY_RUN" = "1" ] && _argv+=(--dry-run)
    orch_run_leaf "user (cli) ${_argv[0]}" \
      bash "$SCRIPT_DIR/add-user.sh" "${_argv[@]}"
  done
fi

# ---- PHASE 4: users from JSON (split spec OR --users-json) ----------------
for _ujson in "$ORCH_SPLIT_USERS" "$ORCH_USERS_JSON"; do
  if [ -n "$_ujson" ] && [ -f "$_ujson" ]; then
    _args=("$_ujson")
    [ "$ORCH_DRY_RUN" = "1" ] && _args+=(--dry-run)
    orch_run_leaf "users (json) $_ujson" \
      bash "$SCRIPT_DIR/add-user-from-json.sh" "${_args[@]}"
  fi
done

# ---- merged roll-up --------------------------------------------------------
printf '\n'
log_info "================ orchestrator summary ================"
if [ -s "$ORCH_SUMMARY_MERGED" ]; then
  UM_SUMMARY_FILE="$ORCH_SUMMARY_MERGED" um_summary_print
else
  log_info "(no per-record rows recorded by leaves)"
fi
log_info "exit code: $ORCH_RC  (0 = all phases ok; 1 = at least one record failed)"
exit "$ORCH_RC"