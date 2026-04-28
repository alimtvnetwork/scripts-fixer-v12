#!/usr/bin/env bash
# Shared helpers for 68-user-mgmt leaves.
#
# Sourced by every leaf script (add-user.sh, add-group.sh, add-user-from-json.sh,
# add-group-from-json.sh) AND by the root run.sh dispatcher. Pure bash, no
# external deps beyond coreutils + the OS-native user-management tools
# (useradd/groupadd on Linux, dscl on macOS).
#
# CODE RED rule: every file/path error MUST be reported with the EXACT
# path + a human-readable failure reason via log_file_error.

# ---- guard: only source once ------------------------------------------------
if [ "${__USERMGMT_COMMON_LOADED:-0}" = "1" ]; then return 0; fi
__USERMGMT_COMMON_LOADED=1

# Resolve toolkit root (../..) so we can pull in shared logger + file-error
# helpers no matter how the leaf was invoked.
__UM_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__UM_SCRIPT_DIR="$(cd "$__UM_HELPERS_DIR/.." && pwd)"
__UM_TOOLKIT_ROOT="$(cd "$__UM_SCRIPT_DIR/.." && pwd)"

export SCRIPT_ID="${SCRIPT_ID:-68}"

# Source shared logger + file-error if not already loaded by the caller.
if ! command -v log_info >/dev/null 2>&1; then
  . "$__UM_TOOLKIT_ROOT/_shared/logger.sh"
fi
if ! command -v log_file_error >/dev/null 2>&1; then
  # log_file_error is defined inside logger.sh; this branch only fires
  # if a future refactor splits them.
  . "$__UM_TOOLKIT_ROOT/_shared/logger.sh"
fi
if ! command -v ensure_dir >/dev/null 2>&1; then
  . "$__UM_TOOLKIT_ROOT/_shared/file-error.sh"
fi
if ! command -v write_install_paths >/dev/null 2>&1; then
  . "$__UM_TOOLKIT_ROOT/_shared/install-paths.sh"
fi

# Load log message catalogue once. Use jq if available; otherwise fall back to
# a tiny grep-based extractor so the leaves still produce sensible output on
# very minimal hosts (e.g. fresh containers without jq installed yet).
__UM_LOG_JSON="$__UM_SCRIPT_DIR/log-messages.json"

um_msg() {
  # Usage: um_msg <key> [printf-args...]
  # Returns the formatted message on stdout. Unknown keys fall back to the
  # raw key name so missing translations are visible rather than silent.
  local key="$1"; shift || true
  local tmpl=""
  if [ -f "$__UM_LOG_JSON" ]; then
    if command -v jq >/dev/null 2>&1; then
      tmpl=$(jq -r --arg k "$key" '.messages[$k] // empty' "$__UM_LOG_JSON" 2>/dev/null)
    else
      # Best-effort sed extractor: matches "key": "value" on a single line.
      tmpl=$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\(.*\)\".*/\1/p" "$__UM_LOG_JSON" | head -1)
    fi
  fi
  if [ -z "$tmpl" ]; then tmpl="$key"; fi
  # shellcheck disable=SC2059
  printf "$tmpl" "$@"
}

# ---- OS detection -----------------------------------------------------------
# Sets UM_OS to 'linux' or 'macos'. Anything else -> exit 2 with exact uname
# output recorded so the operator knows what was seen.
um_detect_os() {
  local kernel
  kernel=$(uname -s 2>/dev/null || echo "")
  case "$kernel" in
    Linux)  UM_OS=linux ;;
    Darwin) UM_OS=macos ;;
    *)
      log_err "$(um_msg osDetectFail "$kernel")"
      return 2
      ;;
  esac
  export UM_OS
  return 0
}

# ---- root check -------------------------------------------------------------
# All real (non-dry-run) operations need root. We don't auto-sudo; we tell
# the operator exactly why and exit non-zero.
um_require_root() {
  if [ "${UM_DRY_RUN:-0}" = "1" ]; then return 0; fi
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  log_err "$(um_msg needRoot)"
  return 0
}

