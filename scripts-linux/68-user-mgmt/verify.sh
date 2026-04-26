#!/usr/bin/env bash
# 68-user-mgmt/verify.sh -- READ-ONLY verification of user/group state.
#
# Given a list of expected user and/or group names (via --spec JSON, separate
# --groups-json / --users-json files, or inline --group / --user flags), this
# script probes the live system and prints a pass/fail line per entity plus a
# final tally. It NEVER mutates anything -- safe to run before, after, or
# between orchestrator invocations.
#
# This is the canonical "did the orchestrator actually do what it claimed?"
# checker. The orchestrator calls it twice (BEFORE + AFTER snapshots) but it
# is fully usable on its own:
#
#   bash verify.sh --spec ./examples/full-bootstrap.json
#   bash verify.sh --user alice --user bob --group devs
#   bash verify.sh --users-json u.json --groups-json g.json
#
# Output is a table:
#   [pass|fail] kind name  detail
# Final line: "verify: N/M passed (exit 0)" or "verify: N/M passed (exit 1)".
#
# When invoked with --emit-snapshot <path>, also writes a TSV snapshot file:
#   <kind>\t<name>\t<exists 0|1>\t<id>\t<extra>
# This is what the orchestrator diffs to show what actually changed.
#
# CODE RED rule honored: every file/path error logs the EXACT path + reason.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

vrf_usage() {
  cat <<'EOF'
Usage: verify.sh [inputs] [--emit-snapshot FILE] [--quiet]

Inputs (any combination, all optional but at least one required):
  --spec FILE              Unified spec: { "groups": [...], "users": [...] }
  --groups-json FILE       Same shape as add-group-from-json.sh accepts
  --users-json  FILE       Same shape as add-user-from-json.sh accepts
  --group NAME             Expected group (repeatable)
  --user  NAME             Expected user  (repeatable)

Optional:
  --emit-snapshot FILE     Write TSV snapshot to FILE (for diffing). One row
                           per entity:  kind\tname\texists\tid\textra
  --quiet                  Suppress per-entity lines; only print the tally
  -h | --help              This help

Exit code:
  0  every expected entity exists (and matches expected ids/groups when given)
  1  at least one expected entity is missing or mismatched
  2  bad input (missing file, bad JSON, etc.)
 64  bad CLI usage
EOF
}

# ---- arg parse -------------------------------------------------------------
VRF_SPEC=""; VRF_GROUPS_JSON=""; VRF_USERS_JSON=""
VRF_GROUP_NAMES=()    # plain names from --group
VRF_USER_NAMES=()     # plain names from --user
VRF_SNAPSHOT=""
VRF_QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)        vrf_usage; exit 0 ;;
    --spec)           VRF_SPEC="${2:-}";         shift 2 ;;
    --groups-json)    VRF_GROUPS_JSON="${2:-}";  shift 2 ;;
    --users-json)     VRF_USERS_JSON="${2:-}";   shift 2 ;;
    --group)          VRF_GROUP_NAMES+=("${2:-}"); shift 2 ;;
    --user)           VRF_USER_NAMES+=("${2:-}");  shift 2 ;;
    --emit-snapshot)  VRF_SNAPSHOT="${2:-}";     shift 2 ;;
    --quiet)          VRF_QUIET=1;               shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1' (failure: see --help)"; exit 64 ;;
    *)  log_err "unexpected positional: '$1' (failure: verify.sh has no positionals)"; exit 64 ;;
  esac
done

if [ -z "$VRF_SPEC" ] && [ -z "$VRF_GROUPS_JSON" ] && [ -z "$VRF_USERS_JSON" ] \
   && [ "${#VRF_GROUP_NAMES[@]}" -eq 0 ] && [ "${#VRF_USER_NAMES[@]}" -eq 0 ]; then
  log_err "no expectations supplied (failure: pass --spec, --groups-json, --users-json, --group, or --user)"
  vrf_usage
  exit 64
fi

# Validate file inputs early (CODE RED).
for _f_pair in "spec:$VRF_SPEC" "groups-json:$VRF_GROUPS_JSON" "users-json:$VRF_USERS_JSON"; do
  _label="${_f_pair%%:*}"; _path="${_f_pair#*:}"
  if [ -n "$_path" ] && [ ! -f "$_path" ]; then
    log_file_error "$_path" "$_label JSON not found"
    exit 2
  fi
done

