#!/usr/bin/env bash
# Shared logger for Linux installer toolkit.
# CODE RED: every file/path error MUST log exact path + reason.

__LOG_DIR="${__LOG_DIR:-$(dirname "${BASH_SOURCE[0]}")/../.logs}"
mkdir -p "$__LOG_DIR" 2>/dev/null || true

__color() {
  case "$1" in
    info)  printf '\033[36m' ;;
    ok)    printf '\033[32m' ;;
    warn)  printf '\033[33m' ;;
    err)   printf '\033[31m' ;;
    dim)   printf '\033[2m'  ;;
    *)     printf '' ;;
  esac
}

__reset() { printf '\033[0m'; }

__log_write() {
  local level="$1"; shift
  local script="${SCRIPT_ID:-root}"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  local line="[$ts] [$level] [$script] $*"
  echo "$line" >> "$__LOG_DIR/$script.log" 2>/dev/null || true
  printf '%s%s%s\n' "$(__color "$level")" "$line" "$(__reset)"
}

log_info() { __log_write info "$*"; }
log_ok()   { __log_write ok   "$*"; }
log_warn() { __log_write warn "$*"; }
log_err()  { __log_write err  "$*"; }

# CODE RED helper: file/path errors must include exact path + reason.
log_file_error() {
  local path="$1"; local reason="$2"
  __log_write err "FILE-ERROR path='$path' reason='$reason'"
}
# Public: log a message tagged with the current hostname + primary IP.
# Useful in remote/multi-node scripts so output is unambiguous.
# Usage:  log_msg_ip "joining cluster"          (default level: info)
#         log_msg_ip "joined cluster" ok
log_msg_ip() {
  local message="$1"
  local level="${2:-info}"
  local hostname_val ip_val
  hostname_val=$(hostname 2>/dev/null || echo "unknown-host")
  ip_val=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$ip_val" ] || ip_val="?.?.?.?"
  case "$level" in
    ok)   log_ok   "[$hostname_val @ $ip_val] $message" ;;
    warn) log_warn "[$hostname_val @ $ip_val] $message" ;;
    err)  log_err  "[$hostname_val @ $ip_val] $message" ;;
    *)    log_info "[$hostname_val @ $ip_val] $message" ;;
  esac
}
