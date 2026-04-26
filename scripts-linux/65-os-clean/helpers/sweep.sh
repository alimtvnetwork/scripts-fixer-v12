#!/usr/bin/env bash
# 65-os-clean :: helpers/sweep.sh
# Pure POSIX-ish bash. Two sweep primitives + size accounting + a tiny
# JSON-result accumulator that matches the Windows clean-categories shape:
#   { Category, Label, Bucket, Destructive, Count, Bytes, Locked,
#     LockedDetails:[{Path,Reason}], Status, Notes:[] }
#
# CODE RED: every file/dir failure goes through log_file_error <path> <why>.
#
# Per-target emission (used by plan-then-confirm + final verify):
#   When the env var SW_TARGETS_TSV is set to a writable file path, every
#   sweep_* primitive ALSO appends one row per concrete target to that file
#   in the schema:
#     <status>\t<kind>\t<target>\t<bytes>\t<detail>
#   where:
#     status  = removed | would | missing | failed | skipped
#     kind    = rm-file | rm-dir | apt-update | brew-cleanup | journal | <cmd>
#     target  = absolute path OR "cmd:<argv0> <args>"
#     bytes   = best-effort bytes attributable to this target
#     detail  = short human reason (e.g. "preserved-by-caller", lock reason)
#   The plan/verify stages in run.sh consume this TSV; older callers that
#   don't set SW_TARGETS_TSV continue to work unchanged (counter-only mode).

# Helper: append one row to the per-target TSV, if enabled.
# Args: <status> <kind> <target> <bytes> [<detail>]
_sw_emit_target() {
  [ -n "${SW_TARGETS_TSV:-}" ] || return 0
  local status="$1" kind="$2" target="$3" bytes="${4:-0}" detail="${5:-}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$kind" "$target" "$bytes" "$detail" \
    >> "$SW_TARGETS_TSV" \
    || log_file_error "$SW_TARGETS_TSV" "failed to append target row (kind=$kind target=$target)"
}

# ---------- byte counting -------------------------------------------------
# Total bytes for a single path (file or dir). Returns 0 if path is missing
# or unreadable. Uses GNU `du -sb` when available, falls back to BSD `du -sk`
# (macOS) and converts to bytes.
sweep_size_bytes() {
  local path="$1"
  [ -e "$path" ] 2>/dev/null || { printf '0\n'; return 0; }
  if du -sb "$path" >/dev/null 2>&1; then
    du -sb "$path" 2>/dev/null | awk '{print $1+0}'
  else
    du -sk "$path" 2>/dev/null | awk '{print ($1+0)*1024}'
  fi
}

sweep_human_bytes() {
  awk -v n="$1" 'BEGIN{
    s="B KB MB GB TB PB"; split(s,u," "); i=1;
    while (n>=1024 && i<6) { n/=1024; i++ }
    if (i==1) printf "%d %s", n, u[i]; else printf "%.2f %s", n, u[i];
  }'
}

# ---------- sweep modes ---------------------------------------------------
# All sweep_* functions push results into globals (sweep keeps state in
# variables instead of returning structs to keep bash happy):
#   _SW_COUNT  total items removed (or that would be)
#   _SW_BYTES  total bytes freed (best-effort: size before - size after)
#   _SW_LOCKED count of items that could not be removed
#   _SW_LOCKS  newline-separated "path|reason" pairs (capped at 50)
#   _SW_NOTES  newline-separated human notes
sweep_reset() { _SW_COUNT=0; _SW_BYTES=0; _SW_LOCKED=0; _SW_LOCKS=""; _SW_NOTES=""; }

_sw_add_lock() {
  local path="$1" reason="$2"
  _SW_LOCKED=$((_SW_LOCKED + 1))
  if [ "$_SW_LOCKED" -le 50 ]; then
    _SW_LOCKS="${_SW_LOCKS}${path}|${reason}
"
  fi
  log_file_error "$path" "$reason"
}

