#!/usr/bin/env bash
# 68-user-mgmt/remove-user-from-json.sh -- bulk user removal from JSON.
#
# Input shapes (auto-detected, same as add-user-from-json.sh):
#   1) Single object:  { "name": "alice", "purgeHome": true }
#   2) Array:          [ { ... }, { ... }, ... ]
#   3) Wrapped:        { "users": [ ... ] }   <- also accepted
#   4) Bare strings:   [ "alice", "bob" ]      <- shorthand: each string is
#                                                a record with just `.name`
#                                                (no purgeHome, no purgeMail)
#
# Each record is dispatched to remove-user.sh -- removing a missing user
# is treated as success (idempotent), so re-running the same JSON is safe.
#
# Per-record schema (every field optional except `name`):
#
#   { "name":            "alice",   # REQUIRED -- account to remove
#     "purgeHome":       true,      # --purge-home (DESTRUCTIVE)
#     "removeMailSpool": true       # --remove-mail-spool (Linux only)
#   }
#
# Confirmation prompts are auto-bypassed (--yes is added unconditionally)
# because bulk-from-JSON cannot be interactive. Use --dry-run if you want
# a preview without mutation.
#
# Usage:
#   ./remove-user-from-json.sh <file.json> [--dry-run]

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

# As of v0.203.0 this loader applies each record IN-PROCESS via the shared
# um_user_delete + um_purge_home helpers rather than forking
# `bash remove-user.sh` per row. Confirmation prompts are skipped because
# bulk-from-JSON is non-interactive by design.

UM_ALLOWED_FIELDS="name purgeHome purgeProfile removeMailSpool"

_validate_remove_record() {
    local rec="$1"
    local toptype
    toptype=$(jq -r 'type' <<< "$rec")
    if [ "$toptype" != "object" ]; then
        printf 'ERROR\t<root>\tnot an object (got %s)\n' "$toptype"
        return 0
    fi
    jq -r --arg allowed "$UM_ALLOWED_FIELDS" '
        def expect(field; want):
            if has(field) then
                (.[field] | type) as $t
                | if $t != want then "ERROR\t\(field)\twrong type: expected \(want), got \($t)"
                  else empty end
            else empty end;

        def expect_nonempty_string(field):
            if has(field) then
                (.[field]) as $v | ($v | type) as $t
                | if $t == "null" then "ERROR\t\(field)\tnull value"
                  elif $t != "string" then "ERROR\t\(field)\twrong type: expected string, got \($t)"
                  elif ($v | length) == 0 then "ERROR\t\(field)\tempty string"
                  else empty end
            else empty end;

        ( if has("name") | not then "ERROR\tname\tmissing required field" else empty end ),
        expect_nonempty_string("name"),
        expect("purgeHome";       "boolean"),
        expect("purgeProfile";    "boolean"),
        expect("removeMailSpool"; "boolean"),

        ( ($allowed | split(" ")) as $known
          | keys[]
          | select(. as $k | ($known | index($k)) | not)
          | "WARN\t\(.)\tunknown field (allowed: \($allowed))"
        )
    ' <<< "$rec" 2>/dev/null
}

um_usage() {
  cat <<EOF
Usage: remove-user-from-json.sh <file.json> [--dry-run]

Accepts a JSON file in any of:
  - single object   : { "name": "alice", "purgeHome": true }
  - array           : [ { ... }, { ... } ]
  - wrapped         : { "users": [ ... ] }
  - bare-string list: [ "alice", "bob" ]   (shorthand: name only)

Each record fans out to remove-user.sh with --yes (no per-record prompts).
Removing a missing user is a no-op (idempotent), so this is safe to re-run.
EOF
}

UM_FILE=""
UM_DRY_RUN="${UM_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) um_usage; exit 0 ;;
    --dry-run) UM_DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1' (failure: see --help)"; exit 64 ;;
    *)
      if [ -z "$UM_FILE" ]; then UM_FILE="$1"; shift
      else log_err "unexpected positional: '$1' (failure: only <file.json> is positional)"; exit 64; fi
      ;;
  esac
done

if [ -z "$UM_FILE" ]; then
  log_err "missing required <file.json> (failure: nothing to read)"
  um_usage; exit 64
fi
if [ ! -f "$UM_FILE" ]; then
  log_file_error "$UM_FILE" "JSON input not found"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  log_err "$(um_msg missingTool "jq" 2>/dev/null || echo "required tool 'jq' not found on PATH (failure: install jq)")"
  exit 127
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner 2>/dev/null || echo "[dry-run] no host mutation will occur")"; fi

