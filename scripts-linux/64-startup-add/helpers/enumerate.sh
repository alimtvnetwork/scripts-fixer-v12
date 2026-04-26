#!/usr/bin/env bash
# 64-startup-add :: enumerate.sh
# Enumerate + remove startup entries written by this toolkit, identified by
# the STARTUP_TAG_PREFIX (default: "lovable-startup") across all 6 methods:
#   Linux : autostart .desktop, systemd --user unit, shell-rc app block
#   macOS : LaunchAgent plist, login item, launchctl setenv
# shell-rc env blocks are shared on both OSes.
#
# Output of list_startup_entries (TSV, stable):
#   <method>\t<name>\t<path-or-id>\t<scope>
# Errors always go through log_file_error <path> <reason>.

STARTUP_TAG_PREFIX="${STARTUP_TAG_PREFIX:-lovable-startup}"

# ---- per-method enumerators (each prints zero or more TSV lines) ----

_enum_autostart() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
  [ -d "$dir" ] || return 0
  local f name
  for f in "$dir/${STARTUP_TAG_PREFIX}-"*.desktop; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .desktop)
    name="${name#${STARTUP_TAG_PREFIX}-}"
    printf 'autostart\t%s\t%s\tuser\n' "$name" "$f"
  done
}

_enum_systemd_user() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  [ -d "$dir" ] || return 0
  local f name
  for f in "$dir/${STARTUP_TAG_PREFIX}-"*.service; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .service)
    name="${name#${STARTUP_TAG_PREFIX}-}"
    printf 'systemd-user\t%s\t%s\tuser\n' "$name" "$f"
  done
}

_enum_shell_rc_app() {
  # shellcheck disable=SC1090
  local rc; rc=$(detect_shell_rc 2>/dev/null) || return 0
  [ -f "$rc" ] || return 0
  # Markers look like:  # >>> lovable-startup-<name> (lovable-startup-app) >>>
  awk -v p="$STARTUP_TAG_PREFIX" -v rc="$rc" '
    $0 ~ ("^# >>> "p"-.+ \\("p"-app\\) >>>$") {
      n=$0
      sub("^# >>> "p"-", "", n)
      sub(" \\("p"-app\\) >>>$", "", n)
      printf "shell-rc-app\t%s\t%s\tuser\n", n, rc
    }
  ' "$rc"
}

_enum_launchagent() {
  local dir="$HOME/Library/LaunchAgents"
  [ -d "$dir" ] || return 0
  local f label name
  for f in "$dir/com.${STARTUP_TAG_PREFIX}."*.plist; do
    [ -f "$f" ] || continue
    label=$(basename "$f" .plist)
    name="${label#com.${STARTUP_TAG_PREFIX}.}"
    printf 'launchagent\t%s\t%s\tuser\n' "$name" "$f"
  done
}

_enum_login_item() {
  command -v osascript >/dev/null 2>&1 || return 0
  osascript <<APPLESCRIPT 2>/dev/null | awk -v p="$STARTUP_TAG_PREFIX" -F'\t' '
    $1 ~ ("^com\\."p"\\.") {
      n=$1; sub("^com\\."p"\\.", "", n)
      printf "login-item\t%s\t%s\tuser\n", n, $2
    }'
tell application "System Events"
  set out to ""
  repeat with li in (every login item)
    set out to out & (name of li) & tab & (path of li) & linefeed
  end repeat
  return out
end tell
APPLESCRIPT
}

_enum_shell_rc_env() {
  local rc; rc=$(detect_shell_rc 2>/dev/null) || return 0
  [ -f "$rc" ] || return 0
  if grep -Fq "# >>> ${STARTUP_TAG_PREFIX}-env (managed) >>>" "$rc" 2>/dev/null; then
    # One pseudo-entry per exported KEY in the block
    awk -v p="$STARTUP_TAG_PREFIX" -v rc="$rc" '
      $0=="# >>> "p"-env (managed) >>>" {inb=1; next}
      $0=="# <<< "p"-env <<<"          {inb=0; next}
      inb && $0 ~ /^export [A-Za-z_][A-Za-z0-9_]*=/ {
        k=$0; sub("^export ","",k); sub("=.*$","",k)
        printf "shell-rc-env\t%s\t%s\tuser\n", k, rc
      }
    ' "$rc"
  fi
}

# ---- public: list ----
list_startup_entries() {
  _enum_autostart
  _enum_systemd_user
  _enum_shell_rc_app
  _enum_launchagent
  _enum_login_item
  _enum_shell_rc_env
}

