#!/usr/bin/env bash
# 68-user-mgmt/add-group.sh -- create a single local group (Linux | macOS).
#
# Usage:
#   ./add-group.sh <name> [--gid N] [--system] [--dry-run]

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

um_usage() {
  cat <<EOF
# add-group -- create one local group (Linux | macOS); see readme.md.
Usage: add-group.sh <name> [options]

Required:
  <name>          group name

Optional:
  --gid N         explicit numeric GID
  --system        system group (Linux only; ignored on macOS)
  --dry-run       print what would happen, change nothing
EOF
}

UM_NAME=""
UM_GID=""
UM_SYSTEM=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) um_usage; exit 0 ;;
    --gid)     UM_GID="${2:-}"; shift 2 ;;
    --system)  UM_SYSTEM=1; shift ;;
    --dry-run) UM_DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*)
      log_err "unknown option: '$1' (failure: see --help)"
      exit 64
      ;;
    *)
      if [ -z "$UM_NAME" ]; then UM_NAME="$1"; shift
      else log_err "unexpected positional: '$1'"; exit 64; fi
      ;;
  esac
done

if [ -z "$UM_NAME" ]; then
  log_err "missing required <name> (failure: nothing to create)"
  um_usage; exit 64
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

if um_group_exists "$UM_NAME"; then
  log_warn "$(um_msg groupExists "$UM_NAME")"
  um_summary_add "skip" "group" "$UM_NAME" "exists"
  exit 0
fi

if [ "$UM_OS" = "linux" ]; then
  args=(groupadd)
  [ "$UM_SYSTEM" = "1" ] && args+=(--system)
  [ -n "$UM_GID" ]       && args+=(--gid "$UM_GID")
  args+=("$UM_NAME")
  if um_run "${args[@]}"; then
    created_gid=$(getent group "$UM_NAME" | awk -F: '{print $3}')
    log_ok "$(um_msg groupCreated "$UM_NAME" "$created_gid")"
    um_summary_add "ok" "group" "$UM_NAME" "gid=$created_gid"
  else
    log_err "$(um_msg groupCreateFail "$UM_NAME" "groupadd returned non-zero")"
    um_summary_add "fail" "group" "$UM_NAME" "groupadd failed"
    exit 1
  fi
else
  if [ -z "$UM_GID" ]; then UM_GID=$(um_next_macos_gid 510); fi
  um_run dscl . -create "/Groups/$UM_NAME"                            || { log_err "$(um_msg groupCreateFail "$UM_NAME" "dscl create failed")"; exit 1; }
  um_run dscl . -create "/Groups/$UM_NAME" PrimaryGroupID "$UM_GID"   || true
  log_ok "$(um_msg groupCreated "$UM_NAME" "$UM_GID")"
  um_summary_add "ok" "group" "$UM_NAME" "gid=$UM_GID"
fi