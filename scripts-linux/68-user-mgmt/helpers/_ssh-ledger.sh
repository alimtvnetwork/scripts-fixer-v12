#!/usr/bin/env bash
# Cross-OS SSH key state ledger (Unix side).
# Mirrors scripts/os/helpers/_ssh-ledger.ps1 -- same JSON schema at
# $HOME/.lovable/ssh-keys-state.json so a shared home dir keeps a unified
# history regardless of which OS performed the operation.
#
# Schema (top-level object):
#   { "version": 1, "host": "...", "user": "...", "updated": "ISO8601",
#     "entries": [ { "ts","action","fingerprint","keyPath","source","comment","host","user" } ] }
#
# CODE-RED: every IO failure logs the exact path + reason via log_err / log_warn
# (defined in _common.sh; falls back to stderr printf if not loaded).

if [ "${__UM_SSH_LEDGER_LOADED:-0}" = "1" ]; then return 0; fi
__UM_SSH_LEDGER_LOADED=1

_um_ledger_log() {
  local level="$1"; shift
  if command -v log_err >/dev/null 2>&1 && [ "$level" = "err" ]; then log_err "$@"
  elif command -v log_warn >/dev/null 2>&1 && [ "$level" = "warn" ]; then log_warn "$@"
  else printf '[%s] %s\n' "$level" "$*" >&2; fi
}

um_ledger_path() {
  printf '%s/.lovable/ssh-keys-state.json' "${HOME:-/root}"
}

um_ledger_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# um_ledger_add <action> <fingerprint> <keyPath> <source> [<comment>]
um_ledger_add() {
  local action="$1" fp="${2:-}" kp="${3:-}" src="${4:-}" cmt="${5:-}"
  local path host user dir tmp
  path=$(um_ledger_path)
  dir=$(dirname "$path")
  host=$(hostname 2>/dev/null || echo "?")
  user=$(id -un 2>/dev/null || echo "?")

  if ! command -v jq >/dev/null 2>&1; then
    _um_ledger_log warn "jq not found -- skipping SSH ledger write at exact path: '$path'"
    return 0
  fi

  if ! mkdir -p "$dir" 2>/dev/null; then
    _um_ledger_log err "Failed to create ledger dir at exact path: '$dir' (failure: mkdir refused)"
    return 1
  fi
  chmod 700 "$dir" 2>/dev/null || true

  if [ ! -f "$path" ]; then
    if ! printf '{"version":1,"host":"%s","user":"%s","updated":"%s","entries":[]}\n' \
         "$host" "$user" "$(um_ledger_now)" > "$path" 2>/dev/null; then
      _um_ledger_log err "Failed to seed ledger at exact path: '$path' (failure: write refused)"
      return 1
    fi
    chmod 600 "$path" 2>/dev/null || true
  fi

  tmp="$path.tmp.$$"
  if jq --arg ts   "$(um_ledger_now)" \
        --arg act  "$action" \
        --arg fp   "$fp" \
        --arg kp   "$kp" \
        --arg src  "$src" \
        --arg cmt  "$cmt" \
        --arg host "$host" \
        --arg user "$user" \
     '.updated = $ts
      | .entries += [ {ts:$ts, action:$act, fingerprint:$fp, keyPath:$kp,
                       source:$src, comment:$cmt, host:$host, user:$user} ]' \
     "$path" > "$tmp" 2>/dev/null
  then
    if mv -f "$tmp" "$path"; then
      chmod 600 "$path" 2>/dev/null || true
      return 0
    else
      _um_ledger_log err "Failed to swap ledger at exact path: '$path' (failure: mv refused)"
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
  else
    _um_ledger_log err "Failed to update ledger at exact path: '$path' (failure: jq returned non-zero)"
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
}