# ---- password resolution ----------------------------------------------------
# Three sources, in priority order:
#   1. --password-file FILE  (must exist and be mode 0600 or stricter)
#   2. UM_PASSWORD env var   (set by JSON loader from "password" field)
#   3. --password VALUE      (plain CLI; mirrors Windows risk decision)
# Sets UM_RESOLVED_PASSWORD on success. Empty password -> account is created
# without a password (locked); not a failure.
um_resolve_password() {
  UM_RESOLVED_PASSWORD=""
  local pw_file="${UM_PASSWORD_FILE:-}"
  local pw_env="${UM_PASSWORD:-}"
  local pw_cli="${UM_PASSWORD_CLI:-}"

  if [ -n "$pw_file" ]; then
    if [ ! -f "$pw_file" ]; then
      log_file_error "$pw_file" "password file not found"
      return 2
    fi
    # Mode check: must be 0600 or stricter (no group/other bits).
    local mode
    mode=$(stat -c '%a' "$pw_file" 2>/dev/null || stat -f '%Lp' "$pw_file" 2>/dev/null)
    case "$mode" in
      400|600|0400|0600|"") : ;;  # accept; empty mode = stat unsupported, allow
      *)
        log_err "$(um_msg passwordFileBadMode "$pw_file" "$mode")"
        return 2
        ;;
    esac
    UM_RESOLVED_PASSWORD=$(head -n1 "$pw_file" 2>/dev/null)
    return 0
  fi

  if [ -n "$pw_env" ]; then
    UM_RESOLVED_PASSWORD="$pw_env"
    return 0
  fi

  if [ -n "$pw_cli" ]; then
    UM_RESOLVED_PASSWORD="$pw_cli"
    return 0
  fi

  return 0  # no password -> account locked, that's fine
}

