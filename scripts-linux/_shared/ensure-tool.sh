#!/usr/bin/env bash
# scripts-linux/_shared/ensure-tool.sh
# One-shot detect / install / upgrade / track helper (mirror of
# scripts/shared/ensure-tool.ps1).
#
# Behavior:
#   1. Detect command in PATH.
#   2. If found, read version + parse via tool-version-parsers.sh. If it
#      matches the .installed/<name>.json record, skip everything.
#   3. If found and --upgrade is set, run the upgrade callback and refresh
#      the install record.
#   4. If missing, run the install callback (default: apt) and write a fresh
#      record.
#
# CODE RED: every file/path failure is reported with exact path + reason.
#
# Usage:
#   . "$ROOT/_shared/ensure-tool.sh"
#   ensure_tool \
#     --name      git \
#     --command   git \
#     --apt       git \
#     --friendly  "Git" \
#     --upgrade
#
#   # Custom install command (any shell snippet):
#   ensure_tool --name node --command node \
#     --install-cmd 'curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs'

# -- Bootstrap shared helpers --------------------------------------------------
__et_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__et_dir/logger.sh"
fi
if ! command -v log_file_error >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__et_dir/file-error.sh" 2>/dev/null || true
fi
if ! command -v save_installed_record >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__et_dir/installed.sh"
fi
if ! command -v parse_tool_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__et_dir/tool-version-parsers.sh"
fi
if ! command -v add_ensure_summary >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__et_dir/ensure-summary.sh"
fi

write_ensure_file_error() {
  # CODE RED helper.
  local path="$1" reason="$2"
  if command -v log_file_error >/dev/null 2>&1; then
    log_file_error "$path" "$reason"
  else
    log_err "  [FAIL] path: $path -- reason: $reason"
  fi
}

get_ensured_version() {
  # Args: --command <c> [--flag <--version>]
  local cmd="" flag="--version"
  while [ $# -gt 0 ]; do
    case "$1" in
      --command) cmd="$2"; shift 2 ;;
      --flag)    flag="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  command -v "$cmd" >/dev/null 2>&1 || return 1
  # Capture both stdout + stderr (java prints to stderr).
  local raw
  raw=$("$cmd" "$flag" 2>&1 || true)
  [ -z "$raw" ] && return 1
  parse_tool_version "$cmd" "$raw"
}

ensure_tool() {
  local name="" command="" friendly="" version_flag="--version"
  local apt_pkg="" snap_pkg="" install_cmd="" upgrade_cmd=""
  local always_upgrade=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        name="$2"; shift 2 ;;
      --command)     command="$2"; shift 2 ;;
      --friendly)    friendly="$2"; shift 2 ;;
      --version-flag) version_flag="$2"; shift 2 ;;
      --apt)         apt_pkg="$2"; shift 2 ;;
      --snap)        snap_pkg="$2"; shift 2 ;;
      --install-cmd) install_cmd="$2"; shift 2 ;;
      --upgrade-cmd) upgrade_cmd="$2"; shift 2 ;;
      --upgrade)     always_upgrade=1; shift ;;
      *) log_warn "ensure_tool: unknown arg $1"; shift ;;
    esac
  done

  [ -z "$name" ]    && { log_err "ensure_tool: --name required"; return 2; }
  [ -z "$command" ] && command="$name"
  [ -z "$friendly" ] && friendly="$name"

  # Default install/upgrade snippets (apt-based) when nothing custom given.
  if [ -z "$install_cmd" ]; then
    if [ -n "$apt_pkg" ]; then
      install_cmd="sudo apt-get update -y >/dev/null 2>&1 || true; sudo apt-get install -y $apt_pkg"
    elif [ -n "$snap_pkg" ]; then
      install_cmd="sudo snap install $snap_pkg"
    else
      local reason="no --install-cmd, --apt, or --snap provided for tool '$name'"
      write_ensure_file_error ".installed/$name.json" "$reason"
      save_installed_error --name "$name" --error "$reason"
      add_ensure_summary --name "$name" --friendly "$friendly" --action failed --error "$reason"
      return 1
    fi
  fi
  if [ -z "$upgrade_cmd" ] && [ -n "$apt_pkg" ]; then
    upgrade_cmd="sudo apt-get update -y >/dev/null 2>&1 || true; sudo apt-get install --only-upgrade -y $apt_pkg"
  fi

  # ---- Step 1: detect -------------------------------------------------------
  if command -v "$command" >/dev/null 2>&1; then
    local current_version=""
    current_version=$(get_ensured_version --command "$command" --flag "$version_flag" || true)

    if [ -n "$current_version" ]; then
      if is_already_installed --name "$name" --current-version "$current_version"; then
        log_ok "$friendly already installed and tracked: $current_version -- skipping"
        add_ensure_summary --name "$name" --friendly "$friendly" --action skipped --version "$current_version"
        return 0
      fi
      log_info "$friendly found in PATH: $current_version (not tracked or version drift)"
    else
      log_warn "$friendly found in PATH but version probe returned nothing"
    fi

    # ---- Step 2: optional upgrade -----------------------------------------
    if [ "$always_upgrade" = "1" ] && [ -n "$upgrade_cmd" ]; then
      log_info "Upgrading $friendly to latest..."
      if ! bash -c "$upgrade_cmd"; then
        local err="upgrade failed (see apt/snap output above)"
        write_ensure_file_error ".installed/$name.json" "$err"
        save_installed_error --name "$name" --error "$err"
        add_ensure_summary --name "$name" --friendly "$friendly" --action failed --error "$err"
        return 1
      fi
      local new_version
      new_version=$(get_ensured_version --command "$command" --flag "$version_flag" || true)
      [ -z "$new_version" ] && new_version="$current_version (pending refresh)"
      save_installed_record --name "$name" --version "$new_version"
      log_ok "$friendly upgraded successfully: $new_version"
      add_ensure_summary --name "$name" --friendly "$friendly" --action upgraded --version "$new_version"
      return 0
    fi

    # No upgrade requested — record current version so future runs are fast.
    if [ -n "$current_version" ]; then
      save_installed_record --name "$name" --version "$current_version"
    fi
    add_ensure_summary --name "$name" --friendly "$friendly" --action skipped --version "$current_version"
    return 0
  fi

  # ---- Step 3: missing -> install ------------------------------------------
  log_info "$friendly not found, installing..."
  if ! bash -c "$install_cmd"; then
    local err="install failed (see apt/snap/curl output above)"
    write_ensure_file_error ".installed/$name.json" "$err"
    save_installed_error --name "$name" --error "$err"
    add_ensure_summary --name "$name" --friendly "$friendly" --action failed --error "$err"
    return 1
  fi
  hash -r 2>/dev/null || true
  local installed_version
  installed_version=$(get_ensured_version --command "$command" --flag "$version_flag" || true)
  [ -z "$installed_version" ] && installed_version="unknown"
  save_installed_record --name "$name" --version "$installed_version"
  log_ok "$friendly installed successfully: $installed_version"
  add_ensure_summary --name "$name" --friendly "$friendly" --action installed --version "$installed_version"
  return 0
}
