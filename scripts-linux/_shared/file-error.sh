#!/usr/bin/env bash
# CODE RED file/path error reporter. Always log exact path + reason.
# Source logger.sh first.

report_file_missing() {
  local path="$1"; local context="${2:-unspecified}"
  log_file_error "$path" "missing (context: $context)"
  return 1
}

report_file_unreadable() {
  local path="$1"; local context="${2:-unspecified}"
  log_file_error "$path" "unreadable (context: $context)"
  return 1
}

report_dir_create_failed() {
  local path="$1"; local err="$2"
  log_file_error "$path" "mkdir failed: $err"
  return 1
}

ensure_dir() {
  local path="$1"
  if [ -d "$path" ]; then return 0; fi
  if mkdir -p "$path" 2>/dev/null; then return 0; fi
  report_dir_create_failed "$path" "permission or filesystem error"
}