# Mask a password for safe console display. NEVER write the unmasked form
# to log files -- callers must use this helper for any console echo.
um_mask_password() {
  local pw="$1"
  local n=${#pw}
  if [ "$n" -eq 0 ]; then printf '<none>'; return 0; fi
  local cap=8
  if [ "$n" -lt "$cap" ]; then cap="$n"; fi
  local i=0
  while [ "$i" -lt "$cap" ]; do printf '*'; i=$((i+1)); done
}

# ---- existence probes (idempotent, cross-OS) -------------------------------
um_user_exists() {
  local name="$1"
  if [ "$UM_OS" = "macos" ]; then
    dscl . -read "/Users/$name" >/dev/null 2>&1
  else
    id -u "$name" >/dev/null 2>&1
  fi
}

um_group_exists() {
  local name="$1"
  if [ "$UM_OS" = "macos" ]; then
    dscl . -read "/Groups/$name" >/dev/null 2>&1
  else
    getent group "$name" >/dev/null 2>&1
  fi
}

# ---- macOS uid allocator ----------------------------------------------------
# macOS dscl needs an explicit numeric UID. We pick the next free uid >= start.
um_next_macos_uid() {
  local start="${1:-510}"
  local used candidate
  used=$(dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | sort -n)
  candidate="$start"
  while echo "$used" | grep -qx "$candidate"; do
    candidate=$((candidate+1))
  done
  printf '%s' "$candidate"
}

um_next_macos_gid() {
  local start="${1:-510}"
  local used candidate
  used=$(dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '{print $2}' | sort -n)
  candidate="$start"
  while echo "$used" | grep -qx "$candidate"; do
    candidate=$((candidate+1))
  done
  printf '%s' "$candidate"
}

# ---- numeric primary GID resolver (cross-OS, v0.174.0) ----------------------
# Returns the numeric primary GID for an existing user. We need the NUMERIC
# value (not the group name) for chown on macOS, where directory-services
# group names occasionally drift from /etc/group entries and chown by name
# can fail with "invalid group" even though the user exists.
#
# Resolution order:
#   1. `id -g <user>`           -- works on Linux + macOS for any real user
#   2. macOS dscl PrimaryGroupID -- fallback when getpwnam is racy after
#                                   a fresh dscl -create
# Echoes the numeric gid on stdout, or empty string on failure.
um_resolve_pg_gid() {
  local user="$1"
  local gid=""
  gid=$(id -g "$user" 2>/dev/null)
  if [ -z "$gid" ] && [ "${UM_OS:-}" = "macos" ]; then
    gid=$(dscl . -read "/Users/$user" PrimaryGroupID 2>/dev/null \
          | awk '/^PrimaryGroupID:/ {print $2}')
  fi
  printf '%s' "$gid"
}

# ---- macOS home seeder (v0.174.0) -------------------------------------------
# After `dscl . -create /Users/<n> NFSHomeDirectory ...` the home dir
# does NOT exist on disk. Apple's documented one-liner is:
#     createhomedir -c -u <name>
# which materialises the dir, copies the User Template (~/Library skeleton),
# and sets owner=<user>:<gid> mode=0755 the way the Setup Assistant would.
#
# This function does that, with a graceful fallback for stripped-down hosts
# (CI runners, restored Time Machine images) where createhomedir was pruned:
# we mkdir + chown numerically + chmod 0755, log a warning so the operator
# knows the ~/Library skeleton is missing, and keep going.
#
# Args: <user> <home-dir> <numeric-gid>
# Returns 0 on success (incl. fallback path), 1 only on hard write failure.
um_seed_macos_home() {
  local user="$1" home="$2" gid="$3"
  if [ "${UM_DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] createhomedir -c -u '$user'  (would seed '$home' owner $user:$gid mode 0755)"
    return 0
  fi

  if command -v createhomedir >/dev/null 2>&1; then
    # createhomedir prints to stderr on failure; capture it for CODE RED.
    local out rc=0
    out=$(createhomedir -c -u "$user" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -d "$home" ]; then
      log_err "$(um_msg macHomeSeedFail "$home" "$user" "createhomedir rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)" "$user")"
      return 1
    fi
    # createhomedir already chowns/chmods correctly, but re-assert to be
    # defensive against a pre-existing $home with wrong perms.
    chown "$user:$gid" "$home" 2>/dev/null || true
    chmod 0755 "$home" 2>/dev/null         || true
    log_ok "$(um_msg macHomeSeeded "$home" "$user" "$user" "$gid")"
    return 0
  fi

  # Fallback: bare dir + manual perms. ~/Library skeleton is missing so
  # GUI apps may complain, but ssh + shell login will work.
  if ! mkdir -p "$home" 2>/dev/null; then
    log_file_error "$home" "could not create macOS home dir (createhomedir absent)"
    return 1
  fi
  chmod 0755 "$home" 2>/dev/null \
    || log_file_error "$home" "could not chmod 0755 on macOS home"
  if ! chown "$user:$gid" "$home" 2>/dev/null; then
    log_file_error "$home" "could not chown to $user:$gid (macOS fallback)"
    return 1
  fi
  log_warn "$(um_msg macHomeSeededFallback "$home" "$user" "$user" "$gid")"
  return 0
}

# ---- dry-run shim -----------------------------------------------------------
# Wrap any state-mutating command. When UM_DRY_RUN=1 we just log the intent.
um_run() {
  if [ "${UM_DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ---- summary collector ------------------------------------------------------
# Append a row "<status>\t<kind>\t<name>\t<detail>" to UM_SUMMARY_FILE so the
# JSON-batch leaves can print a single roll-up table at the end.
um_summary_add() {
  local status="$1" kind="$2" name="$3" detail="${4:-}"
  if [ -z "${UM_SUMMARY_FILE:-}" ]; then return 0; fi
  printf '%s\t%s\t%s\t%s\n' "$status" "$kind" "$name" "$detail" >> "$UM_SUMMARY_FILE"
}

um_summary_print() {
  local f="${UM_SUMMARY_FILE:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then return 0; fi
  log_info "$(um_msg summaryHeader)"
  while IFS=$'\t' read -r status kind name detail; do
    log_info "$(um_msg summaryRow "[$status]" "$kind" "$name $detail")"
  done < "$f"
}

# ---- user modify / delete / purge-home (shared leaf helpers) ---------------
# These are extracted so the new edit-user / remove-user JSON loaders, the
# orchestrate.sh fan-out, and any future leaf can apply the same single-user
# operation without re-implementing the Linux/macOS branching, the dry-run
# shim, the CODE RED file-error path, or the summary roll-up.
#
# Every helper:
#   * requires UM_OS to be set (call um_detect_os first);
#   * honours UM_DRY_RUN=1 by logging the intent only;
#   * logs success with log_ok and failure with log_err / log_file_error
#     including the EXACT path or tool that failed (CODE RED rule);
#   * appends a row to UM_SUMMARY_FILE when one is configured;
#   * returns 0 on success, non-zero on failure (so callers can aggregate).

# um_user_modify <user> <op> [args...]
#
# Apply ONE atomic modification to an existing user. Supported ops:
#   password   <plain-pw>             reset login password
#   shell      <path>                 change login shell
#   comment    <gecos>                change GECOS / RealName
#   enable                            unlock the account
#   disable                           lock the account
#   add-group  <group>                add to supplementary group (creates if missing)
#   rm-group   <group>                remove from supplementary group (idempotent)
#   rename     <new-name>             rename the login (caller must verify target free)
#
# Returns 0 ok, 1 tool failure, 2 bad usage. Caller is responsible for the
# higher-level orchestration (plan banner, conflict checks, password masking
# in printable text, etc.) -- this helper just executes the OS call.
um_user_modify() {
  local user="$1" op="${2:-}"; shift 2 || true
  if [ -z "$user" ] || [ -z "$op" ]; then
    log_err "um_user_modify: missing <user> or <op> (failure: bad call)"
    return 2
  fi
  if [ -z "${UM_OS:-}" ]; then
    log_err "um_user_modify: UM_OS not set (failure: call um_detect_os first)"
    return 2
  fi

  case "$op" in
    password)
      local pw="${1:-}"
      if [ -z "$pw" ]; then
        log_err "um_user_modify password: empty password (failure: refusing to set blank)"
        return 2
      fi
      local masked; masked=$(um_mask_password "$pw")
      if [ "$UM_OS" = "linux" ]; then
        if [ "${UM_DRY_RUN:-0}" = "1" ]; then
          log_info "[dry-run] chpasswd <<< '$user:<masked>'"
        elif printf '%s:%s\n' "$user" "$pw" | chpasswd 2>/dev/null; then
          log_ok "$(um_msg passwordSet "$user" "$masked")"
        else
          log_err "$(um_msg passwordSetFail "$user" "chpasswd failed")"; return 1
        fi
      else
        if [ "${UM_DRY_RUN:-0}" = "1" ]; then
          log_info "[dry-run] dscl . -passwd /Users/$user <masked>"
        elif dscl . -passwd "/Users/$user" "$pw" 2>/dev/null; then
          log_ok "$(um_msg passwordSet "$user" "$masked")"
        else
          log_err "$(um_msg passwordSetFail "$user" "dscl -passwd failed")"; return 1
        fi
      fi
      um_summary_add "ok" "modify" "$user" "password"
      ;;

    shell)
      local sh="${1:-}"
      if [ -z "$sh" ]; then log_err "um_user_modify shell: empty path"; return 2; fi
      if [ "$UM_OS" = "linux" ]; then
        um_run usermod -s "$sh" "$user" \
          && log_ok "$(um_msg shellChanged "$user" "$sh")" \
          || { log_err "$(um_msg shellChangeFail "$user" "$sh" "usermod -s failed")"; return 1; }
      else
        um_run dscl . -create "/Users/$user" UserShell "$sh" \
          && log_ok "$(um_msg shellChanged "$user" "$sh")" \
          || { log_err "$(um_msg shellChangeFail "$user" "$sh" "dscl -create UserShell failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "shell=$sh"
      ;;

    comment)
      local gecos="${1:-}"
      if [ "$UM_OS" = "linux" ]; then
        um_run usermod -c "$gecos" "$user" \
          && log_ok "$(um_msg commentChanged "$user")" \
          || { log_err "$(um_msg commentChangeFail "$user" "usermod -c failed")"; return 1; }
      else
        um_run dscl . -create "/Users/$user" RealName "$gecos" \
          && log_ok "$(um_msg commentChanged "$user")" \
          || { log_err "$(um_msg commentChangeFail "$user" "dscl -create RealName failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "comment"
      ;;

    enable)
      if [ "$UM_OS" = "linux" ]; then
        um_run usermod -U "$user" \
          && log_ok "$(um_msg accountEnabled "$user")" \
          || { log_err "$(um_msg accountEnableFail "$user" "usermod -U failed")"; return 1; }
      else
        um_run pwpolicy -u "$user" -enableuser \
          && log_ok "$(um_msg accountEnabled "$user")" \
          || { log_err "$(um_msg accountEnableFail "$user" "pwpolicy -enableuser failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "enabled"
      ;;

    disable)
      if [ "$UM_OS" = "linux" ]; then
        um_run usermod -L "$user" \
          && log_ok "$(um_msg accountDisabled "$user")" \
          || { log_err "$(um_msg accountDisableFail "$user" "usermod -L failed")"; return 1; }
      else
        um_run pwpolicy -u "$user" -disableuser \
          && log_ok "$(um_msg accountDisabled "$user")" \
          || { log_err "$(um_msg accountDisableFail "$user" "pwpolicy -disableuser failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "disabled"
      ;;

    add-group)
      local g="${1:-}"
      if [ -z "$g" ]; then log_err "um_user_modify add-group: empty group"; return 2; fi
      if ! um_group_exists "$g"; then
        log_warn "group '$g' does not exist -- creating it"
        if [ "$UM_OS" = "linux" ]; then
          um_run groupadd "$g" || { log_err "$(um_msg groupCreateFail "$g" "groupadd failed")"; return 1; }
        else
          local _gid; _gid=$(um_next_macos_gid 510)
          um_run dscl . -create "/Groups/$g" || true
          um_run dscl . -create "/Groups/$g" PrimaryGroupID "$_gid" || true
        fi
      fi
      if [ "$UM_OS" = "linux" ]; then
        um_run usermod -aG "$g" "$user" \
          && log_ok "$(um_msg groupAdded "$user" "$g")" \
          || { log_err "$(um_msg groupAddFail "$user" "$g" "usermod -aG failed")"; return 1; }
      else
        um_run dscl . -append "/Groups/$g" GroupMembership "$user" \
          && log_ok "$(um_msg groupAdded "$user" "$g")" \
          || { log_err "$(um_msg groupAddFail "$user" "$g" "dscl -append failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "+group $g"
      ;;

    rm-group)
      local g="${1:-}"
      if [ -z "$g" ]; then log_err "um_user_modify rm-group: empty group"; return 2; fi
      if ! um_group_exists "$g"; then
        log_info "group '$g' does not exist -- skipping remove (idempotent)"
        return 0
      fi
      if [ "$UM_OS" = "linux" ]; then
        um_run gpasswd -d "$user" "$g" \
          && log_ok "$(um_msg groupRemoved "$user" "$g")" \
          || { log_err "$(um_msg groupRemoveFail "$user" "$g" "gpasswd -d failed")"; return 1; }
      else
        um_run dscl . -delete "/Groups/$g" GroupMembership "$user" \
          && log_ok "$(um_msg groupRemoved "$user" "$g")" \
          || { log_err "$(um_msg groupRemoveFail "$user" "$g" "dscl -delete failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "-group $g"
      ;;

    rename)
      local newname="${1:-}"
      if [ -z "$newname" ]; then log_err "um_user_modify rename: empty new-name"; return 2; fi
      if um_user_exists "$newname"; then
        log_err "$(um_msg renameTargetExists "$newname")"; return 1
      fi
      if [ "$UM_OS" = "linux" ]; then
        um_run usermod -l "$newname" "$user" \
          && log_ok "$(um_msg userRenamed "$user" "$newname")" \
          || { log_err "$(um_msg renameFail "$user" "$newname" "usermod -l failed")"; return 1; }
      else
        um_run dscl . -change "/Users/$user" RecordName "$user" "$newname" \
          && log_ok "$(um_msg userRenamed "$user" "$newname")" \
          || { log_err "$(um_msg renameFail "$user" "$newname" "dscl -change RecordName failed")"; return 1; }
      fi
      um_summary_add "ok" "modify" "$user" "renamed -> $newname"
      ;;

    *)
      log_err "um_user_modify: unknown op '$op' (failure: see helpers/_common.sh for the supported list)"
      return 2
      ;;
  esac
  return 0
}