_need_jq=0
[ -n "$VRF_SPEC" ]        && _need_jq=1
[ -n "$VRF_GROUPS_JSON" ] && _need_jq=1
[ -n "$VRF_USERS_JSON" ]  && _need_jq=1
if [ "$_need_jq" = "1" ] && ! command -v jq >/dev/null 2>&1; then
  log_err "$(um_msg missingTool "jq")"
  exit 127
fi

um_detect_os || exit $?
# verify.sh does NOT need root -- read-only. We don't call um_require_root.

# ---- expectation collection ------------------------------------------------
# We build two parallel arrays:
#   VRF_GRP_EXPECT[i]  = "name\tgid_or_empty\tsystem_0_or_1"
#   VRF_USR_EXPECT[i]  = "name\tuid_or_empty\tprimary_or_empty\tgroups_csv\tshell_or_empty\thome_or_empty\tssh_count_or_empty"
# Then we iterate, probe the live system, and emit one line per entity.
VRF_GRP_EXPECT=()
VRF_USR_EXPECT=()

# Inline names -> empty expectations beyond existence.
for g in "${VRF_GROUP_NAMES[@]}"; do
  [ -z "$g" ] && continue
  VRF_GRP_EXPECT+=("$(printf '%s\t%s\t%s' "$g" "" "0")")
done
for u in "${VRF_USER_NAMES[@]}"; do
  [ -z "$u" ] && continue
  VRF_USR_EXPECT+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$u" "" "" "" "" "" "")")
done

