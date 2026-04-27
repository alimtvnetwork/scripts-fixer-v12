#!/usr/bin/env bash
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

um_usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

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

# ---- password reset --------------------------------------------------------
if [ -n "$UM_NEW_PASSWORD" ]; then
  masked=$(um_mask_password "$UM_NEW_PASSWORD")
  if [ "$UM_OS" = "linux" ]; then
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] chpasswd <<< '$UM_NAME:<masked>'"
    else
      if printf '%s:%s\n' "$UM_NAME" "$UM_NEW_PASSWORD" | chpasswd 2>/dev/null; then
        log_ok "$(um_msg passwordSet "$UM_NAME" "$masked")"
      else
        log_err "$(um_msg passwordSetFail "$UM_NAME" "chpasswd failed")"
        rc_overall=1
      fi
    fi
  else
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] dscl . -passwd /Users/$UM_NAME <masked>"
    else
      if dscl . -passwd "/Users/$UM_NAME" "$UM_NEW_PASSWORD" 2>/dev/null; then
        log_ok "$(um_msg passwordSet "$UM_NAME" "$masked")"
      else
        log_err "$(um_msg passwordSetFail "$UM_NAME" "dscl -passwd failed")"
        rc_overall=1
      fi
    fi
  fi
fi

# ---- shell change ----------------------------------------------------------
if [ -n "$UM_NEW_SHELL" ]; then
  if [ "$UM_OS" = "linux" ]; then
    if um_run usermod -s "$UM_NEW_SHELL" "$UM_NAME"; then
      log_ok "$(um_msg shellChanged "$UM_NAME" "$UM_NEW_SHELL")"
    else
      log_err "$(um_msg shellChangeFail "$UM_NAME" "$UM_NEW_SHELL" "usermod -s failed")"; rc_overall=1
    fi
  else
    if um_run dscl . -create "/Users/$UM_NAME" UserShell "$UM_NEW_SHELL"; then
      log_ok "$(um_msg shellChanged "$UM_NAME" "$UM_NEW_SHELL")"
    else
      log_err "$(um_msg shellChangeFail "$UM_NAME" "$UM_NEW_SHELL" "dscl -create UserShell failed")"; rc_overall=1
    fi
  fi
fi

# ---- comment / GECOS / RealName -------------------------------------------
if [ "$UM_NEW_COMMENT_SET" = "1" ]; then
  if [ "$UM_OS" = "linux" ]; then
    if um_run usermod -c "$UM_NEW_COMMENT" "$UM_NAME"; then
      log_ok "$(um_msg commentChanged "$UM_NAME")"
    else
      log_err "$(um_msg commentChangeFail "$UM_NAME" "usermod -c failed")"; rc_overall=1
    fi
  else
    if um_run dscl . -create "/Users/$UM_NAME" RealName "$UM_NEW_COMMENT"; then
      log_ok "$(um_msg commentChanged "$UM_NAME")"
    else
      log_err "$(um_msg commentChangeFail "$UM_NAME" "dscl -create RealName failed")"; rc_overall=1
    fi
  fi
fi

# ---- enable / disable ------------------------------------------------------
if [ "$UM_ENABLE" = "1" ]; then
  if [ "$UM_OS" = "linux" ]; then
    if um_run usermod -U "$UM_NAME"; then
      log_ok "$(um_msg accountEnabled "$UM_NAME")"
    else
      log_err "$(um_msg accountEnableFail "$UM_NAME" "usermod -U failed")"; rc_overall=1
    fi
  else
    if um_run pwpolicy -u "$UM_NAME" -enableuser; then
      log_ok "$(um_msg accountEnabled "$UM_NAME")"
    else
      log_err "$(um_msg accountEnableFail "$UM_NAME" "pwpolicy -enableuser failed")"; rc_overall=1
    fi
  fi
fi
if [ "$UM_DISABLE" = "1" ]; then
  if [ "$UM_OS" = "linux" ]; then
    if um_run usermod -L "$UM_NAME"; then
      log_ok "$(um_msg accountDisabled "$UM_NAME")"
    else
      log_err "$(um_msg accountDisableFail "$UM_NAME" "usermod -L failed")"; rc_overall=1
    fi
  else
    if um_run pwpolicy -u "$UM_NAME" -disableuser; then
      log_ok "$(um_msg accountDisabled "$UM_NAME")"
    else
      log_err "$(um_msg accountDisableFail "$UM_NAME" "pwpolicy -disableuser failed")"; rc_overall=1
    fi
  fi
