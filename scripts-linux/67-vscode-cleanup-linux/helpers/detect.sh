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
#   cmd-no-pkg-owner       -> `command -v <pkg>` resolves AND `dpkg -S` reports no
#                              owner AND `snap list` does not own it. Hits the case
#                              where someone copied the binary into /usr/local/bin or
#                              a curl|sh installer dropped a shim with no package
#                              metadata.
#   symlink-into-roots     -> `command -v <pkg>` resolves to a symlink whose
#                              ultimate target lives under one of the configured
#                              tarball roots (passed via DETECT_PROBE_ROOTS env,
#                              colon-separated). Hits the 'tarball + manual ln -s'
#                              install style.
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

# probe_cmd_no_pkg_owner <cmd> -> hit when binary is on PATH but UNOWNED.
# UNOWNED means: dpkg -S <abspath> reports nothing AND `snap list <cmd>` fails.
# This deliberately runs AFTER apt/snap/deb/tarball detectors so callers can
# treat 'binary' as the residual "raw drop" install style.
probe_cmd_no_pkg_owner() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || return 1
    local resolved
    resolved=$(command -v "$cmd" 2>/dev/null) || return 1
    [ -n "$resolved" ] || return 1
    # readlink -f gives the ultimate target; on macOS this would need -e but
    # this script is Linux-only so -f is correct.
    local real
    real=$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")
    # snap-owned? bail (snap detector handles it).
    if command -v snap >/dev/null 2>&1 && snap list "$cmd" >/dev/null 2>&1; then
        return 1
    fi
    # dpkg-owned? bail (apt or deb detector handles it).
    if command -v dpkg >/dev/null 2>&1 && dpkg -S "$real" >/dev/null 2>&1; then
        return 1
    fi
    # If the resolved target sits under a known tarball root, the tarball
    # detector owns this -- bail so we don't double-classify.
    local roots="${DETECT_PROBE_ROOTS:-}"
    if [ -n "$roots" ]; then
        local IFS=':' r
        for r in $roots; do
            [ -z "$r" ] && continue
            r=$(_expand_path "$r")
            case "$real" in
                "$r"|"$r"/*) return 1 ;;
            esac
        done
    fi
    printf 'cmd=%s path=%s real=%s (no dpkg owner, not a snap, not in tarball roots)' \
        "$cmd" "$resolved" "$real"
    return 0
}

# probe_symlink_into_roots <cmd> -> hit when `command -v <cmd>` resolves to a
# symlink whose target lives inside one of the colon-separated roots in
# DETECT_PROBE_ROOTS. This is the "manual `ln -s` from a tarball install" case.
# Not a hit when the resolved path equals the symlink itself (no link).
probe_symlink_into_roots() {
    local cmd="$1"
    local resolved
    resolved=$(command -v "$cmd" 2>/dev/null) || return 1
    [ -L "$resolved" ] || return 1
    local real
    real=$(readlink -f "$resolved" 2>/dev/null) || return 1
    [ -n "$real" ] || return 1
    local roots="${DETECT_PROBE_ROOTS:-}"
    [ -n "$roots" ] || return 1
    local IFS=':' r
    for r in $roots; do
        [ -z "$r" ] && continue
        r=$(_expand_path "$r")
        case "$real" in
            "$r"|"$r"/*)
                printf 'cmd=%s symlink=%s -> target=%s root=%s' \
                    "$cmd" "$resolved" "$real" "$r"
                return 0
                ;;
        esac
    done
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
    cmd-no-pkg-owner)       detail=$(probe_cmd_no_pkg_owner "$arg") || return 1 ;;
    symlink-into-roots)     detail=$(probe_symlink_into_roots "$arg") || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$method" "$kind" "$detail"
  return 0
}