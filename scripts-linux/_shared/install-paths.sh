#!/usr/bin/env bash
# Shared install-paths helper for Linux installer toolkit.
#
# Mirrors scripts/shared/install-paths.ps1 (Write-InstallPaths). Every
# install/operation MUST surface three paths:
#   Source  -- where the install was launched from (script dir, repo root,
#              download URL, or installer binary path)
#   Temp    -- where intermediate / cache / scratch files are written
#   Target  -- final install location (/usr/bin, /opt, ~/.local, etc.)
#
# Usage:
#   . "$ROOT/_shared/install-paths.sh"
#   write_install_paths \
#       --tool   "Node.js (LTS)" \
#       --source "apt repo (Debian/Ubuntu)" \
#       --temp   "/var/cache/apt/archives" \
#       --target "/usr/bin/node"
#
# Optional: --action "Install" (default) | "Upgrade" | "Repair" | "Configure"
#
# Missing values are allowed but flagged "(unknown)" in yellow.
# Helper version: 1.0.0

# Resolve logger if not already loaded
__ip_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__ip_dir/logger.sh"
fi

write_install_paths() {
  local tool="" source_path="" temp_path="" target_path="" action="Install"

  while [ $# -gt 0 ]; do
    case "$1" in
      --tool)   tool="$2"; shift 2 ;;
      --source) source_path="$2"; shift 2 ;;
      --temp)   temp_path="$2"; shift 2 ;;
      --target) target_path="$2"; shift 2 ;;
      --action) action="$2"; shift 2 ;;
      *)        log_warn "write_install_paths: unknown arg '$1'"; shift ;;
    esac
  done

  local heading
  if [ -n "$tool" ]; then
    heading="$action paths -- $tool"
  else
    heading="$action paths"
  fi

  # Color codes
  local C_MAG='\033[35m' C_WHITE='\033[97m' C_GRAY='\033[90m'
  local C_VAL='\033[37m' C_UNK='\033[33m' C_RST='\033[0m'

  printf '\n'
  printf '  %b[ PATH ]%b %b%s%b\n' "$C_MAG" "$C_RST" "$C_WHITE" "$heading" "$C_RST"

  __ip_row() {
    local label="$1" val="$2"
    if [ -z "$val" ]; then
      printf '          %b%s%b : %b(unknown)%b\n' "$C_GRAY" "$label" "$C_RST" "$C_UNK" "$C_RST"
    else
      printf '          %b%s%b : %b%s%b\n' "$C_GRAY" "$label" "$C_RST" "$C_VAL" "$val" "$C_RST"
    fi
  }
  __ip_row "Source" "$source_path"
  __ip_row "Temp  " "$temp_path"
  __ip_row "Target" "$target_path"
  printf '\n'

  # Structured log line so the trio survives in JSON/text logs
  log_info "installPaths tool='$tool' action='$action' source='$source_path' temp='$temp_path' target='$target_path'"
}

# Convenience: per-tool temp dir under /tmp, created if needed
resolve_default_temp_dir() {
  local slug="$1"
  if [ -z "$slug" ]; then
    log_file_error "(slug)" "resolve_default_temp_dir: slug required"
    return 1
  fi
  local dir="${TMPDIR:-/tmp}/scripts-fixer/$slug"
  mkdir -p "$dir" 2>/dev/null || {
    log_file_error "$dir" "mkdir failed for temp dir"
    return 1
  }
  printf '%s\n' "$dir"
}
