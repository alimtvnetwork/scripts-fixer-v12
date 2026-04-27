#!/usr/bin/env bash
# Shared interactive prompt helpers used by --ask flows on the Unix side.
# Mirrors helpers/_prompt.ps1 on the Windows side. Plain `read` based; no
# extra dependencies. Reads/writes via /dev/tty so prompts stay visible
# even when stdout is captured (e.g. `out=$(... --ask)`).

if [ "${__UM_PROMPT_LOADED:-0}" = "1" ]; then return 0; fi
__UM_PROMPT_LOADED=1

# um_prompt_string <prompt> [default] [required:0|1]
um_prompt_string() {
  local prompt="$1" default="${2:-}" required="${3:-0}" val=""
  while :; do
    if [ -n "$default" ]; then
      printf '  ? %s [%s] : ' "$prompt" "$default" >/dev/tty
    else
      printf '  ? %s : ' "$prompt" >/dev/tty
    fi
    IFS= read -r val </dev/tty || val=""
    if [ -z "$val" ] && [ -n "$default" ]; then printf '%s' "$default"; return 0; fi
    if [ -z "$val" ] && [ "$required" = "1" ]; then
      printf '    (required)\n' >/dev/tty
      continue
    fi
    printf '%s' "$val"
    return 0
  done
}

# um_prompt_secret <prompt> [required:0|1]
um_prompt_secret() {
  local prompt="$1" required="${2:-0}" val=""
  while :; do
    printf '  ? %s (hidden) : ' "$prompt" >/dev/tty
    stty -echo </dev/tty 2>/dev/null
    IFS= read -r val </dev/tty || val=""
    stty echo </dev/tty 2>/dev/null
    printf '\n' >/dev/tty
    if [ -z "$val" ] && [ "$required" = "1" ]; then
      printf '    (required)\n' >/dev/tty
      continue
    fi
    printf '%s' "$val"
    return 0
  done
}

# um_prompt_confirm <prompt> [defaultYes:0|1] -> exit code (0=yes,1=no)
um_prompt_confirm() {
  local prompt="$1" defyes="${2:-0}" hint="[y/N]" val=""
  [ "$defyes" = "1" ] && hint="[Y/n]"
  printf '  ? %s %s : ' "$prompt" "$hint" >/dev/tty
  IFS= read -r val </dev/tty || val=""
  if [ -z "$val" ]; then [ "$defyes" = "1" ] && return 0 || return 1; fi
  case "$val" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
