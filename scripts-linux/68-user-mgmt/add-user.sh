#!/usr/bin/env bash
# 68-user-mgmt/add-user.sh -- create a single local user (Linux | macOS).
#
# Usage:
#   ./add-user.sh <name> [--password PW | --password-file FILE]
#                        [--uid N] [--primary-group G] [--groups g1,g2,...]
#                        [--shell PATH] [--home PATH] [--comment "..."]
#                        [--sudo] [--system] [--dry-run]
#
# Notes:
#   - Idempotent: re-running on an existing user only adjusts membership +
#     password (still skips create).
#   - Plain --password is accepted to mirror the Windows side; prefer
#     --password-file (mode 0600) for any account that outlives a demo.
#   - Passwords are NEVER written to log files. Console echo is masked.
#   - CODE RED: every file/path error logs the EXACT path + reason.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

um_usage() {
  cat <<EOF
Usage: add-user.sh <name> [options]

Required:
  <name>                       login name

Password (pick at most one):
  --password PW                plain text (logged masked; visible in shell history)
  --password-file FILE         file mode must be 0600 or stricter

Optional:
  --uid N                      explicit numeric UID
  --primary-group G            primary group (created if missing on Linux; must exist on macOS)
  --groups g1,g2,...           supplementary groups (comma-separated)
  --shell PATH                 login shell (default: /bin/bash on Linux, /bin/zsh on macOS)
  --home  PATH                 home directory (default: /home/<name> | /Users/<name>)
  --comment "..."              GECOS / RealName
  --sudo                       add to sudo group (Linux: 'sudo', macOS: 'admin')
  --system                     create system account (Linux only; ignored on macOS)
  --dry-run                    print what would happen, change nothing
EOF
}

# ---- arg parse --------------------------------------------------------------
UM_NAME=""
UM_PASSWORD_CLI=""
UM_PASSWORD_FILE=""
UM_UID=""
UM_PRIMARY_GROUP=""
UM_GROUPS=""
UM_SHELL=""
UM_HOME=""
UM_COMMENT=""
UM_SUDO=0
UM_SYSTEM=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         um_usage; exit 0 ;;
    --password)        UM_PASSWORD_CLI="${2:-}"; shift 2 ;;
    --password-file)   UM_PASSWORD_FILE="${2:-}"; shift 2 ;;
    --uid)             UM_UID="${2:-}"; shift 2 ;;
    --primary-group)   UM_PRIMARY_GROUP="${2:-}"; shift 2 ;;
    --groups)          UM_GROUPS="${2:-}"; shift 2 ;;
    --shell)           UM_SHELL="${2:-}"; shift 2 ;;
    --home)            UM_HOME="${2:-}"; shift 2 ;;
    --comment)         UM_COMMENT="${2:-}"; shift 2 ;;
    --sudo)            UM_SUDO=1; shift ;;
    --system)          UM_SYSTEM=1; shift ;;
    --dry-run)         UM_DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*)
      log_err "unknown option: '$1' (failure: see --help)"
      exit 64
      ;;
    *)
      if [ -z "$UM_NAME" ]; then UM_NAME="$1"; shift
      else log_err "unexpected positional: '$1' (failure: only <name> is positional)"; exit 64; fi
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

# Defaults per OS.
if [ "$UM_OS" = "macos" ]; then
  : "${UM_SHELL:=/bin/zsh}"
  : "${UM_HOME:=/Users/$UM_NAME}"
  : "${UM_PRIMARY_GROUP:=staff}"
  UM_SUDO_GROUP="admin"
else
  : "${UM_SHELL:=/bin/bash}"
  : "${UM_HOME:=/home/$UM_NAME}"
  : "${UM_PRIMARY_GROUP:=$UM_NAME}"  # Linux convention: per-user primary group
  UM_SUDO_GROUP="sudo"
fi

# Resolve password (sets UM_RESOLVED_PASSWORD).
um_resolve_password || exit $?
UM_MASKED_PW=$(um_mask_password "$UM_RESOLVED_PASSWORD")

# ---- create user ------------------------------------------------------------
if um_user_exists "$UM_NAME"; then
  log_warn "$(um_msg userExists "$UM_NAME")"
  um_summary_add "skip" "user" "$UM_NAME" "exists"
