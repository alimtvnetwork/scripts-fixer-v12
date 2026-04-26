#!/usr/bin/env bash
# 64-startup-add :: detect.sh
# OS + session detection and safest-default method selection.
#
# Public functions (all echo their result; return 0/1 for boolean predicates):
#   detect_os               -> "linux" | "macos" | "unsupported:<uname>"
#   has_gui_session         -> 0 if a display server is reachable, else 1
#   has_systemd_user        -> 0 if `systemctl --user` is usable, else 1
#   detect_shell_rc         -> path to user's preferred rc file (zshrc > bashrc > profile)
#   default_app_method <os> -> safest default for current host
#   default_env_method <os> -> safest default for current host
#   methods_for <os> <kind> -> space-separated valid methods for kind=app|env
#   validate_method <os> <kind> <method> -> 0 ok, 1 invalid (prints reason)
#   pick_method_interactive <os> <kind>  -> echoes chosen method, return 0
#                                            (returns 1 + empty echo on quit)
#
# Pure bash, no external JSON parser. Reads minimal fields from config.json
# via grep/sed when needed (kept simple; we already lock the method names in
# this file's METHODS_* arrays so config drift surfaces in validate_method).

# --- method enums (must mirror config.json) ---
LINUX_APP_METHODS=("autostart" "systemd-user" "shell-rc")
LINUX_ENV_METHODS=("shell-rc" "systemd-env")
MACOS_APP_METHODS=("launchagent" "login-item" "shell-rc")
MACOS_ENV_METHODS=("shell-rc" "launchctl")

detect_os() {
  local u; u=$(uname -s 2>/dev/null || echo unknown)
  case "$u" in
    Linux)  echo "linux" ;;
    Darwin) echo "macos" ;;
    *)      echo "unsupported:$u" ;;
  esac
}

has_gui_session() {
  # Linux: $DISPLAY (X11) or $WAYLAND_DISPLAY (Wayland) or $XDG_CURRENT_DESKTOP
  # macOS: always true (Aqua is always the login session for a real user)
  local os; os=$(detect_os)
  if [ "$os" = "macos" ]; then return 0; fi
  if [ -n "${DISPLAY:-}" ]              ; then return 0; fi
  if [ -n "${WAYLAND_DISPLAY:-}" ]      ; then return 0; fi
  if [ -n "${XDG_CURRENT_DESKTOP:-}" ]  ; then return 0; fi
  return 1
}

has_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || return 1
  # `systemctl --user status` returns 0 even with no units; use show as a probe
  systemctl --user show-environment >/dev/null 2>&1
}

detect_shell_rc() {
  # Prefer the rc file matching the user's login shell, but fall back gracefully.
  local sh; sh=$(basename "${SHELL:-/bin/bash}")
  case "$sh" in
    zsh)  [ -f "$HOME/.zshrc"   ] && { echo "$HOME/.zshrc"  ; return 0; } ;;
    bash) [ -f "$HOME/.bashrc"  ] && { echo "$HOME/.bashrc" ; return 0; } ;;
  esac
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  # nothing exists yet -- prefer .zshrc on macOS (default shell since 10.15),
  # .bashrc on Linux
  local os; os=$(detect_os)
  if [ "$os" = "macos" ]; then echo "$HOME/.zshrc"; else echo "$HOME/.bashrc"; fi
}

default_app_method() {
  local os="${1:-$(detect_os)}"
  case "$os" in
    linux)
      if has_gui_session; then echo "autostart"
      elif has_systemd_user; then echo "systemd-user"
      else echo "shell-rc"
      fi ;;
    macos) echo "launchagent" ;;
    *)     echo "shell-rc" ;;
  esac
}

default_env_method() {
  local os="${1:-$(detect_os)}"
  # shell-rc is the universally-safe default (no service manager, no reboot)
  echo "shell-rc"
}

methods_for() {
  local os="$1" kind="$2"
  case "$os:$kind" in
    linux:app)  echo "${LINUX_APP_METHODS[*]}" ;;
    linux:env)  echo "${LINUX_ENV_METHODS[*]}" ;;
    macos:app)  echo "${MACOS_APP_METHODS[*]}" ;;
    macos:env)  echo "${MACOS_ENV_METHODS[*]}" ;;
    *)          echo "" ;;
  esac
}

validate_method() {
  local os="$1" kind="$2" method="$3"
  local valid; valid=$(methods_for "$os" "$kind")
  if [ -z "$valid" ]; then
    echo "no methods registered for os=$os kind=$kind" >&2
    return 1
  fi
  for m in $valid; do
    [ "$m" = "$method" ] && return 0
  done
  echo "invalid method '$method' for $os/$kind. Valid: $valid" >&2
  return 1
}

method_description() {
  case "$1" in
    autostart)    echo "~/.config/autostart/<name>.desktop  (XDG GUI session)" ;;
    systemd-user) echo "systemctl --user enable <name>.service  (headless OK with linger)" ;;
    shell-rc)     echo "Marker block appended to ~/.zshrc / ~/.bashrc" ;;
    launchagent)  echo "~/Library/LaunchAgents/<label>.plist + launchctl load" ;;
    login-item)   echo "macOS Login Items via osascript -> System Events" ;;
    systemd-env)  echo "systemctl --user set-environment KEY=VAL  (session-scoped)" ;;
    launchctl)    echo "launchctl setenv KEY VAL  (session-scoped, GUI apps)" ;;
    *)            echo "(no description)" ;;
  esac
}

pick_method_interactive() {
  local os="$1" kind="$2"
  local valid; valid=$(methods_for "$os" "$kind")
  [ -n "$valid" ] || return 1

  # Render UI to stderr so callers can capture the chosen method via stdout
  printf '\n' >&2
  printf '  Pick startup method for %s/%s:\n' "$os" "$kind" >&2
  local i=0 methods=() m
  for m in $valid; do
    i=$((i+1)); methods+=("$m")
    printf '    [%d] %-13s -- %s\n' "$i" "$m" "$(method_description "$m")" >&2
  done
  printf '\n  Choose [1-%d] or "q" to quit: ' "$i" >&2
  local reply=""
  if [ -t 0 ]; then
    read -r reply
  elif [ -e /dev/tty ]; then
    read -r reply </dev/tty
  fi
  case "$reply" in
    q|Q|quit|exit) return 1 ;;
    ''|*[!0-9]*)   return 1 ;;
  esac
  if [ "$reply" -ge 1 ] && [ "$reply" -le "$i" ]; then
    echo "${methods[$((reply-1))]}"
    return 0
  fi
  return 1
}

# Allow direct invocation for debugging:  bash detect.sh <fn> [args...]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fn="${1:-detect_os}"; shift || true
  "$fn" "$@"
fi
