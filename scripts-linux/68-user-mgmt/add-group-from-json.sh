#!/usr/bin/env bash
# 68-user-mgmt/add-group-from-json.sh -- bulk group creation from JSON.
#
# Input shapes (auto-detected, mirrors add-user-from-json.sh):
#   1) Single object:  { "name": "devs", "gid": 2000 }
#   2) Array:          [ { ... }, { ... }, ... ]
#   3) Wrapped:        { "groups": [ ... ] }

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"
. "$SCRIPT_DIR/helpers/_schema.sh"

UM_ALLOWED_FIELDS="name gid system"
UM_SCHEMA_REQUIRED="name"
UM_SCHEMA_FIELDS="name:nestr gid:uid system:bool"

um_usage() {
  cat <<EOF
Usage: add-group-from-json.sh <file.json> [--dry-run]
EOF
}

UM_FILE=""
UM_DRY_RUN="${UM_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) um_usage; exit 0 ;;
    --dry-run) UM_DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1'"; exit 64 ;;
    *)
      if [ -z "$UM_FILE" ]; then UM_FILE="$1"; shift
      else log_err "unexpected positional: '$1'"; exit 64; fi
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
  log_err "$(um_msg missingTool "jq")"
  exit 127
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

um_schema_normalize_array "$UM_FILE" "groups" || exit 2
normalised="$UM_NORMALIZED_JSON"
count="$UM_NORMALIZED_COUNT"
log_info "loaded $count group record(s) from '$UM_FILE'"

UM_SUMMARY_FILE="${UM_SUMMARY_FILE:-$(mktemp -t 68-summary.XXXXXX)}"
export UM_SUMMARY_FILE

rc_total=0
i=0
while [ "$i" -lt "$count" ]; do
  rec=$(jq -c ".[$i]" <<< "$normalised")

  validation_out=$(um_schema_validate_record "$rec" "$UM_ALLOWED_FIELDS" \
    "$UM_SCHEMA_REQUIRED" "$UM_SCHEMA_FIELDS")
  um_schema_report "$i" "$UM_FILE" "$validation_out" "plain"
  name=$(um_schema_record_name "$rec")

  if [ "$UM_SCHEMA_ERR_COUNT" -gt 0 ]; then
    log_err "rejected record #$i in '$UM_FILE' for group='$name' ($UM_SCHEMA_ERR_COUNT schema error(s))"
    rc_total=1
    i=$((i+1)); continue
  fi

  gid=$(jq -r    '.gid // empty'                       <<< "$rec")
  is_sys=$(jq -r 'if .system == true then "1" else "" end' <<< "$rec")

  args=("$name")
  [ -n "$gid" ]       && args+=(--gid "$gid")
  [ "$is_sys" = "1" ] && args+=(--system)
  [ "$UM_DRY_RUN" = "1" ] && args+=(--dry-run)

  log_info "--- record $((i+1))/$count: group='$name' ---"
  if ! bash "$SCRIPT_DIR/add-group.sh" "${args[@]}"; then
    rc_total=1
  fi
  i=$((i+1))
done

um_summary_print
exit "$rc_total"