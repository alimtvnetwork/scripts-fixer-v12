#!/usr/bin/env bash
# edit-user -- modify one user (rename/promote/...); see readme.md.
# 68-user-mgmt/edit-user.sh -- modify a single local user (Linux | macOS).
#
# Usage:
#   ./edit-user.sh <name> [flags]
#   ./edit-user.sh --ask
#
# Flags (every flag is optional; pick the changes you want):
#   --rename <newName>            rename the account
#   --reset-password <PW>         reset password (plain CLI -- accepted risk)
#   --password-file <FILE>        reset password from file (mode 0600)
#   --promote                     add to sudo group ('sudo' on Linux, 'admin' on macOS)
#   --demote                      remove from sudo/admin group (account stays)
#   --add-group <g>               add to group (comma-list OK, repeatable)
#   --remove-group <g>            remove from group (comma-list OK, repeatable)
#   --shell <PATH>                change login shell
#   --comment "..."               change GECOS / RealName
#   --enable | --disable          unlock or lock the account
#   --ask                         prompt interactively for missing fields
#   --dry-run                     print actions, change nothing
#
# Exit codes match add-user.sh: 0=ok, 1=tool error, 2=input error,
# 13=not root (and not --dry-run), 64=bad CLI usage, 127=missing tool.
#
# CODE RED: every file/path error logs the EXACT path + the failure reason.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"
[ -f "$SCRIPT_DIR/helpers/_prompt.sh" ] && . "$SCRIPT_DIR/helpers/_prompt.sh"

um_usage() {
  cat <<'EOF'
edit-user -- modify one user (rename/promote/...); see readme.md.
68-user-mgmt/edit-user.sh -- modify a single local user (Linux | macOS).

Usage:
  ./edit-user.sh <name> [flags]
  ./edit-user.sh --ask

Flags (every flag is optional; pick the changes you want):
  --rename <newName>            rename the account
  --reset-password <PW>         reset password (plain CLI -- accepted risk)
  --password-file <FILE>        reset password from file (mode 0600)
  --promote                     add to sudo group ('sudo' on Linux, 'admin' on macOS)
  --demote                      remove from sudo/admin group (account stays)
  --add-group <g>               add to group (comma-list OK, repeatable)
  --remove-group <g>            remove from group (comma-list OK, repeatable)
  --shell <PATH>                change login shell
  --comment "..."               change GECOS / RealName
  --enable | --disable          unlock or lock the account
  --ask                         prompt interactively for missing fields
  --dry-run                     print actions, change nothing

Exit codes match add-user.sh: 0=ok, 1=tool error, 2=input error,
13=not root (and not --dry-run), 64=bad CLI usage, 127=missing tool.

Dry-run effect per flag (with --dry-run, every mutating action is routed
through the um_user_modify shim and logged as "[dry-run] <command>"; the
plan summary "edit plan for <name>:" is printed BEFORE any action so
you see the same intent in dry-run and real-run):
  <name>                        would resolve the account; missing user
                                logs "[FAIL] user does not exist" and
                                aborts the record (still no mutation)
  --rename <newName>            would call usermod -l (Linux) / dscl rename
                                (macOS); applied LAST so other ops still
                                target the original name
  --reset-password <PW>         would pipe '<name>:<masked>' to chpasswd
                                (Linux) or dscl . -passwd (macOS); value
                                NEVER logged
  --password-file <FILE>        same as --reset-password but reads PW from
                                FILE (mode 0600 enforced before plan)
  --promote                     would add to 'sudo' (Linux) / 'admin'
                                (macOS) via usermod -aG / dseditgroup
  --demote                      would remove from 'sudo' / 'admin' via
                                gpasswd -d (Linux) / dseditgroup -d (macOS)
  --add-group <g>               would add to <g> (one usermod / dseditgroup
                                call per group; comma-list expanded first)
  --remove-group <g>            would remove from <g> (one gpasswd /
                                dseditgroup call per group)
  --shell <PATH>                would call usermod -s PATH (Linux) /
                                dscl . -create UserShell (macOS)
  --comment "..."               would call usermod -c "..." (Linux) /
                                dscl . -create RealName (macOS); empty
                                string clears the field
  --enable                      would call usermod -U / passwd -u (Linux) /
                                pwpolicy -enableuser (macOS)
  --disable                     would call usermod -L / passwd -l (Linux) /
                                pwpolicy -disableuser (macOS)
  --ask                         prompt happens BEFORE the dry-run banner;
                                collected values still drive the would-do
                                log lines
  --dry-run                     this flag itself; emits the dry-run banner,
                                still prints the plan summary, and gates
                                every um_user_modify call

CODE RED: every file/path error logs the EXACT path + the failure reason.
EOF
}

