#!/usr/bin/env bash
# 64-startup-add :: methods-linux.sh
# Linux app methods: autostart (.desktop), systemd-user unit, shell-rc append.
# Plus the shared shell-rc env writer (also reused by macOS in step 10).
#
# All writers honour:
#   STARTUP_TAG_PREFIX   (default: "lovable-startup")
#   STARTUP_FORCE_REPLACE (default: 0)
# Every error path logs the exact file/path + reason (CODE RED rule).

STARTUP_TAG_PREFIX="${STARTUP_TAG_PREFIX:-lovable-startup}"
STARTUP_FORCE_REPLACE="${STARTUP_FORCE_REPLACE:-0}"

# ---- helpers ----
_tagged_name() { printf '%s-%s' "$STARTUP_TAG_PREFIX" "$1"; }

_xdg_autostart_dir() {
  printf '%s/autostart' "${XDG_CONFIG_HOME:-$HOME/.config}"
}
_systemd_user_dir() {
  printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

_ensure_dir() {
  local d="$1"
  if [ -d "$d" ]; then return 0; fi
  if mkdir -p "$d" 2>/dev/null; then return 0; fi
  log_file_error "$d" "mkdir failed"
  return 1
}

# ---- 1) autostart .desktop ----
write_autostart_desktop() {
  local name="$1" path="$2" args="${3:-}"
  local tagged; tagged=$(_tagged_name "$name")
  local dir;    dir=$(_xdg_autostart_dir)
  local file="$dir/${tagged}.desktop"

  _ensure_dir "$dir" || return 1

  if [ -f "$file" ] && [ "$STARTUP_FORCE_REPLACE" != "1" ]; then
    log_info "[64] entry already exists at $file -- replacing (upsert)"
  fi

  local exec_line="$path"
  [ -n "$args" ] && exec_line="$path $args"

  {
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Version=1.0\n'
    printf 'Name=%s\n' "$tagged"
    printf 'Comment=Managed by %s\n' "$STARTUP_TAG_PREFIX"
    printf 'Exec=%s\n' "$exec_line"
    printf 'Terminal=false\n'
    printf 'X-GNOME-Autostart-enabled=true\n'
    printf 'X-Lovable-Tag=%s\n' "$STARTUP_TAG_PREFIX"
    printf 'X-Lovable-Name=%s\n' "$name"
  } > "$file" 2>/dev/null \
      || { log_file_error "$file" "write failed"; return 1; }

  chmod 644 "$file" 2>/dev/null || true
  log_ok "[64] autostart entry written: $file"
  return 0
}

# ---- 2) systemd --user unit ----
write_systemd_user_unit() {
  local name="$1" path="$2" args="${3:-}"
  local tagged; tagged=$(_tagged_name "$name")
  local dir;    dir=$(_systemd_user_dir)
  local file="$dir/${tagged}.service"

  _ensure_dir "$dir" || return 1

  if [ -f "$file" ] && [ "$STARTUP_FORCE_REPLACE" != "1" ]; then
    log_info "[64] systemd unit already exists at $file -- replacing (upsert)"
  fi

  local exec_start="$path"
  [ -n "$args" ] && exec_start="$path $args"

  {
    printf '[Unit]\n'
    printf 'Description=Lovable startup entry: %s\n' "$name"
    printf 'After=default.target\n\n'
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'ExecStart=%s\n' "$exec_start"
    printf 'Restart=on-failure\n'
    printf 'RestartSec=5\n\n'
    printf '[Install]\n'
    printf 'WantedBy=default.target\n'
    printf 'X-Lovable-Tag=%s\n' "$STARTUP_TAG_PREFIX"
  } > "$file" 2>/dev/null \
      || { log_file_error "$file" "write failed"; return 1; }

  log_ok "[64] systemd user unit written: $file"

  # Try to enable -- not fatal in containers / CI without a user bus
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user daemon-reload >/dev/null 2>&1 \
        && systemctl --user enable "${tagged}.service" >/dev/null 2>&1; then
      log_ok "[64] systemctl --user enable ${tagged}.service"
    else
      log_warn "[64] systemctl --user enable ${tagged}.service failed (no user bus?). Unit still written -- run 'systemctl --user enable ${tagged}.service' interactively."
    fi
  fi

  # Optional linger for headless boxes
  if [ "${STARTUP_LINGER:-0}" = "1" ] && command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$USER" >/dev/null 2>&1; then
      log_ok "[64] loginctl enable-linger $USER"
    else
      log_warn "[64] loginctl enable-linger $USER failed (needs sudo? run manually for headless autostart)"
    fi
  fi
  return 0
}

# ---- 3) shell-rc append (apps) ----
append_shell_rc_app() {
  local name="$1" path="$2" args="${3:-}"
  local rc;      rc=$(detect_shell_rc)
  local tagged;  tagged=$(_tagged_name "$name")
  local marker_start="# >>> ${tagged} (lovable-startup-app) >>>"
  local marker_end="# <<< ${tagged} <<<"

  _ensure_dir "$(dirname "$rc")" || return 1
  [ -f "$rc" ] || { : > "$rc" || { log_file_error "$rc" "create failed"; return 1; }; }

  # Strip existing block (idempotent upsert)
  if grep -Fq "$marker_start" "$rc" 2>/dev/null; then
    if ! awk -v s="$marker_start" -v e="$marker_end" '
      $0==s {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$rc" > "$rc.tmp"; then
      log_file_error "$rc.tmp" "awk strip failed"
      rm -f "$rc.tmp" 2>/dev/null
      return 1
    fi
    mv "$rc.tmp" "$rc" || { log_file_error "$rc" "mv from tmp failed"; return 1; }
  fi

  local cmd="$path"
  [ -n "$args" ] && cmd="$path $args"

  {
    printf '\n%s\n' "$marker_start"
    printf '# Auto-run on shell startup (managed by %s)\n' "$STARTUP_TAG_PREFIX"
    printf 'if command -v "$(echo %q | awk \"{print \\$1}\")" >/dev/null 2>&1 || [ -x %q ]; then\n' "$cmd" "$path"
    printf '  %s &\n' "$cmd"
    printf 'fi\n'
    printf '%s\n' "$marker_end"
  } >> "$rc" 2>/dev/null \
      || { log_file_error "$rc" "append failed"; return 1; }

  log_ok "[64] shell-rc app entry appended to $rc (block: $tagged)"
  return 0
}

# ---- 4) shell-rc env writer (shared with macOS) ----
write_shell_rc_env() {
  local key="$1" value="$2"
  local rc;     rc=$(detect_shell_rc)
  local marker_start="# >>> ${STARTUP_TAG_PREFIX}-env (managed) >>>"
  local marker_end="# <<< ${STARTUP_TAG_PREFIX}-env <<<"
  # Always single-quote the value so spaces/specials survive sourcing.
  # Escape any embedded single quotes via the bash '\'' idiom.
  local escaped="${value//\'/\'\\\'\'}"
  local export_line="export ${key}='${escaped}'"

  _ensure_dir "$(dirname "$rc")" || return 1
  [ -f "$rc" ] || { : > "$rc" || { log_file_error "$rc" "create failed"; return 1; }; }

  if grep -Fq "$marker_start" "$rc" 2>/dev/null; then
    # Block exists. Strategy:
    #   1. awk strips the closing marker and any existing `export KEY=...`
    #      line inside the block.
    #   2. shell printf re-emits the new export_line + closing marker
    #      (so awk's -v handling never touches the literal value text).
    if ! awk -v s="$marker_start" -v e="$marker_end" -v key="$key" '
      BEGIN{ inblock=0 }
      $0==s { print; inblock=1; next }
      $0==e { inblock=0; next }   # drop closing marker; we re-emit
      inblock && $0 ~ ("^export "key"=") { next }
      { print }
    ' "$rc" > "$rc.tmp"; then
      log_file_error "$rc.tmp" "awk env-replace failed"
      rm -f "$rc.tmp" 2>/dev/null
      return 1
    fi
    {
      printf '%s\n' "$export_line"
      printf '%s\n' "$marker_end"
    } >> "$rc.tmp" 2>/dev/null \
        || { log_file_error "$rc.tmp" "env append-after-strip failed"; rm -f "$rc.tmp"; return 1; }
    mv "$rc.tmp" "$rc" || { log_file_error "$rc" "mv from tmp failed"; return 1; }
  else
    # Create the block at end of file
    {
      printf '\n%s\n' "$marker_start"
      printf '%s\n' "$export_line"
      printf '%s\n' "$marker_end"
    } >> "$rc" 2>/dev/null \
        || { log_file_error "$rc" "env append failed"; return 1; }
  fi

  log_ok "[64] shell-rc env: ${key} written to $rc (in marker block)"
  return 0
}

# Allow direct invocation for debugging:
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  . "$(dirname "$0")/../../_shared/logger.sh"
  . "$(dirname "$0")/../../_shared/file-error.sh"
  . "$(dirname "$0")/detect.sh"
  fn="${1:-write_autostart_desktop}"; shift || true
  "$fn" "$@"
fi