# Normalise into an array on stdout. The bare-string list case
# ([ "alice", "bob" ]) is converted to objects up front so the rest of
# the loop only ever sees [ {name: ...}, ... ].
normalised=$(jq -c '
  ( if   type == "object" and has("users") and (.users|type=="array") then .users
    elif type == "array"  then .
    elif type == "object" then [ . ]
    else error("top-level must be object or array")
    end
  )
  | map(if type == "string" then { name: . } else . end)
' "$UM_FILE" 2>/tmp/68-jq-err.$$)
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  err_text=$(cat /tmp/68-jq-err.$$ 2>/dev/null); rm -f /tmp/68-jq-err.$$
  log_err "JSON parse failed for exact path: '$UM_FILE' (failure: $err_text)"
  exit 2
fi
rm -f /tmp/68-jq-err.$$

count=$(jq 'length' <<< "$normalised")
log_info "loaded $count user-removal record(s) from '$UM_FILE'"

# In-process applicator. Resolves the user's home dir BEFORE deleting the
# account so we can purge it after (matches remove-user.sh semantics).
_apply_remove_record() {
  local name="$1" is_purge="$2" is_mail="$3"
  local home="" rc=0 linux_purged_home=0

  log_info "$(um_msg removePlanHeader "$name" 2>/dev/null || echo "remove-user plan for '$name':")"
  log_info "  - delete user account"

  if um_user_exists "$name"; then
    if [ "$UM_OS" = "linux" ]; then
      home=$(getent passwd "$name" | awk -F: '{print $6}')
    else
      home=$(dscl . -read "/Users/$name" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    fi
  fi
  [ "$is_purge" = "1" ] && [ -n "$home" ] && log_info "  - delete home dir: $home (DESTRUCTIVE)"
  [ "$is_mail"  = "1" ] && [ "$UM_OS" = "linux" ] && log_info "  - delete /var/mail/$name (Linux mail spool)"

  # Linux: userdel -r covers home + mail spool atomically when either flag set.
  if [ "$UM_OS" = "linux" ] && { [ "$is_purge" = "1" ] || [ "$is_mail" = "1" ]; }; then
    um_user_delete "$name" --remove-mail-spool || rc=1
    linux_purged_home=1
  else
    um_user_delete "$name" || rc=1
  fi

  if [ "$is_purge" = "1" ] && [ "$linux_purged_home" = "0" ] && [ -n "$home" ]; then
    um_purge_home "$home" || rc=1
  fi
  return $rc
}

rc_total=0
i=0
while [ "$i" -lt "$count" ]; do
  rec=$(jq -c ".[$i]" <<< "$normalised")

  validation_out=$(_validate_remove_record "$rec")
  err_count=0
  if [ -n "$validation_out" ]; then
    while IFS=$'\t' read -r severity field reason; do
      [ -z "$severity" ] && continue
      case "$severity" in
        ERROR)
          err_count=$((err_count+1))
          log_err "JSON record #$i in '$UM_FILE' field '$field': $reason (failure: rejecting record)"
          ;;
        WARN)
          log_warn "JSON record #$i in '$UM_FILE' field '$field': $reason"
          ;;
      esac
    done <<< "$validation_out"
  fi

  if [ "$(jq -r 'type' <<< "$rec")" = "object" ]; then
    name=$(jq -r '.name // "<missing>"' <<< "$rec")
  else
    name="<not-an-object>"
  fi

  if [ "$err_count" -gt 0 ]; then
    log_err "rejected record #$i in '$UM_FILE' for user='$name' ($err_count schema error(s))"
    rc_total=1
    i=$((i+1)); continue
  fi

  # Accept either purgeHome (Unix-native) or purgeProfile (Windows-friendly alias).
  is_purge=$(jq -r 'if (.purgeHome == true) or (.purgeProfile == true) then "1" else "" end' <<< "$rec")
  is_mail=$(jq -r  'if .removeMailSpool == true then "1" else "" end' <<< "$rec")

  log_info "--- record $((i+1))/$count: remove user='$name'$([ "$is_purge" = "1" ] && echo " (+purge home)") ---"
  _apply_remove_record "$name" "$is_purge" "$is_mail" || rc_total=1
  i=$((i+1))
done

exit $rc_total