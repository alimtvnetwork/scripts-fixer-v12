#!/usr/bin/env bash
# helpers/remove.sh -- removal action dispatchers used by run.sh.
#
# Every action_* function:
#   - reads $DRY_RUN to decide apply-vs-preview
#   - never deletes anything outside the path the caller passed in
#   - emits one row per action via _emit_row
#       (status \t method \t kind \t target \t detail)
#   - logs every file/path failure with exact path + reason (CODE RED rule)
#
# Statuses written to the rows file:
#   removed   -- file/dir/package actually deleted
#   would     -- dry-run preview entry
#   missing   -- target wasn't present
#   failed    -- delete attempted but errored
#   skipped   -- prerequisite missing (sudo, tool, etc.)

: "${DRY_RUN:=0}"
: "${IS_ROOT:=0}"
: "${ROWS_TSV:=/tmp/vscode-cleanup-linux.rows.tsv}"

_emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$ROWS_TSV"
}

_expand() { eval "printf '%s' \"$1\""; }

_need_sudo_check() {
  # Args: method, kind, target, requiresSudo (true|false)
  local method="$1" kind="$2" target="$3" req="$4"
  if [ "$req" = "true" ] && [ "$IS_ROOT" -ne 1 ]; then
    _emit_row "skipped" "$method" "$kind" "$target" "requires sudo (re-run with sudo or use --scope user)"
    log_warn "  [$method] skipped $kind: $target (requires sudo; re-run with sudo or use --scope user)"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------ rm-file / rm-shim
# rm-shim is identical to rm-file in semantics but emits 'shim' as kind so the
# manifest is informative.
_rm_path_common() {
  local method="$1" kind="$2" raw_target="$3" req_sudo="$4"
  local target; target=$(_expand "$raw_target")
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    _emit_row "missing" "$method" "$kind" "$target" "absent"
    log_info "  [$method] not present ($kind): $target"
    return 0
  fi
  _need_sudo_check "$method" "$kind" "$target" "$req_sudo" || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    _emit_row "would" "$method" "$kind" "$target" "exists"
    log_info "  [$method] [dry-run] would $kind: $target"
    return 0
  fi
  if rm -f "$target" 2>/dev/null; then
    _emit_row "removed" "$method" "$kind" "$target" "ok"
    log_ok "  [$method] removed $kind: $target"
  else
    _emit_row "failed" "$method" "$kind" "$target" "rm failed"
    log_file_error "$target" "rm failed (permission? try sudo or --scope user)"
  fi
}
action_rm_file() { _rm_path_common "$1" "rm-file" "$2" "$3"; }
action_rm_shim() { _rm_path_common "$1" "rm-shim" "$2" "$3"; }

# ------------------------------------------------------------ rm-dir
action_rm_dir() {
  local method="$1" raw_target="$2" req_sudo="$3"
  local target; target=$(_expand "$raw_target")
  if [ ! -d "$target" ]; then
    _emit_row "missing" "$method" "rm-dir" "$target" "directory absent"
    log_info "  [$method] not present (rm-dir): $target"
    return 0
  fi
  _need_sudo_check "$method" "rm-dir" "$target" "$req_sudo" || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    local sz; sz=$(du -sh "$target" 2>/dev/null | awk '{print $1}')
    _emit_row "would" "$method" "rm-dir" "$target" "size=${sz:-?}"
    log_info "  [$method] [dry-run] would rm-dir: $target (size=${sz:-?})"
    return 0
  fi
  if rm -rf "$target" 2>/dev/null; then
    _emit_row "removed" "$method" "rm-dir" "$target" "ok"
    log_ok "  [$method] removed rm-dir: $target"
  else
    _emit_row "failed" "$method" "rm-dir" "$target" "rm -rf failed"
    log_file_error "$target" "rm -rf failed (permission? try sudo)"
  fi
}

# ------------------------------------------------------------ apt-purge
# Args: method, csv-pkg-list (already comma-joined)
action_apt_purge() {
  local method="$1" pkgs_csv="$2"
  if ! command -v apt-get >/dev/null 2>&1; then
    _emit_row "skipped" "$method" "apt-purge" "$pkgs_csv" "apt-get not installed"
    log_warn "  [$method] skipped apt-purge: apt-get not installed"
    return 0
  fi
  _need_sudo_check "$method" "apt-purge" "$pkgs_csv" "true" || return 0
  local IFS=','; local arr=($pkgs_csv); unset IFS
  local pkg
  for pkg in "${arr[@]}"; do
    [ -z "$pkg" ] && continue
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      _emit_row "missing" "$method" "apt-purge" "$pkg" "package not installed"
      log_info "  [$method] not present (apt-purge): $pkg"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      _emit_row "would" "$method" "apt-purge" "$pkg" "currently installed"
      log_info "  [$method] [dry-run] would apt-purge: $pkg"
      continue
    fi
    if apt-get purge -y "$pkg" >/dev/null 2>&1; then
      _emit_row "removed" "$method" "apt-purge" "$pkg" "ok"
      log_ok "  [$method] removed apt-purge: $pkg"
    else
      _emit_row "failed" "$method" "apt-purge" "$pkg" "apt-get purge returned non-zero"
      log_file_error "$pkg" "apt-get purge failed (see /var/log/apt/term.log)"
    fi
  done
}

# ------------------------------------------------------------ apt-update
action_apt_update() {
  local method="$1" note="$2"
  if ! command -v apt-get >/dev/null 2>&1; then
    _emit_row "skipped" "$method" "apt-update" "(refresh)" "apt-get not installed"
    return 0
  fi
  _need_sudo_check "$method" "apt-update" "(refresh)" "true" || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    _emit_row "would" "$method" "apt-update" "(refresh)" "$note"
    log_info "  [$method] [dry-run] would apt-update: $note"
    return 0
  fi
  if apt-get update -y >/dev/null 2>&1; then
    _emit_row "removed" "$method" "apt-update" "(refresh)" "$note"
    log_ok "  [$method] apt-update done: $note"
  else
    _emit_row "failed" "$method" "apt-update" "(refresh)" "apt-get update non-zero"
    log_warn "  [$method] apt-update returned non-zero -- continuing"
  fi
}

# ------------------------------------------------------------ snap-remove
action_snap_remove() {
  local method="$1" pkgs_csv="$2"
  if ! command -v snap >/dev/null 2>&1; then
    _emit_row "skipped" "$method" "snap-remove" "$pkgs_csv" "snap not installed"
    log_warn "  [$method] skipped snap-remove: snap not installed"
    return 0
  fi
  _need_sudo_check "$method" "snap-remove" "$pkgs_csv" "true" || return 0
  local IFS=','; local arr=($pkgs_csv); unset IFS
  local pkg
  for pkg in "${arr[@]}"; do
    [ -z "$pkg" ] && continue
    if ! snap list "$pkg" >/dev/null 2>&1; then
      _emit_row "missing" "$method" "snap-remove" "$pkg" "snap not installed"
      log_info "  [$method] not present (snap-remove): $pkg"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      _emit_row "would" "$method" "snap-remove" "$pkg" "currently installed"
      log_info "  [$method] [dry-run] would snap-remove: $pkg"
      continue
    fi
    if snap remove "$pkg" >/dev/null 2>&1; then
      _emit_row "removed" "$method" "snap-remove" "$pkg" "ok"
      log_ok "  [$method] removed snap-remove: $pkg"
    else
      _emit_row "failed" "$method" "snap-remove" "$pkg" "snap remove non-zero"
      log_file_error "$pkg" "snap remove failed"
    fi
  done
}

# ------------------------------------------------------------ dpkg-remove
action_dpkg_remove() {
  local method="$1" pkgs_csv="$2"
  if ! command -v dpkg >/dev/null 2>&1; then
    _emit_row "skipped" "$method" "dpkg-remove" "$pkgs_csv" "dpkg not installed"
    log_warn "  [$method] skipped dpkg-remove: dpkg not installed"
    return 0
  fi
  _need_sudo_check "$method" "dpkg-remove" "$pkgs_csv" "true" || return 0
  local IFS=','; local arr=($pkgs_csv); unset IFS
  local pkg
  for pkg in "${arr[@]}"; do
    [ -z "$pkg" ] && continue
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      _emit_row "missing" "$method" "dpkg-remove" "$pkg" "package not installed"
      log_info "  [$method] not present (dpkg-remove): $pkg"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      _emit_row "would" "$method" "dpkg-remove" "$pkg" "currently installed"
      log_info "  [$method] [dry-run] would dpkg-remove: $pkg"
      continue
    fi
    if dpkg -r "$pkg" >/dev/null 2>&1; then
      _emit_row "removed" "$method" "dpkg-remove" "$pkg" "ok"
      log_ok "  [$method] removed dpkg-remove: $pkg"
    else
      _emit_row "failed" "$method" "dpkg-remove" "$pkg" "dpkg -r non-zero"
      log_file_error "$pkg" "dpkg -r failed"
    fi
  done
}