fi

# ---- supplementary group changes ------------------------------------------
_apply_group_change() {
  local action="$1" g="$2"
  if ! um_group_exists "$g"; then
    if [ "$action" = "remove" ]; then
      log_info "group '$g' does not exist -- skipping remove (idempotent)"
      return 0
    fi
    log_warn "group '$g' does not exist -- creating it"
    if [ "$UM_OS" = "linux" ]; then
      um_run groupadd "$g" || { log_err "$(um_msg groupCreateFail "$g" "groupadd failed")"; return 1; }
    else
      next_gid=$(um_next_macos_gid 510)
      um_run dscl . -create "/Groups/$g" || true
      um_run dscl . -create "/Groups/$g" PrimaryGroupID "$next_gid" || true
    fi
  fi
  if [ "$UM_OS" = "linux" ]; then
    if [ "$action" = "add" ]; then
      um_run usermod -aG "$g" "$UM_NAME" \
        && log_ok "$(um_msg groupAdded "$UM_NAME" "$g")" \
        || { log_err "$(um_msg groupAddFail "$UM_NAME" "$g" "usermod -aG failed")"; return 1; }
    else
      um_run gpasswd -d "$UM_NAME" "$g" \
        && log_ok "$(um_msg groupRemoved "$UM_NAME" "$g")" \
        || { log_err "$(um_msg groupRemoveFail "$UM_NAME" "$g" "gpasswd -d failed")"; return 1; }
    fi
  else
    if [ "$action" = "add" ]; then
      um_run dscl . -append "/Groups/$g" GroupMembership "$UM_NAME" \
        && log_ok "$(um_msg groupAdded "$UM_NAME" "$g")" \
        || { log_err "$(um_msg groupAddFail "$UM_NAME" "$g" "dscl -append failed")"; return 1; }
    else
      um_run dscl . -delete "/Groups/$g" GroupMembership "$UM_NAME" \
        && log_ok "$(um_msg groupRemoved "$UM_NAME" "$g")" \
        || { log_err "$(um_msg groupRemoveFail "$UM_NAME" "$g" "dscl -delete failed")"; return 1; }
    fi
  fi
}

if [ -n "$UM_ADD_GROUPS" ]; then
  IFS=',' read -ra _ag <<< "$UM_ADD_GROUPS"
  for g in "${_ag[@]}"; do
    g="${g// /}"; [ -z "$g" ] && continue
    _apply_group_change add "$g" || rc_overall=1
  done
fi
if [ -n "$UM_REMOVE_GROUPS" ]; then
  IFS=',' read -ra _rg <<< "$UM_REMOVE_GROUPS"
  for g in "${_rg[@]}"; do
    g="${g// /}"; [ -z "$g" ] && continue
    _apply_group_change remove "$g" || rc_overall=1
  done
fi

# ---- rename (do LAST so all other ops referenced the original name) -------
if [ -n "$UM_NEW_NAME" ]; then
  if um_user_exists "$UM_NEW_NAME"; then
    log_err "$(um_msg renameTargetExists "$UM_NEW_NAME")"
    rc_overall=1
  else
    if [ "$UM_OS" = "linux" ]; then
      if um_run usermod -l "$UM_NEW_NAME" "$UM_NAME"; then
        log_ok "$(um_msg userRenamed "$UM_NAME" "$UM_NEW_NAME")"
        um_summary_add "ok" "user" "$UM_NAME" "renamed -> $UM_NEW_NAME"
      else
        log_err "$(um_msg renameFail "$UM_NAME" "$UM_NEW_NAME" "usermod -l failed")"; rc_overall=1
      fi
    else
      if um_run dscl . -change "/Users/$UM_NAME" RecordName "$UM_NAME" "$UM_NEW_NAME"; then
        log_ok "$(um_msg userRenamed "$UM_NAME" "$UM_NEW_NAME")"
        um_summary_add "ok" "user" "$UM_NAME" "renamed -> $UM_NEW_NAME"
      else
        log_err "$(um_msg renameFail "$UM_NAME" "$UM_NEW_NAME" "dscl -change RecordName failed")"; rc_overall=1
      fi
    fi
  fi
fi

if [ "$rc_overall" -eq 0 ]; then
  um_summary_add "ok" "edit-user" "$UM_NAME" "${#plan[@]} change(s) applied"
else
  um_summary_add "fail" "edit-user" "$UM_NAME" "one or more changes failed"
fi
exit $rc_overall