_sw_classify_err() {
  local err="$1"
  case "$err" in
    *"Permission denied"*|*"Operation not permitted"*) printf 'access denied (locked or root-owned)' ;;
    *"Read-only file system"*)                          printf 'read-only filesystem' ;;
    *"Device or resource busy"*|*"in use"*)             printf 'in use by another process' ;;
    *"No such file"*)                                   printf 'vanished mid-sweep (already gone)' ;;
    *"Directory not empty"*)                            printf 'directory not empty (race)' ;;
    *)                                                   printf 'remove failed: %s' "$err" ;;
  esac
}

# Wipe the CONTENTS of a directory (the dir itself stays).
# Optional --preserve <subdir,subdir2> to keep specific top-level entries.
sweep_contents() {
  local path="$1"; shift
  local preserve_csv="" dry_run="${SW_DRY_RUN:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --preserve) preserve_csv="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done

  if [ ! -e "$path" ]; then
    _SW_NOTES="${_SW_NOTES}Path not present: ${path}
"
    _sw_emit_target "missing" "rm-dir" "$path" 0 "directory absent before sweep"
    return 0
  fi
  if [ ! -d "$path" ]; then
    log_file_error "$path" "expected directory, got non-dir entry"
    _sw_emit_target "failed" "rm-dir" "$path" 0 "expected directory; non-dir on disk"
    return 1
  fi

  local before after
  before=$(sweep_size_bytes "$path")

  # Build a find expression that excludes the preserved subdirs at depth 1.
  local find_args=("$path" -mindepth 1 -maxdepth 1)
  if [ -n "$preserve_csv" ]; then
    local IFS_old="$IFS" name
    IFS=','
    # shellcheck disable=SC2086
    set -- $preserve_csv
    IFS="$IFS_old"
    for name in "$@"; do
      [ -z "$name" ] && continue
      find_args+=( ! -name "$name" )
    done
  fi

  local entry rc err
  while IFS= read -r -d '' entry; do
    local entry_kind="rm-file"
    [ -d "$entry" ] && entry_kind="rm-dir"
    local entry_bytes
    entry_bytes=$(sweep_size_bytes "$entry")
    if [ "$dry_run" = "1" ]; then
      _SW_COUNT=$((_SW_COUNT + 1))
      _sw_emit_target "would" "$entry_kind" "$entry" "$entry_bytes" "in $path"
      continue
    fi
    err=$(rm -rf -- "$entry" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      _SW_COUNT=$((_SW_COUNT + 1))
      _sw_emit_target "removed" "$entry_kind" "$entry" "$entry_bytes" "in $path"
    else
      local lock_reason
      lock_reason=$(_sw_classify_err "$err")
      _sw_add_lock "$entry" "$lock_reason"
      _sw_emit_target "failed" "$entry_kind" "$entry" 0 "$lock_reason"
    fi
  done < <(find "${find_args[@]}" -print0 2>/dev/null)

  after=$(sweep_size_bytes "$path")
  if [ "$dry_run" = "1" ]; then
    _SW_BYTES=$((_SW_BYTES + before))
  else
    local diff=$((before - after))
    [ "$diff" -lt 0 ] && diff=0
    _SW_BYTES=$((_SW_BYTES + diff))
  fi
}

# Resolve a glob pattern (e.g. "/tmp/${USER}-*" or "*.gz" inside a dir) and
# remove every match. Patterns are expanded by find to avoid the bash
# argument-list-too-long trap.
sweep_glob() {
  local pattern="$1"; shift
  local root_for_glob="" name_pattern=""
  local dry_run="${SW_DRY_RUN:-0}"

  # Two flavours:
  #   (a) absolute pattern with one or more wildcards -- expand with shell
  #       globbing (e.g. "/tmp/user-*").
  #   (b) bare basename pattern paired with a parent root -- caller passes
  #       --root <dir>.
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root_for_glob="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done

  local matches=() entry rc err before
  before=0
  if [ -n "$root_for_glob" ]; then
    if [ ! -d "$root_for_glob" ]; then
      _SW_NOTES="${_SW_NOTES}Root not present: ${root_for_glob}
"
      _sw_emit_target "missing" "rm-dir" "$root_for_glob" 0 "glob root absent (pattern=$pattern)"
      return 0
    fi
    while IFS= read -r -d '' entry; do
      matches+=("$entry")
    done < <(find "$root_for_glob" -name "$pattern" -print0 2>/dev/null)
  else
    # Shell-expand the pattern. nullglob ensures empty match -> empty array.
    local _shopt_state
    _shopt_state=$(shopt -p nullglob 2>/dev/null || true)
    shopt -s nullglob 2>/dev/null || true
    # shellcheck disable=SC2206
    matches=( $pattern )
    eval "$_shopt_state" 2>/dev/null || true
  fi

  if [ "${#matches[@]}" -eq 0 ]; then
    _SW_NOTES="${_SW_NOTES}No matches for pattern: ${pattern}
"
    _sw_emit_target "missing" "rm-file" "$pattern" 0 "no glob matches"
    return 0
  fi

  for entry in "${matches[@]}"; do
    [ -e "$entry" ] || continue
    local entry_bytes
    entry_bytes=$(sweep_size_bytes "$entry")
    before=$((before + entry_bytes))
    local entry_kind="rm-file"
    [ -d "$entry" ] && entry_kind="rm-dir"
    if [ "$dry_run" = "1" ]; then
      _SW_COUNT=$((_SW_COUNT + 1))
      _sw_emit_target "would" "$entry_kind" "$entry" "$entry_bytes" "match for $pattern"
      continue
    fi
    err=$(rm -rf -- "$entry" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      _SW_COUNT=$((_SW_COUNT + 1))
      _sw_emit_target "removed" "$entry_kind" "$entry" "$entry_bytes" "match for $pattern"
    else
      local lock_reason
      lock_reason=$(_sw_classify_err "$err")
      _sw_add_lock "$entry" "$lock_reason"
      _sw_emit_target "failed" "$entry_kind" "$entry" 0 "$lock_reason"
    fi
  done

  if [ "$dry_run" = "1" ]; then
    _SW_BYTES=$((_SW_BYTES + before))
  else
    # Recompute residual size for any paths that survived (locked).
    local residual=0
    for entry in "${matches[@]}"; do
      [ -e "$entry" ] && residual=$((residual + $(sweep_size_bytes "$entry")))
    done
    local freed=$((before - residual))
    [ "$freed" -lt 0 ] && freed=0
    _SW_BYTES=$((_SW_BYTES + freed))
  fi
}

# Run an external command (apt-get clean, brew cleanup, etc.) and capture
# the size delta of an associated path. Honors SW_DRY_RUN.
sweep_command() {
  local size_path="$1"; shift
  local before after rc out
  before=$(sweep_size_bytes "$size_path" 2>/dev/null || echo 0)
  local cmd_kind="$1"
  local target_label="cmd:$*"
  # NOTE: in dry-run mode the caller passes the config's `dryCmd` (e.g.
  # `apt-get clean --simulate`), which is itself a safe simulation. We
  # still execute it so we get a real exit code + stderr, but we tag the
  # emitted target row as "would" instead of "removed".
  local emit_status="removed"
  [ "${SW_DRY_RUN:-0}" = "1" ] && emit_status="would"
  out=$("$@" 2>&1); rc=$?
  after=$(sweep_size_bytes "$size_path" 2>/dev/null || echo 0)
  local freed=$((before - after))
  [ "$freed" -lt 0 ] && freed=0
  _SW_BYTES=$((_SW_BYTES + freed))
  if [ "$rc" -eq 0 ]; then
    # Success: count the call as 1 logical "item" for parity with sweep counts.
    [ "$freed" -gt 0 ] && _SW_COUNT=$((_SW_COUNT + 1))
    _sw_emit_target "$emit_status" "$cmd_kind" "$target_label" "$freed" "exit=0 freed=${freed}B size_path=${size_path:-?}"
  else
    _SW_LOCKED=$((_SW_LOCKED + 1))
    _SW_LOCKS="${_SW_LOCKS}cmd:$*|exit=${rc}: $(printf '%s' "$out" | head -c 200)
"
    _sw_emit_target "failed" "$cmd_kind" "$target_label" 0 "exit=${rc}: $(printf '%s' "$out" | head -c 80)"
  fi
  printf '%s' "$out"
  return "$rc"
}