UM_NAME=""
UM_NEW_NAME=""
UM_NEW_PASSWORD=""
UM_PASSWORD_FILE=""
UM_PROMOTE=0
UM_DEMOTE=0
UM_ADD_GROUPS=""
UM_REMOVE_GROUPS=""
UM_NEW_SHELL=""
UM_NEW_COMMENT=""
UM_NEW_COMMENT_SET=0
UM_ENABLE=0
UM_DISABLE=0
UM_ASK=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         um_usage; exit 0 ;;
    --rename)          UM_NEW_NAME="${2:-}"; shift 2 ;;
    --reset-password)  UM_NEW_PASSWORD="${2:-}"; shift 2 ;;
    --password-file)   UM_PASSWORD_FILE="${2:-}"; shift 2 ;;
    --promote)         UM_PROMOTE=1; shift ;;
    --demote)          UM_DEMOTE=1; shift ;;
    --add-group)
        if [ -z "$UM_ADD_GROUPS" ]; then UM_ADD_GROUPS="${2:-}"
        else UM_ADD_GROUPS="$UM_ADD_GROUPS,${2:-}"; fi
        shift 2 ;;
    --remove-group)
        if [ -z "$UM_REMOVE_GROUPS" ]; then UM_REMOVE_GROUPS="${2:-}"
        else UM_REMOVE_GROUPS="$UM_REMOVE_GROUPS,${2:-}"; fi
        shift 2 ;;
    --shell)           UM_NEW_SHELL="${2:-}"; shift 2 ;;
    --comment)         UM_NEW_COMMENT="${2:-}"; UM_NEW_COMMENT_SET=1; shift 2 ;;
    --enable)          UM_ENABLE=1; shift ;;
    --disable)         UM_DISABLE=1; shift ;;
    --ask)             UM_ASK=1; shift ;;
    --dry-run)         UM_DRY_RUN=1; shift ;;
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

# --ask: fill any missing required fields interactively.
if [ "$UM_ASK" = "1" ]; then
  if command -v um_prompt_string >/dev/null 2>&1; then
    [ -z "$UM_NAME" ] && UM_NAME=$(um_prompt_string "Username to edit" "" 1)
    rn=$(um_prompt_string "Rename to (blank = keep)" "" 0)
    [ -n "$rn" ] && UM_NEW_NAME="$rn"
    if um_prompt_confirm "Reset password?" 0; then
      UM_NEW_PASSWORD=$(um_prompt_secret "New password" 1)
    fi
    role=$(um_prompt_string "Role change [promote/demote/none]" "none" 0)
    case "$role" in promote*|Promote*|PROMOTE*) UM_PROMOTE=1 ;; demote*|Demote*|DEMOTE*) UM_DEMOTE=1 ;; esac
  else
    log_err "--ask requested but helpers/_prompt.sh is missing (failure: cannot prompt)"
    exit 1
  fi
fi

if [ -z "$UM_NAME" ]; then
  log_err "missing required <name> (failure: nothing to edit)"
  um_usage; exit 64
fi
if [ "$UM_PROMOTE" = "1" ] && [ "$UM_DEMOTE" = "1" ]; then
  log_err "cannot use --promote and --demote together (failure: pick one)"
  exit 64
fi
if [ "$UM_ENABLE" = "1" ] && [ "$UM_DISABLE" = "1" ]; then
  log_err "cannot use --enable and --disable together (failure: pick one)"
  exit 64
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

# Sudo group choice mirrors add-user.sh.
if [ "$UM_OS" = "macos" ]; then UM_SUDO_GROUP="admin"; else UM_SUDO_GROUP="sudo"; fi
[ "$UM_PROMOTE" = "1" ] && UM_ADD_GROUPS="${UM_ADD_GROUPS:+$UM_ADD_GROUPS,}$UM_SUDO_GROUP"
[ "$UM_DEMOTE"  = "1" ] && UM_REMOVE_GROUPS="${UM_REMOVE_GROUPS:+$UM_REMOVE_GROUPS,}$UM_SUDO_GROUP"