# ---- public: remove single entry ----
# remove_startup_entry <method> <name>
remove_startup_entry() {
  local method="$1" name="$2"

  # Defense in depth: refuse names that contain path-traversal or directory
  # separators. Tag-based enumerate would never produce them, but a hostile
  # caller could try `remove ../firefox --method autostart` to delete a
  # foreign file. The tag prefix is appended below so absolute paths get
  # neutered too, but reject early for clearer error.
  case "$name" in
    */*|*..*|"")
      log_file_error "(name=$name)" "name contains path separators or is empty -- refusing"
      return 1 ;;
  esac

  case "$method" in
    autostart)
      local f="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/${STARTUP_TAG_PREFIX}-${name}.desktop"
      # Re-validate that what we're about to rm has the tool tag prefix.
      case "$(basename "$f")" in "${STARTUP_TAG_PREFIX}-"*) ;;
        *) log_file_error "$f" "basename missing required '${STARTUP_TAG_PREFIX}-' prefix -- refusing"; return 1 ;;
      esac
      if [ ! -f "$f" ]; then log_warn "[64] autostart entry not found: $f"; return 0; fi
      rm -f "$f" || { log_file_error "$f" "rm failed"; return 1; }
      log_ok "[64] removed autostart: $f"
      ;;
    systemd-user)
      local tagged="${STARTUP_TAG_PREFIX}-${name}.service"
      local f="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${tagged}"
      case "$tagged" in "${STARTUP_TAG_PREFIX}-"*) ;;
        *) log_file_error "$f" "basename missing required '${STARTUP_TAG_PREFIX}-' prefix -- refusing"; return 1 ;;
      esac
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable "$tagged" >/dev/null 2>&1 || true
        systemctl --user stop    "$tagged" >/dev/null 2>&1 || true
      fi
      if [ -f "$f" ]; then
        rm -f "$f" || { log_file_error "$f" "rm failed"; return 1; }
        log_ok "[64] removed systemd-user unit: $f"
        command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 || true
      else
        log_warn "[64] systemd-user unit not found: $f"
      fi
      ;;
    shell-rc-app)
      local rc; rc=$(detect_shell_rc)
      [ -f "$rc" ] || { log_warn "[64] shell rc not found: $rc"; return 0; }
      local s="# >>> ${STARTUP_TAG_PREFIX}-${name} (${STARTUP_TAG_PREFIX}-app) >>>"
      local e="# <<< ${STARTUP_TAG_PREFIX}-${name} <<<"
      if ! awk -v s="$s" -v e="$e" '
        $0==s {skip=1; next}
        $0==e {skip=0; next}
        !skip {print}
      ' "$rc" > "$rc.tmp"; then
        log_file_error "$rc.tmp" "awk strip failed"
        rm -f "$rc.tmp"; return 1
      fi
      mv "$rc.tmp" "$rc" || { log_file_error "$rc" "mv from tmp failed"; return 1; }
      log_ok "[64] removed shell-rc app block: ${name} from $rc"
      ;;
    launchagent)
      local label="com.${STARTUP_TAG_PREFIX}.${name}"
      local f="$HOME/Library/LaunchAgents/${label}.plist"
      case "$label" in "com.${STARTUP_TAG_PREFIX}."*) ;;
        *) log_file_error "$f" "label missing required 'com.${STARTUP_TAG_PREFIX}.' prefix -- refusing"; return 1 ;;
      esac
      if command -v launchctl >/dev/null 2>&1 && [ -f "$f" ]; then
        launchctl bootout "gui/$(id -u)" "$f" >/dev/null 2>&1 || true
      fi
      if [ -f "$f" ]; then
        rm -f "$f" || { log_file_error "$f" "rm failed"; return 1; }
        log_ok "[64] removed LaunchAgent: $f"
      else
        log_warn "[64] LaunchAgent plist not found: $f"
      fi
      ;;
    login-item)
      if ! command -v osascript >/dev/null 2>&1; then
        log_warn "[64] osascript unavailable -- cannot remove login item ${name}"
        return 0
      fi
      local tagged="com.${STARTUP_TAG_PREFIX}.${name}"
      if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "System Events"
  delete login item "$tagged"
end tell
APPLESCRIPT
      then
        log_ok "[64] removed login item: $tagged"
      else
        log_warn "[64] login item not found or osascript failed: $tagged"
      fi
      ;;
    shell-rc-env)
      # name == KEY here
      local rc; rc=$(detect_shell_rc)
      [ -f "$rc" ] || { log_warn "[64] shell rc not found: $rc"; return 0; }
      local s="# >>> ${STARTUP_TAG_PREFIX}-env (managed) >>>"
      local e="# <<< ${STARTUP_TAG_PREFIX}-env <<<"
      # Buffer the WHOLE block in awk before deciding whether to keep it.
      # If the only line left would be the markers themselves, drop both
      # markers (and any blank line we naturally inserted before the block).
      if ! awk -v s="$s" -v e="$e" -v key="$name" '
        BEGIN { inb=0; kept=0; buf="" }
        $0==s { inb=1; buf=""; kept=0; next }                # swallow open marker
        inb && $0==e {
          if (kept>0) {
            # Re-emit the block verbatim, with markers
            printf "%s\n%s%s\n", s, buf, e
          }
          # else: block becomes empty -> drop markers entirely
          inb=0; buf=""; kept=0; next
        }
        inb && $0 ~ ("^export "key"=") { next }              # drop the targeted export
        inb { buf = buf $0 ORS; kept++; next }
        { print }
      ' "$rc" > "$rc.tmp"; then
        log_file_error "$rc.tmp" "awk env-remove failed"
        rm -f "$rc.tmp"; return 1
      fi
      mv "$rc.tmp" "$rc" || { log_file_error "$rc" "mv from tmp failed"; return 1; }
      log_ok "[64] removed shell-rc env: ${name} from $rc"
      ;;
    *)
      log_file_error "(method=$method)" "unknown remove method"
      return 1
      ;;
  esac
  return 0
}

# Allow direct invocation:
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  . "$(dirname "$0")/../../_shared/logger.sh"
  . "$(dirname "$0")/../../_shared/file-error.sh"
  . "$(dirname "$0")/detect.sh"
  fn="${1:-list_startup_entries}"; shift || true
  "$fn" "$@"
fi