# um_user_delete <user> [--remove-mail-spool]
#
# Delete the account record ONLY (no home-dir purge -- call um_purge_home for
# that). Idempotent: removing an absent user logs a [WARN] and returns 0 so
# bulk loaders can keep going.
um_user_delete() {
  local user="${1:-}"; shift || true
  local rm_mail=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --remove-mail-spool) rm_mail=1; shift ;;
      *) log_err "um_user_delete: unknown flag '$1' (failure: bad call)"; return 2 ;;
    esac
  done
  if [ -z "$user" ]; then
    log_err "um_user_delete: missing <user> (failure: bad call)"; return 2
  fi
  if [ -z "${UM_OS:-}" ]; then
    log_err "um_user_delete: UM_OS not set (failure: call um_detect_os first)"; return 2
  fi
  if ! um_user_exists "$user"; then
    log_warn "user '$user' does not exist -- nothing to remove (idempotent)"
    um_summary_add "skip" "remove-user" "$user" "absent"
    return 0
  fi

  if [ "$UM_OS" = "linux" ]; then
    local args=(userdel)
    [ "$rm_mail" = "1" ] && args+=(-r)
    args+=("$user")
    if um_run "${args[@]}"; then
      log_ok "$(um_msg userRemoved "$user")"
      um_summary_add "ok" "remove-user" "$user" "userdel"
      return 0
    fi
    log_err "$(um_msg userRemoveFail "$user" "userdel returned non-zero")"
    um_summary_add "fail" "remove-user" "$user" "userdel failed"
    return 1
  fi

  # macOS
  if um_run dscl . -delete "/Users/$user"; then
    log_ok "$(um_msg userRemoved "$user")"
    um_summary_add "ok" "remove-user" "$user" "dscl -delete"
    return 0
  fi
  log_err "$(um_msg userRemoveFail "$user" "dscl -delete failed")"
  um_summary_add "fail" "remove-user" "$user" "dscl -delete failed"
  return 1
}