# Plan summary (always print so dry-run + real-run agree on intent).
plan=()
[ -n "$UM_NEW_NAME" ]      && plan+=("rename '$UM_NAME' -> '$UM_NEW_NAME'")
[ -n "$UM_NEW_PASSWORD" ] || [ -n "$UM_PASSWORD_FILE" ] && plan+=("reset password")
[ "$UM_PROMOTE" = "1" ]    && plan+=("promote (add to '$UM_SUDO_GROUP')")
[ "$UM_DEMOTE"  = "1" ]    && plan+=("demote (remove from '$UM_SUDO_GROUP')")
[ -n "$UM_ADD_GROUPS" ]    && plan+=("add groups: $UM_ADD_GROUPS")
[ -n "$UM_REMOVE_GROUPS" ] && plan+=("remove groups: $UM_REMOVE_GROUPS")
[ -n "$UM_NEW_SHELL" ]     && plan+=("set shell: $UM_NEW_SHELL")
[ "$UM_NEW_COMMENT_SET" = "1" ] && plan+=("set comment: '$UM_NEW_COMMENT'")
[ "$UM_ENABLE" = "1" ]     && plan+=("enable account")
[ "$UM_DISABLE" = "1" ]    && plan+=("disable account")
if [ "${#plan[@]}" -eq 0 ]; then
  log_warn "no changes requested -- pass at least one flag (use --help for the list)"
  exit 0
fi

log_info "$(um_msg editPlanHeader "$UM_NAME")"
for p in "${plan[@]}"; do log_info "  - $p"; done

if ! um_user_exists "$UM_NAME"; then
  log_err "$(um_msg editUserMissing "$UM_NAME")"
  um_summary_add "fail" "user" "$UM_NAME" "missing"
  exit 1
fi

# Resolve password if either source given.
if [ -n "$UM_NEW_PASSWORD" ] || [ -n "$UM_PASSWORD_FILE" ]; then
  UM_PASSWORD_CLI="$UM_NEW_PASSWORD"
  um_resolve_password || exit $?
  UM_NEW_PASSWORD="$UM_RESOLVED_PASSWORD"
fi

rc_overall=0

# All operations now go through the shared um_user_modify helper in
# helpers/_common.sh. Each call returns 0/1/2 -- we OR into rc_overall so a
# single failed op does not abort the rest of the plan (matches the previous
# best-effort semantics that the JSON loader relies on).

# ---- password reset --------------------------------------------------------
if [ -n "$UM_NEW_PASSWORD" ]; then
  um_user_modify "$UM_NAME" password "$UM_NEW_PASSWORD" || rc_overall=1
fi

# ---- shell / comment / enable / disable ------------------------------------
[ -n "$UM_NEW_SHELL" ] && { um_user_modify "$UM_NAME" shell   "$UM_NEW_SHELL"   || rc_overall=1; }
[ "$UM_NEW_COMMENT_SET" = "1" ] && { um_user_modify "$UM_NAME" comment "$UM_NEW_COMMENT" || rc_overall=1; }
[ "$UM_ENABLE"  = "1" ] && { um_user_modify "$UM_NAME" enable  || rc_overall=1; }
[ "$UM_DISABLE" = "1" ] && { um_user_modify "$UM_NAME" disable || rc_overall=1; }

# ---- supplementary group changes ------------------------------------------
if [ -n "$UM_ADD_GROUPS" ]; then
  IFS=',' read -ra _ag <<< "$UM_ADD_GROUPS"
  for g in "${_ag[@]}"; do
    g="${g// /}"; [ -z "$g" ] && continue
    um_user_modify "$UM_NAME" add-group "$g" || rc_overall=1
  done
fi
if [ -n "$UM_REMOVE_GROUPS" ]; then
  IFS=',' read -ra _rg <<< "$UM_REMOVE_GROUPS"
  for g in "${_rg[@]}"; do
    g="${g// /}"; [ -z "$g" ] && continue
    um_user_modify "$UM_NAME" rm-group "$g" || rc_overall=1
  done
fi

# ---- rename (do LAST so all other ops referenced the original name) -------
if [ -n "$UM_NEW_NAME" ]; then
  um_user_modify "$UM_NAME" rename "$UM_NEW_NAME" || rc_overall=1
fi

if [ "$rc_overall" -eq 0 ]; then
  um_summary_add "ok" "edit-user" "$UM_NAME" "${#plan[@]} change(s) applied"
else
  um_summary_add "fail" "edit-user" "$UM_NAME" "one or more changes failed"
fi
exit $rc_overall