else
  if [ "$UM_OS" = "linux" ]; then
    args=(useradd)
    [ "$UM_SYSTEM" = "1" ] && args+=(--system)
    args+=(--shell "$UM_SHELL")
    args+=(--home-dir "$UM_HOME")
    args+=(--create-home)
    [ -n "$UM_UID" ]     && args+=(--uid "$UM_UID")
    [ -n "$UM_COMMENT" ] && args+=(--comment "$UM_COMMENT")
    # primary group: create per-user group if it doesn't exist
    if [ "$UM_PRIMARY_GROUP" = "$UM_NAME" ]; then
      args+=(--user-group)
    else
      if ! um_group_exists "$UM_PRIMARY_GROUP"; then
        um_run groupadd "$UM_PRIMARY_GROUP" \
          || { log_err "$(um_msg groupCreateFail "$UM_PRIMARY_GROUP" "groupadd failed")"; exit 1; }
      fi
      args+=(--gid "$UM_PRIMARY_GROUP")
    fi
    args+=("$UM_NAME")

    if um_run "${args[@]}"; then
      created_uid=$(id -u "$UM_NAME" 2>/dev/null || echo "?")
      log_ok "$(um_msg userCreated "$UM_NAME" "$created_uid" "$UM_PRIMARY_GROUP")"
      um_summary_add "ok" "user" "$UM_NAME" "uid=$created_uid"
    else
      log_err "$(um_msg userCreateFail "$UM_NAME" "useradd returned non-zero")"
      um_summary_add "fail" "user" "$UM_NAME" "useradd failed"
      exit 1
    fi

  else  # macos
    if [ -z "$UM_UID" ]; then UM_UID=$(um_next_macos_uid 510); fi
    # Resolve primary group GID (must exist).
    pg_gid=$(dscl . -read "/Groups/$UM_PRIMARY_GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}')
    if [ -z "$pg_gid" ]; then
      log_err "primary group '$UM_PRIMARY_GROUP' not found on macOS (failure: create it first or pick 'staff')"
      exit 1
    fi
    um_run dscl . -create "/Users/$UM_NAME"                                     || { log_err "$(um_msg userCreateFail "$UM_NAME" "dscl create failed")"; exit 1; }
    um_run dscl . -create "/Users/$UM_NAME" UserShell      "$UM_SHELL"          || true
    um_run dscl . -create "/Users/$UM_NAME" RealName       "${UM_COMMENT:-$UM_NAME}" || true
    um_run dscl . -create "/Users/$UM_NAME" UniqueID       "$UM_UID"            || true
    um_run dscl . -create "/Users/$UM_NAME" PrimaryGroupID "$pg_gid"            || true
    um_run dscl . -create "/Users/$UM_NAME" NFSHomeDirectory "$UM_HOME"         || true
    if [ "$UM_DRY_RUN" != "1" ] && [ ! -d "$UM_HOME" ]; then
      um_run mkdir -p "$UM_HOME" \
        || log_file_error "$UM_HOME" "could not create home dir"
      um_run chown "$UM_NAME:$pg_gid" "$UM_HOME" 2>/dev/null || true
    fi
    log_ok "$(um_msg userCreated "$UM_NAME" "$UM_UID" "$UM_PRIMARY_GROUP")"
    um_summary_add "ok" "user" "$UM_NAME" "uid=$UM_UID"
  fi
fi

# ---- supplementary groups ---------------------------------------------------
UM_GROUP_LIST=""
if [ -n "$UM_GROUPS" ]; then UM_GROUP_LIST="$UM_GROUPS"; fi
if [ "$UM_SUDO" = "1" ]; then
  if [ -z "$UM_GROUP_LIST" ]; then UM_GROUP_LIST="$UM_SUDO_GROUP"
  else UM_GROUP_LIST="$UM_GROUP_LIST,$UM_SUDO_GROUP"; fi
fi

if [ -n "$UM_GROUP_LIST" ]; then
  IFS=',' read -ra _grps <<< "$UM_GROUP_LIST"
  for g in "${_grps[@]}"; do
    g="${g// /}"
    [ -z "$g" ] && continue
    if ! um_group_exists "$g"; then
      log_warn "group '$g' does not exist -- creating it (failure to create will abort)"
      if [ "$UM_OS" = "linux" ]; then
        um_run groupadd "$g" || { log_err "$(um_msg groupCreateFail "$g" "groupadd failed")"; exit 1; }
      else
        next_gid=$(um_next_macos_gid 510)
        um_run dscl . -create "/Groups/$g"                              || true
        um_run dscl . -create "/Groups/$g" PrimaryGroupID "$next_gid"   || true
      fi
    fi
    if [ "$UM_OS" = "linux" ]; then
      if um_run usermod -aG "$g" "$UM_NAME"; then
        log_ok "$(um_msg groupAdded "$UM_NAME" "$g")"
      else
        log_err "$(um_msg groupAddFail "$UM_NAME" "$g" "usermod -aG failed")"
      fi
    else
      if um_run dscl . -append "/Groups/$g" GroupMembership "$UM_NAME"; then
        log_ok "$(um_msg groupAdded "$UM_NAME" "$g")"
      else
        log_err "$(um_msg groupAddFail "$UM_NAME" "$g" "dscl append failed")"
      fi
    fi
  done
fi

# ---- password ---------------------------------------------------------------
if [ -n "$UM_RESOLVED_PASSWORD" ]; then
  if [ "$UM_OS" = "linux" ]; then
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] chpasswd <<< '$UM_NAME:<masked>'"
    else
      if printf '%s:%s\n' "$UM_NAME" "$UM_RESOLVED_PASSWORD" | chpasswd 2>/dev/null; then
        log_ok "$(um_msg passwordSet "$UM_NAME" "$UM_MASKED_PW")"
      else
        log_err "$(um_msg passwordSetFail "$UM_NAME" "chpasswd failed")"
      fi
    fi
  else  # macos
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] dscl . -passwd /Users/$UM_NAME <masked>"
    else
      if dscl . -passwd "/Users/$UM_NAME" "$UM_RESOLVED_PASSWORD" 2>/dev/null; then
        log_ok "$(um_msg passwordSet "$UM_NAME" "$UM_MASKED_PW")"
      else
        log_err "$(um_msg passwordSetFail "$UM_NAME" "dscl -passwd failed")"
      fi
    fi
  fi
fi

# ---- console summary (masked) ----------------------------------------------
printf '\n'
printf '  User         : %s\n' "$UM_NAME"
printf '  OS           : %s\n' "$UM_OS"
printf '  Shell        : %s\n' "$UM_SHELL"
printf '  Home         : %s\n' "$UM_HOME"
printf '  Primary group: %s\n' "$UM_PRIMARY_GROUP"
if [ -n "$UM_GROUP_LIST" ]; then printf '  Extra groups : %s\n' "$UM_GROUP_LIST"; fi
if [ -n "$UM_RESOLVED_PASSWORD" ]; then
  printf '  Password     : %s  (passed via CLI/JSON -- never logged)\n' "$UM_MASKED_PW"
fi
printf '\n'