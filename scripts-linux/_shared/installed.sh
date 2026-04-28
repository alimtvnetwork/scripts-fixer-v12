#!/usr/bin/env bash
# scripts-linux/_shared/installed.sh
# Per-tool install record helpers (mirror of scripts/shared/installed.ps1).
#
# Each tool gets a JSON file:   .installed/<name>.json
#   { "name": "git", "version": "2.43.0", "installed_at": "2026-04-28T12:34:56Z",
#     "status": "ok" | "error", "error": "..." }
#
# A legacy ".installed/<name>.ok" marker file is also touched on success so the
# existing doctor.sh / dispatcher logic keeps working.
#
# CODE RED: every file/path failure is logged with exact path + reason.

# Resolve logger if not already loaded.
__inst_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__inst_dir/logger.sh"
fi
if ! command -v log_file_error >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__inst_dir/file-error.sh" 2>/dev/null || true
fi

_inst_root() {
  # .installed/ lives at scripts-linux/.installed/
  echo "$(cd "$__inst_dir/.." && pwd)/.installed"
}

_inst_path() {
  local name="$1"
  echo "$(_inst_root)/$name.json"
}

save_installed_record() {
  # Args: --name <n> --version <v> [--status ok]
  local name="" version="" status="ok"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    name="$2"; shift 2 ;;
      --version) version="$2"; shift 2 ;;
      --status)  status="$2"; shift 2 ;;
      *)         shift ;;
    esac
  done
  [ -z "$name" ] && { log_warn "save_installed_record: --name missing"; return 1; }

  local root; root=$(_inst_root)
  if ! mkdir -p "$root" 2>/dev/null; then
    log_file_error "$root" "could not create .installed/ directory"
    return 1
  fi

  local file; file=$(_inst_path "$name")
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local json
  if command -v jq >/dev/null 2>&1; then
    json=$(jq -n --arg n "$name" --arg v "$version" --arg t "$ts" --arg s "$status" \
      '{name:$n, version:$v, installed_at:$t, status:$s}')
  else
    json="{\"name\":\"$name\",\"version\":\"$version\",\"installed_at\":\"$ts\",\"status\":\"$status\"}"
  fi
  if ! printf '%s\n' "$json" > "$file" 2>/dev/null; then
    log_file_error "$file" "failed to write install record"
    return 1
  fi
  # Legacy .ok marker for doctor.sh compatibility.
  touch "$root/$name.ok" 2>/dev/null || log_file_error "$root/$name.ok" "could not touch legacy marker"
  return 0
}

save_installed_error() {
  # Args: --name <n> --error <msg>
  local name="" err=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)  name="$2"; shift 2 ;;
      --error) err="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  [ -z "$name" ] && return 1
  local root; root=$(_inst_root)
  mkdir -p "$root" 2>/dev/null || { log_file_error "$root" "mkdir failed"; return 1; }
  local file; file=$(_inst_path "$name")
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local json
  if command -v jq >/dev/null 2>&1; then
    json=$(jq -n --arg n "$name" --arg t "$ts" --arg e "$err" \
      '{name:$n, version:null, installed_at:$t, status:"error", error:$e}')
  else
    local esc=${err//\"/\\\"}
    json="{\"name\":\"$name\",\"version\":null,\"installed_at\":\"$ts\",\"status\":\"error\",\"error\":\"$esc\"}"
  fi
  if ! printf '%s\n' "$json" > "$file" 2>/dev/null; then
    log_file_error "$file" "failed to write error record"
    return 1
  fi
  return 0
}

get_installed_version() {
  # Args: <name>  -> echoes stored version or empty
  local name="$1"
  local file; file=$(_inst_path "$name")
  [ -f "$file" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$file" 2>/dev/null
  else
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file"
  fi
}

is_already_installed() {
  # Args: --name <n> --current-version <v>  -> exit 0 if matches, 1 otherwise
  local name="" cur=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)            name="$2"; shift 2 ;;
      --current-version) cur="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local stored; stored=$(get_installed_version "$name")
  [ -n "$stored" ] && [ "$stored" = "$cur" ]
}
