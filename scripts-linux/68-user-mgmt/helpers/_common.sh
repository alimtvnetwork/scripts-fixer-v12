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
  return 13
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