# Helper: extract expectations from a JSON file given a top-level array key.
# Args: $1 = json file, $2 = "groups"|"users"
vrf_load_json() {
  local _f="$1" _kind="$2"
  # Normalize to an array (mirrors logic in the from-json leaves).
  local arr
  arr=$(jq -c --arg k "$_kind" '
    if type == "object" and has($k) and (.[$k]|type=="array") then .[$k]
    elif type == "array" then .
    elif type == "object" then [ . ]
    else error("top-level must be object or array")
    end
  ' "$_f" 2>/tmp/68-vrf-jq-err.$$)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    local err; err=$(cat /tmp/68-vrf-jq-err.$$ 2>/dev/null); rm -f /tmp/68-vrf-jq-err.$$
    log_err "$(um_msg jsonParseFail "$_f" "$err")"
    return 2
  fi
  rm -f /tmp/68-vrf-jq-err.$$
  local n; n=$(jq 'length' <<< "$arr")
  local i=0
  while [ "$i" -lt "$n" ]; do
    local rec; rec=$(jq -c ".[$i]" <<< "$arr")
    local name; name=$(jq -r '.name // empty' <<< "$rec")
    if [ -z "$name" ]; then i=$((i+1)); continue; fi
    if [ "$_kind" = "groups" ]; then
      local gid; gid=$(jq -r '.gid // empty' <<< "$rec")
      local sys; sys=$(jq -r 'if .system == true then "1" else "0" end' <<< "$rec")
      VRF_GRP_EXPECT+=("$(printf '%s\t%s\t%s' "$name" "$gid" "$sys")")
    else
      local uid pgr grps shl hom ssh_n
      uid=$(jq -r '.uid // empty' <<< "$rec")
      pgr=$(jq -r '.primaryGroup // empty' <<< "$rec")
      grps=$(jq -r 'if has("groups") and (.groups|type=="array") then (.groups|join(",")) else "" end' <<< "$rec")
      shl=$(jq -r '.shell // empty' <<< "$rec")
      hom=$(jq -r '.home  // empty' <<< "$rec")
      ssh_n=$(jq -r '
        ((if has("sshKeys")     and (.sshKeys|type=="array")     then (.sshKeys|length)     else 0 end)
       + (if has("sshKeyFiles") and (.sshKeyFiles|type=="array") then (.sshKeyFiles|length) else 0 end))
      ' <<< "$rec")
      # Note: ssh_n is the "at least N keys requested" hint -- file-sourced
      # keys can expand to many lines, so we only assert ">= N" when N > 0.
      VRF_USR_EXPECT+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "$uid" "$pgr" "$grps" "$shl" "$hom" "$ssh_n")")
    fi
    i=$((i+1))
  done
  return 0
}

# Pull from --spec (split into both arrays internally).
if [ -n "$VRF_SPEC" ]; then
  if jq -e '.groups | type=="array"' "$VRF_SPEC" >/dev/null 2>&1; then
    vrf_load_json "$VRF_SPEC" "groups" || exit $?
  fi
  if jq -e '.users | type=="array"' "$VRF_SPEC" >/dev/null 2>&1; then
    vrf_load_json "$VRF_SPEC" "users" || exit $?
  fi
fi
[ -n "$VRF_GROUPS_JSON" ] && { vrf_load_json "$VRF_GROUPS_JSON" "groups" || exit $?; }
[ -n "$VRF_USERS_JSON"  ] && { vrf_load_json "$VRF_USERS_JSON"  "users"  || exit $?; }

# ---- live probes (read-only) -----------------------------------------------
# Override um_group_exists with a getent-free fallback so verify.sh works
# on minimal containers (no nss-tools). um_user_exists already uses `id`
# which is in coreutils, so it's already portable.
um_group_exists() {
  local name="$1"
  if [ "$UM_OS" = "macos" ]; then
    dscl . -read "/Groups/$name" >/dev/null 2>&1
    return $?
  fi
  if command -v getent >/dev/null 2>&1; then
    getent group "$name" >/dev/null 2>&1
    return $?
  fi
  awk -F: -v n="$name" 'BEGIN{rc=1} $1==n {rc=0; exit} END{exit rc}' /etc/group 2>/dev/null
}

vrf_get_gid() {
  local n="$1"
  if [ "$UM_OS" = "macos" ]; then
    dscl . -read "/Groups/$n" PrimaryGroupID 2>/dev/null | awk '{print $2}'
  else
    if command -v getent >/dev/null 2>&1; then
      getent group "$n" 2>/dev/null | awk -F: '{print $3}'
    else
      # /etc/group fallback for minimal containers without nss tools.
      awk -F: -v n="$n" '$1==n {print $3; exit}' /etc/group 2>/dev/null
    fi
  fi
}

vrf_get_uid() {
  local n="$1"
  id -u "$n" 2>/dev/null
}

vrf_get_primary_group_name() {
  local n="$1"
  id -gn "$n" 2>/dev/null
}

vrf_get_supp_groups() {
  # Returns comma-separated supplementary group names (excluding primary).
  local n="$1" pg all
  pg=$(id -gn "$n" 2>/dev/null)
  all=$(id -Gn "$n" 2>/dev/null | tr ' ' '\n' | grep -vx "$pg" | paste -sd, -)
  printf '%s' "$all"
}

vrf_get_shell() {
  local n="$1"
  if [ "$UM_OS" = "macos" ]; then
    dscl . -read "/Users/$n" UserShell 2>/dev/null | awk '{print $2}'
  else
    if command -v getent >/dev/null 2>&1; then
      getent passwd "$n" 2>/dev/null | awk -F: '{print $7}'
    else
      awk -F: -v n="$n" '$1==n {print $7; exit}' /etc/passwd 2>/dev/null
    fi
  fi
}

vrf_get_home() {
  local n="$1"
  if [ "$UM_OS" = "macos" ]; then
    dscl . -read "/Users/$n" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    if command -v getent >/dev/null 2>&1; then
      getent passwd "$n" 2>/dev/null | awk -F: '{print $6}'
    else
      awk -F: -v n="$n" '$1==n {print $6; exit}' /etc/passwd 2>/dev/null
    fi
  fi
}

vrf_count_authorized_keys() {
  # Counts non-blank, non-comment lines in <home>/.ssh/authorized_keys.
  # Empty / missing -> "0". Returns "?" if home unreadable.
  local home="$1"
  [ -z "$home" ] && { printf '0'; return; }
  local f="$home/.ssh/authorized_keys"
  if [ ! -e "$f" ]; then printf '0'; return; fi
  if [ ! -r "$f" ]; then printf '?';  return; fi
  awk 'NF && $1 !~ /^#/' "$f" 2>/dev/null | wc -l | tr -d ' '
}

# ---- emit + tally ----------------------------------------------------------
VRF_PASS=0
VRF_FAIL=0
VRF_TOTAL=0

# Snapshot writer (TSV, no header) -- only if requested.
vrf_snap_open() {
  if [ -z "$VRF_SNAPSHOT" ]; then return 0; fi
  : > "$VRF_SNAPSHOT" 2>/dev/null || {
    log_file_error "$VRF_SNAPSHOT" "could not open snapshot file for write"
    return 2
  }
}
vrf_snap_row() {
  [ -z "$VRF_SNAPSHOT" ] && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$VRF_SNAPSHOT"
}

vrf_snap_open || exit $?

vrf_emit() {
  # $1=verdict (pass|fail) $2=kind $3=name $4=detail
  VRF_TOTAL=$((VRF_TOTAL + 1))
  if [ "$1" = "pass" ]; then VRF_PASS=$((VRF_PASS+1)); else VRF_FAIL=$((VRF_FAIL+1)); fi
  if [ "$VRF_QUIET" = "1" ]; then return 0; fi
  if [ "$1" = "pass" ]; then
    log_ok "[$1] $2 $3  $4"
  else
    log_err "[$1] $2 $3  $4"
  fi
}

# ---- verify groups ---------------------------------------------------------
for row in "${VRF_GRP_EXPECT[@]}"; do
  IFS=$'\t' read -r name want_gid want_sys <<< "$row"
  [ -z "$name" ] && continue
  if um_group_exists "$name"; then
    actual_gid=$(vrf_get_gid "$name")
    detail="gid=$actual_gid"
    verdict="pass"
    if [ -n "$want_gid" ] && [ "$actual_gid" != "$want_gid" ]; then
      verdict="fail"; detail="$detail  (expected gid=$want_gid)"
    fi
    vrf_snap_row "group" "$name" 1 "$actual_gid" ""
    vrf_emit "$verdict" "group" "$name" "$detail"
  else
    vrf_snap_row "group" "$name" 0 "" ""
    vrf_emit "fail" "group" "$name" "MISSING"
  fi
done

# ---- verify users ----------------------------------------------------------
for row in "${VRF_USR_EXPECT[@]}"; do
  IFS=$'\t' read -r name want_uid want_pg want_grps want_shell want_home want_ssh <<< "$row"
  [ -z "$name" ] && continue
  if ! um_user_exists "$name"; then
    vrf_snap_row "user" "$name" 0 "" ""
    vrf_emit "fail" "user" "$name" "MISSING"
    continue
  fi
  actual_uid=$(vrf_get_uid "$name")
  actual_pg=$(vrf_get_primary_group_name "$name")
  actual_supp=$(vrf_get_supp_groups "$name")
  actual_shell=$(vrf_get_shell "$name")
  actual_home=$(vrf_get_home "$name")
  ssh_count=$(vrf_count_authorized_keys "$actual_home")

  detail="uid=$actual_uid pg=$actual_pg"
  [ -n "$actual_supp" ] && detail="$detail supp=$actual_supp"
  [ -n "$actual_shell" ] && detail="$detail shell=$actual_shell"
  detail="$detail ssh=$ssh_count"
  verdict="pass"

  # Field-by-field assertions, only when an expectation was provided.
  if [ -n "$want_uid" ] && [ "$actual_uid" != "$want_uid" ]; then
    verdict="fail"; detail="$detail  (expected uid=$want_uid)"
  fi
  if [ -n "$want_pg" ] && [ "$actual_pg" != "$want_pg" ]; then
    verdict="fail"; detail="$detail  (expected pg=$want_pg)"
  fi
  if [ -n "$want_grps" ]; then
    IFS=',' read -ra _wg <<< "$want_grps"
    for g in "${_wg[@]}"; do
      g="${g// /}"; [ -z "$g" ] && continue
      # accept group as either primary or supplementary
      if [ "$g" = "$actual_pg" ]; then continue; fi
      if printf ',%s,' ",$actual_supp," | grep -q ",$g,"; then continue; fi
      # Fallback: ask `id -nG` directly so we don't miss edge cases.
      if id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then continue; fi
      verdict="fail"; detail="$detail  (missing group: $g)"
    done
  fi
  if [ -n "$want_shell" ] && [ "$actual_shell" != "$want_shell" ]; then
    verdict="fail"; detail="$detail  (expected shell=$want_shell)"
  fi
  if [ -n "$want_home" ] && [ "$actual_home" != "$want_home" ]; then
    verdict="fail"; detail="$detail  (expected home=$want_home)"
  fi
  if [ -n "$want_ssh" ] && [ "$want_ssh" != "0" ]; then
    if [ "$ssh_count" = "?" ]; then
      verdict="fail"; detail="$detail  (authorized_keys unreadable)"
    elif [ "$ssh_count" -lt "$want_ssh" ] 2>/dev/null; then
      verdict="fail"; detail="$detail  (expected >= $want_ssh ssh keys)"
    fi
  fi

  vrf_snap_row "user" "$name" 1 "$actual_uid" "pg=$actual_pg;supp=$actual_supp;shell=$actual_shell;home=$actual_home;ssh=$ssh_count"
  vrf_emit "$verdict" "user" "$name" "$detail"
done

# ---- final tally -----------------------------------------------------------
printf '\n'
if [ "$VRF_FAIL" -eq 0 ]; then
  log_ok "verify: $VRF_PASS/$VRF_TOTAL passed (exit 0)"
  exit 0
else
  log_err "verify: $VRF_PASS/$VRF_TOTAL passed, $VRF_FAIL FAILED (exit 1)"
  exit 1
fi