# um_purge_home <home-path>
#
# Delete a user's home directory recursively. Refuses obvious foot-guns
# (empty path, '/', a path that is not under /home, /Users, or /var).
# CODE RED: every refusal AND every failure logs the exact path + reason.
um_purge_home() {
  local home="${1:-}"
  if [ -z "$home" ]; then
    log_err "um_purge_home: empty path (failure: refusing to rm -rf nothing)"
    return 2
  fi
  case "$home" in
    /|/root|/etc|/usr|/var|/bin|/sbin|/lib|/opt|/boot|/sys|/proc|/dev)
      log_file_error "$home" "refusing to purge a system path"
      return 2
      ;;
  esac
  case "$home" in
    /home/*|/Users/*|/var/empty/*|/var/home/*) : ;;
    *)
      log_file_error "$home" "refusing to purge: not under /home, /Users, or /var"
      return 2
      ;;
  esac
  if [ ! -e "$home" ]; then
    log_warn "home dir '$home' does not exist -- nothing to purge (idempotent)"
    return 0
  fi
  if [ ! -d "$home" ]; then
    log_file_error "$home" "expected a directory but found a non-directory entry"
    return 1
  fi
  if [ "${UM_DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] rm -rf '$home'"
    return 0
  fi
  if rm -rf -- "$home" 2>/dev/null; then
    log_ok "$(um_msg homeRemoved "$home")"
    return 0
  fi
  log_file_error "$home" "rm -rf failed while purging home directory"
  return 1
}