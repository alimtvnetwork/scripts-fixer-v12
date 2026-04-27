#!/usr/bin/env bash
# remove-user -- delete one user; see readme.md.
# 68-user-mgmt/remove-user.sh -- delete a single local user (Linux | macOS).
#
# Usage:
#   ./remove-user.sh <name> [flags]
#   ./remove-user.sh --ask
#
# Flags:
#   --purge-home          also delete the home directory (DESTRUCTIVE)
#   --purge-profile       Windows-friendly alias for --purge-home (same semantics
#                         on Unix; lets a single fan-out command run on both OSes)
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

um_usage() {
  cat <<'EOF'
remove-user -- delete one user; see readme.md.
68-user-mgmt/remove-user.sh -- delete a single local user (Linux | macOS).

Usage:
  ./remove-user.sh <name> [flags]
  ./remove-user.sh --ask

Flags:
  --purge-home          also delete the home directory (DESTRUCTIVE)
  --purge-profile       Windows-friendly alias for --purge-home (same semantics
                        on Unix; lets a single fan-out command run on both OSes)
  --remove-mail-spool   Linux only: also delete /var/mail/<name> (passes -r)
  --yes                 skip the confirmation prompt
  --ask                 prompt interactively
  --dry-run             print what would happen, change nothing

Exit codes match add-user.sh (0/1/2/13/64/127). Removing a user that does
not exist is treated as success (idempotent), with a [WARN] log line.

Dry-run effect per flag (with --dry-run, the plan summary "remove plan
for <name>:" is printed first, the confirmation prompt is BYPASSED, and
every mutating call is logged as "[dry-run] <command>"):
  <name>                would resolve account + home dir, then call
                        userdel (Linux) / sysadminctl -deleteUser (macOS).
                        Absent account -> "[WARN] nothing to remove"
                        and exit 0 (idempotent); no mutation either way.
  --purge-home          would 'rm -rf <home>' AFTER account delete (or, on
                        Linux, fold into 'userdel -r' atomically). DESTRUCTIVE
                        in real-run; in dry-run only the rm command is logged.
  --purge-profile       same as --purge-home (alias only); same dry-run line.
  --remove-mail-spool   Linux only: would pass -r to userdel so /var/mail/<name>
                        is deleted in the same atomic call. macOS: ignored.
  --yes / -y            no dry-run effect (skips the y/N confirmation; under
                        --dry-run the prompt is already skipped automatically)
  --ask                 prompts BEFORE the dry-run banner; collected answers
                        still drive the would-do log lines
  --dry-run             this flag itself; bypasses the y/N prompt, emits the
                        dry-run banner, and gates every userdel / dscl /
                        rm -rf call

CODE RED: every file/path error logs the EXACT path + the failure reason.
EOF
}

UM_NAME=""
UM_PURGE=0
UM_REMOVE_MAIL=0
UM_AUTO_YES=0
UM_ASK=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)            um_usage; exit 0 ;;
    --purge-home|--purge-profile) UM_PURGE=1; shift ;;
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
# Delete account record. On Linux, userdel -r purges $HOME atomically when
# either --purge-home or --remove-mail-spool is set, so we let the helper
# pass that flag and skip the explicit um_purge_home call.
linux_purged_home=0
if [ "$UM_OS" = "linux" ] && { [ "$UM_PURGE" = "1" ] || [ "$UM_REMOVE_MAIL" = "1" ]; }; then
  um_user_delete "$UM_NAME" --remove-mail-spool || rc=1
  linux_purged_home=1
else
  um_user_delete "$UM_NAME" || rc=1
fi

# macOS (and any Linux path that didn't pass -r) needs an explicit purge.
if [ "$UM_PURGE" = "1" ] && [ "$linux_purged_home" = "0" ] && [ -n "$UM_HOME" ]; then
  um_purge_home "$UM_HOME" || rc=1
fi
exit $rc
