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
. "$SCRIPT_DIR/helpers/_schema.sh"

# As of v0.203.0 this loader applies each record IN-PROCESS via the shared
# um_user_delete + um_purge_home helpers rather than forking
# `bash remove-user.sh` per row. Confirmation prompts are skipped because
# bulk-from-JSON is non-interactive by design.

UM_ALLOWED_FIELDS="name purgeHome purgeProfile removeMailSpool"

UM_SCHEMA_REQUIRED="name"
UM_SCHEMA_FIELDS="name:nestr purgeHome:bool purgeProfile:bool removeMailSpool:bool"

um_usage() {
  cat <<EOF
# remove-user-json -- bulk user removal from JSON; see readme.md for schema.
Usage: remove-user-from-json.sh <file.json> [--dry-run]

Accepts a JSON file containing a single object **or** array -- auto-detected.
Four accepted shapes (mirrors readme.md "Bulk edit / remove"):
  - single object   : { "name": "alice", "purgeHome": true }
  - array           : [ { ... }, { ... } ]
  - wrapped         : { "users": [ ... ] }
  - bare-string list: [ "alice", "bob" ]   (shorthand: name only)

Each record applies in-process via the um_user_delete shared helper and
always passes --yes (no per-record confirmation prompts in bulk mode).
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

# Normalise (bare-string list converted to {name: ...} via --allow-strings).
um_schema_normalize_array "$UM_FILE" "users" --allow-strings || exit 2
normalised="$UM_NORMALIZED_JSON"
count="$UM_NORMALIZED_COUNT"
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

  validation_out=$(um_schema_validate_record "$rec" "$UM_ALLOWED_FIELDS" \
    "$UM_SCHEMA_REQUIRED" "$UM_SCHEMA_FIELDS")
  um_schema_report "$i" "$UM_FILE" "$validation_out" "plain"
  name=$(um_schema_record_name "$rec")

  if [ "$UM_SCHEMA_ERR_COUNT" -gt 0 ]; then
    log_err "rejected record #$i in '$UM_FILE' for user='$name' ($UM_SCHEMA_ERR_COUNT schema error(s))"
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