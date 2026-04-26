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

normalised=$(jq -c '
  if type == "object" and has("groups") and (.groups|type=="array") then .groups
  elif type == "array" then .
  elif type == "object" then [ . ]
  else error("top-level must be object or array")
  end
' "$UM_FILE" 2>/tmp/68-jqg-err.$$)
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  err_text=$(cat /tmp/68-jqg-err.$$ 2>/dev/null); rm -f /tmp/68-jqg-err.$$
  log_err "$(um_msg jsonParseFail "$UM_FILE" "$err_text")"
  exit 2
fi
rm -f /tmp/68-jqg-err.$$

count=$(jq 'length' <<< "$normalised")
log_info "loaded $count group record(s) from '$UM_FILE'"

UM_SUMMARY_FILE="${UM_SUMMARY_FILE:-$(mktemp -t 68-summary.XXXXXX)}"
export UM_SUMMARY_FILE

rc_total=0
i=0
while [ "$i" -lt "$count" ]; do
  rec=$(jq -c ".[$i]" <<< "$normalised")
  name=$(jq -r '.name // empty'   <<< "$rec")
  if [ -z "$name" ]; then
    log_err "$(um_msg jsonRecordBad "$i" "$UM_FILE" "name")"
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