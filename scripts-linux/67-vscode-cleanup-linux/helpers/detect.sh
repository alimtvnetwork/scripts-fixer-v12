#!/usr/bin/env bash
# helpers/detect.sh -- read-only install-method detection.
#
# Each probe kind:
#   dpkg-status            -> dpkg -s <pkg> succeeds
#   dpkg-status-no-source  -> dpkg -s <pkg> succeeds AND no MS apt source file present
#                              (i.e. installed manually via dpkg -i, not via apt repo)
#   snap-list              -> snap list <pkg> succeeds
#   file-exists            -> [ -e <path> ]
#   dir-exists             -> [ -d <path> ]
#
# Every probe is read-only. We never call apt-get or snap mutating verbs here.
# Detection results are emitted as TSV rows on stdout:
#   <method>\t<probeKind>\t<detail>
# (one row per HIT; non-hits are silent so the caller can compute coverage).

# Expand $HOME / $XDG_* references in a path coming from JSON.
_expand_path() {
  local raw="$1"
  # Use eval with a printf to expand env vars inside a quoted string. Safe
  # because the inputs come from our own config.json (allow-list), never user CLI.
  eval "printf '%s' \"$raw\""
}

# probe_dpkg_status <pkg>  -> echoes hit detail or empty
probe_dpkg_status() {
  local pkg="$1"
  command -v dpkg >/dev/null 2>&1 || return 1
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    local ver
    ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo unknown)
    printf 'pkg=%s version=%s' "$pkg" "$ver"
    return 0
  fi
  return 1
}

# probe_dpkg_no_source <pkg>  -> hit when dpkg knows pkg but no MS apt source file is present.
probe_dpkg_no_source() {
  local pkg="$1"
  probe_dpkg_status "$pkg" >/dev/null 2>&1 || return 1
  if [ -f /etc/apt/sources.list.d/vscode.list ]; then
    return 1   # MS apt source IS present -> classify as 'apt', not 'deb'.
  fi
  local ver
  ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo unknown)
  printf 'pkg=%s version=%s (no /etc/apt/sources.list.d/vscode.list)' "$pkg" "$ver"
  return 0
}

probe_snap_list() {
  local pkg="$1"
  command -v snap >/dev/null 2>&1 || return 1
  if snap list "$pkg" >/dev/null 2>&1; then
    local rev
    rev=$(snap list "$pkg" 2>/dev/null | awk 'NR==2 {print $3}')
    printf 'snap=%s revision=%s' "$pkg" "${rev:-?}"
    return 0
  fi
  return 1
}

probe_file_exists() {
  local p; p=$(_expand_path "$1")
  if [ -e "$p" ]; then printf 'path=%s' "$p"; return 0; fi
  return 1
}

probe_dir_exists() {
  local p; p=$(_expand_path "$1")
  if [ -d "$p" ]; then
    local sz; sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
    printf 'dir=%s size=%s' "$p" "${sz:-?}"
    return 0
  fi
  return 1
}

# Public API -- run a single probe row from config.json.
# Args: <method> <kind> <pkg-or-path>
# Echoes "<method>\t<kind>\t<detail>" on hit; nothing on miss.
detect_run_probe() {
  local method="$1" kind="$2" arg="$3"
  local detail
  case "$kind" in
    dpkg-status)            detail=$(probe_dpkg_status      "$arg") || return 1 ;;
    dpkg-status-no-source)  detail=$(probe_dpkg_no_source   "$arg") || return 1 ;;
    snap-list)              detail=$(probe_snap_list        "$arg") || return 1 ;;
    file-exists)            detail=$(probe_file_exists      "$arg") || return 1 ;;
    dir-exists)             detail=$(probe_dir_exists       "$arg") || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$method" "$kind" "$detail"
  return 0
}