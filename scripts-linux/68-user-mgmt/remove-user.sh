#!/usr/bin/env bash
# 68-user-mgmt/remove-user.sh -- delete a single local user (Linux | macOS).
#
# Usage:
#   ./remove-user.sh <name> [flags]
#   ./remove-user.sh --ask
#
# Flags:
#   --purge-home          also delete the home directory (DESTRUCTIVE)
#   --remove-mail-spool   Linux only: also delete /var/mail/<name> (passes -r)
#   --yes                 skip the confirmation prompt
#   --ask                 prompt interactively
#   --dry-run             print what would happen, change nothing
#
# Exit codes match add-user.sh (0/1/2/13/64/127). Removing a user that does
# not exist is treated as success (idempotent), with a [WARN] log line.
#
# CODE RED: every file/path error logs the EXACT path + the failure reason.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"
[ -f "$SCRIPT_DIR/helpers/_prompt.sh" ] && . "$SCRIPT_DIR/helpers/_prompt.sh"

um_usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

UM_NAME=""
UM_PURGE=0
UM_REMOVE_MAIL=0
UM_AUTO_YES=0
UM_ASK=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)            um_usage; exit 0 ;;
    --purge-home)         UM_PURGE=1; shift ;;
    --remove-mail-spool)  UM_REMOVE_MAIL=1; shift ;;
    --yes|-y)             UM_AUTO_YES=1; shift ;;
    --ask)                UM_ASK=1; shift ;;
    --dry-run)            UM_DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*)
      log_err "unknown option: '$1' (failure: see --help)"
      exit 64 ;;
    *)
      if [ -z "$UM_NAME" ]; then UM_NAME="$1"; shift
      else log_err "unexpected positional: '$1' (failure: only <name> is positional)"; exit 64; fi
      ;;
  esac
done

if [ "$UM_ASK" = "1" ]; then
  if command -v um_prompt_string >/dev/null 2>&1; then
    [ -z "$UM_NAME" ] && UM_NAME=$(um_prompt_string "Username to remove" "" 1)
    UM_PURGE=$(um_prompt_confirm "Also delete home directory?" 0 && echo 1 || echo 0)
    UM_AUTO_YES=1
  else
    log_err "--ask requested but helpers/_prompt.sh is missing (failure: cannot prompt)"
    exit 1
  fi
fi

if [ -z "$UM_NAME" ]; then
  log_err "missing required <name> (failure: nothing to remove)"
  um_usage; exit 64
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

# Resolve home dir before delete so we can purge it after.
UM_HOME=""
if um_user_exists "$UM_NAME"; then
  if [ "$UM_OS" = "linux" ]; then
    UM_HOME=$(getent passwd "$UM_NAME" | awk -F: '{print $6}')
  else
    UM_HOME=$(dscl . -read "/Users/$UM_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  fi
fi

log_info "$(um_msg removePlanHeader "$UM_NAME")"
log_info "  - delete user account"
[ "$UM_PURGE" = "1" ] && [ -n "$UM_HOME" ] && log_info "  - delete home dir: $UM_HOME (DESTRUCTIVE)"
[ "$UM_REMOVE_MAIL" = "1" ] && [ "$UM_OS" = "linux" ] && log_info "  - delete /var/mail/$UM_NAME (Linux mail spool)"

if [ "$UM_DRY_RUN" != "1" ] && [ "$UM_AUTO_YES" != "1" ]; then
  printf '  Proceed? [y/N]: '
  read -r ans </dev/tty 2>/dev/null || ans=""
  case "$ans" in
    y|Y|yes|YES) : ;;
    *) log_warn "cancelled by user"; exit 0 ;;
  esac
fi

if ! um_user_exists "$UM_NAME"; then
  log_warn "user '$UM_NAME' does not exist -- nothing to remove (idempotent)"
  um_summary_add "skip" "remove-user" "$UM_NAME" "absent"
  exit 0
fi

rc=0
if [ "$UM_OS" = "linux" ]; then
  args=(userdel)
  [ "$UM_PURGE" = "1" ] && args+=(-r)
  [ "$UM_REMOVE_MAIL" = "1" ] && args+=(-r)  # -r already covers mail spool
  args+=("$UM_NAME")
  if um_run "${args[@]}"; then
    log_ok "$(um_msg userRemoved "$UM_NAME")"
    um_summary_add "ok" "remove-user" "$UM_NAME" "userdel"
  else
    log_err "$(um_msg userRemoveFail "$UM_NAME" "userdel returned non-zero")"
    um_summary_add "fail" "remove-user" "$UM_NAME" "userdel failed"
    rc=1
  fi
else
  if um_run dscl . -delete "/Users/$UM_NAME"; then
    log_ok "$(um_msg userRemoved "$UM_NAME")"
    um_summary_add "ok" "remove-user" "$UM_NAME" "dscl -delete"
  else
    log_err "$(um_msg userRemoveFail "$UM_NAME" "dscl -delete failed")"
    um_summary_add "fail" "remove-user" "$UM_NAME" "dscl -delete failed"
    rc=1
  fi
  # macOS doesn't auto-purge $HOME; do it ourselves when requested.
  if [ "$UM_PURGE" = "1" ] && [ -n "$UM_HOME" ] && [ -d "$UM_HOME" ]; then
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] rm -rf '$UM_HOME'"
    else
      if rm -rf -- "$UM_HOME" 2>/dev/null; then
        log_ok "$(um_msg homeRemoved "$UM_HOME")"
      else
        log_file_error "$UM_HOME" "could not remove macOS home directory after user delete"
        rc=1
      fi
    fi
  fi
fi
exit $rc
