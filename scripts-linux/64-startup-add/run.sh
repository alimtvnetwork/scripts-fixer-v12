#!/usr/bin/env bash
# 64-startup-add  --  Cross-OS startup-add (apps + env vars), Unix side.
# Subverbs: app | env | list | remove
# Methods are auto-detected per OS (Linux: autostart|systemd-user|shell-rc;
# macOS: launchagent|login-item|shell-rc). Use --interactive for picker.
#
# Per-run logs: $ROOT/.logs/64/<TIMESTAMP>/{command.txt,manifest.json,session.log}
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="64"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
LOGS_ROOT="$ROOT/.logs/64"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOGS_ROOT/$TS"

# helpers loaded in later steps (8-11). Stub-tolerant for now.
[ -f "$SCRIPT_DIR/helpers/detect.sh" ]       && . "$SCRIPT_DIR/helpers/detect.sh"
[ -f "$SCRIPT_DIR/helpers/methods-linux.sh" ]&& . "$SCRIPT_DIR/helpers/methods-linux.sh"
[ -f "$SCRIPT_DIR/helpers/methods-macos.sh" ]&& . "$SCRIPT_DIR/helpers/methods-macos.sh"
[ -f "$SCRIPT_DIR/helpers/enumerate.sh" ]    && . "$SCRIPT_DIR/helpers/enumerate.sh"

ensure_run_dir() {
  mkdir -p "$RUN_DIR/hosts" 2>/dev/null \
    || { log_file_error "$RUN_DIR" "mkdir failed"; return 1; }
  printf '%s\n' "$0 $*" > "$RUN_DIR/command.txt"
  ln -sfn "$TS" "$LOGS_ROOT/latest" 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage: ./run.sh -I 64 -- <subverb> [args]

Subverbs:
  app  <path>     [--method M] [--name N] [--args "..."] [--interactive]
  env  KEY=VALUE  [--scope user] [--method shell-rc|systemd-env|launchctl]
  list            [--scope user|all]
  remove <name>   [--method ...]

Linux methods : autostart | systemd-user | shell-rc
macOS  methods: launchagent | login-item | shell-rc

Default per OS (when --method omitted):
  Linux GUI    -> autostart
  Linux headless -> systemd-user
  macOS        -> launchagent
EOF
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    app|startup-app)               ensure_run_dir; cmd_app    "$@"; exit $? ;;
    env|startup-env)               ensure_run_dir; cmd_env    "$@"; exit $? ;;
    list|startup-list|ls)          cmd_list   "$@"; exit $? ;;
    remove|startup-remove|rm|del)  ensure_run_dir; cmd_remove "$@"; exit $? ;;
    prune|startup-prune|purge)     ensure_run_dir; cmd_prune  "$@"; exit $? ;;
    ""|help|-h|--help) usage; exit 0 ;;
    *) log_warn "[64] Unknown subverb: '$sub'"; usage; exit 1 ;;
  esac
}

# ---- helpers for cmd_app / cmd_env ----

_pick_default_method_app() {
  # Use detect_default_app_method if available; else hard-code by OS.
  if declare -f detect_default_app_method >/dev/null 2>&1; then
    detect_default_app_method
    return $?
  fi
  case "$(uname -s)" in
    Darwin) echo "launchagent" ;;
    *)      [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && echo "autostart" || echo "systemd-user" ;;
  esac
}

_dispatch_app_method() {
  local method="$1" name="$2" path="$3" args="$4"
  case "$method" in
    autostart)    write_autostart_desktop "$name" "$path" "$args" ;;
    systemd-user) write_systemd_user_unit "$name" "$path" "$args" ;;
    shell-rc)     append_shell_rc_app     "$name" "$path" "$args" ;;
    launchagent)  write_launchagent_plist "$name" "$path" "$args" ;;
    login-item)   add_login_item          "$name" "$path" "false" ;;
    *) log_file_error "(method=$method)" "unsupported app method"; return 1 ;;
  esac
}

_dispatch_env_method() {
  local method="$1" key="$2" value="$3"
  case "$method" in
    shell-rc)  write_shell_rc_env  "$key" "$value" ;;
    launchctl) write_launchctl_env "$key" "$value" ;;
    *) log_file_error "(method=$method)" "unsupported env method"; return 1 ;;
  esac
}

cmd_app() {
  local path="" name="" method="" args=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --method) method="${2:-}"; shift 2 ;;
      --name)   name="${2:-}";   shift 2 ;;
      --args)   args="${2:-}";   shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) [ -z "$path" ] && path="$1" || log_warn "[64] ignoring extra arg: $1"; shift ;;
    esac
  done
  if [ -z "$path" ]; then
    log_warn "[64] app: <path> required"; usage; return 1
  fi
  [ -z "$name" ]   && name="$(basename "$path" | sed 's/\.[^.]*$//')"
  [ -z "$method" ] && method="$(_pick_default_method_app)"
  log_info "[64] app add: name=$name method=$method path=$path args='$args'"
  _dispatch_app_method "$method" "$name" "$path" "$args"
}

cmd_env() {
  local kv="" method="shell-rc" scope="user"
  while [ $# -gt 0 ]; do
    case "$1" in
      --method) method="${2:-shell-rc}"; shift 2 ;;
      --scope)  scope="${2:-user}";      shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) [ -z "$kv" ] && kv="$1" || log_warn "[64] ignoring extra arg: $1"; shift ;;
    esac
  done
  if [ -z "$kv" ] || ! printf '%s' "$kv" | grep -q '='; then
    log_warn "[64] env: KEY=VALUE required"; usage; return 1
  fi
  local key="${kv%%=*}" value="${kv#*=}"
  log_info "[64] env add: key=$key method=$method scope=$scope"
  _dispatch_env_method "$method" "$key" "$value"
}

cmd_list() {
  if ! declare -f list_startup_entries >/dev/null 2>&1; then
    log_file_error "$SCRIPT_DIR/helpers/enumerate.sh" "list_startup_entries not loaded"
    return 1
  fi
  local count=0
  printf 'METHOD          NAME                 PATH/ID\n'
  printf -- '--------------- -------------------- --------------------------------------------\n'
  while IFS=$'\t' read -r m n p _scope; do
    [ -z "${m:-}" ] && continue
    printf '%-15s %-20s %s\n' "$m" "$n" "$p"
    count=$((count+1))
  done < <(list_startup_entries)
  printf -- '--------------- -------------------- --------------------------------------------\n'
  printf '%d entr%s tagged "%s".\n' "$count" "$([ $count -eq 1 ] && echo y || echo ies)" "${STARTUP_TAG_PREFIX:-lovable-startup}"
  return 0
}

cmd_remove() {
  if ! declare -f remove_startup_entry >/dev/null 2>&1; then
    log_file_error "$SCRIPT_DIR/helpers/enumerate.sh" "remove_startup_entry not loaded"
    return 1
  fi
  local name="" method=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --method) method="${2:-}"; shift 2 ;;
      --all) method="ALL"; shift ;;
      -h|--help) usage; return 0 ;;
      *) [ -z "$name" ] && name="$1" || log_warn "[64] ignoring extra arg: $1"; shift ;;
    esac
  done
  if [ -z "$name" ]; then
    log_warn "[64] remove: <name> required"; usage; return 1
  fi

  # Primary defense: reject obviously hostile names BEFORE we touch anything.
  # The deeper guard inside remove_startup_entry is a backstop; this catches
  # callers that bypass enumerate-then-match and surfaces a clear non-zero
  # exit so scripts/tests can detect the rejection.
  case "$name" in
    */*|*..*)
      log_file_error "(name=$name)" "name contains path separators or traversal -- refusing"
      return 1 ;;
  esac

  # Method alias map: user types `shell-rc`, enumerators emit `shell-rc-app`
  # for app blocks and `shell-rc-env` for env blocks. Treat `shell-rc` as
  # "either of those". `ALL`/empty means "no filter".
  _method_matches() {
    local want="$1" got="$2"
    [ -z "$want" ] && return 0
    [ "$want" = "ALL" ] && return 0
    [ "$want" = "$got" ] && return 0
    if [ "$want" = "shell-rc" ]; then
      [ "$got" = "shell-rc-app" ] && return 0
      [ "$got" = "shell-rc-env" ] && return 0
    fi
    return 1
  }

  local rc=0 hits=0
  while IFS=$'\t' read -r m n _p _scope; do
    [ -z "${m:-}" ] && continue
    if [ "$n" = "$name" ] && _method_matches "$method" "$m"; then
      hits=$((hits+1))
      remove_startup_entry "$m" "$n" || rc=1
    fi
  done < <(list_startup_entries)

  if [ $hits -eq 0 ]; then
    log_warn "[64] no entries matched name='$name' method='${method:-any}'"
    # Idempotent no-op when caller didn't pin a method (sweep-style usage).
    # When a method WAS specified and nothing matched, it's still a no-op
    # by design (callers can re-run remove safely after prune).
  else
    log_ok "[64] removed $hits entr$([ $hits -eq 1 ] && echo y || echo ies) for '$name'"
  fi
  return $rc
}

# Sweep ALL tool-tagged entries in one shot. Idempotent: re-runs with nothing
# left return exit 0 with a warning. Optional --dry-run to preview.
cmd_prune() {
  if ! declare -f remove_startup_entry >/dev/null 2>&1; then
    log_file_error "$SCRIPT_DIR/helpers/enumerate.sh" "remove_startup_entry not loaded"
    return 1
  fi
  local dry=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) dry=1; shift ;;
      --yes|-y)     yes=1; shift ;;
      -h|--help)    usage; return 0 ;;
      *) log_warn "[64] ignoring extra arg: $1"; shift ;;
    esac
  done

  # Snapshot first so removals don't perturb the iteration.
  local snapshot; snapshot=$(list_startup_entries)
  if [ -z "$snapshot" ]; then
    log_info "[64] prune: nothing to remove (0 tool-tagged entries)"
    return 0
  fi

  local total; total=$(printf '%s\n' "$snapshot" | grep -c .)
  if [ "$dry" -eq 1 ]; then
    printf 'PRUNE PREVIEW (would remove %d entr%s):\n' "$total" "$([ $total -eq 1 ] && echo y || echo ies)"
    printf '  %s\n' $'METHOD\tNAME\tPATH/ID'
    printf '%s\n' "$snapshot" | awk -F'\t' '{ printf "  %-15s %-20s %s\n", $1, $2, $3 }'
    return 0
  fi

  if [ "$yes" -ne 1 ] && [ -t 0 ]; then
    printf '[64] prune will remove %d tool-tagged entr%s. Continue? [y/N] ' \
      "$total" "$([ $total -eq 1 ] && echo y || echo ies)" >&2
    read -r ans
    case "${ans:-}" in y|Y|yes) ;; *) log_info "[64] prune cancelled"; return 0 ;; esac
  fi

  local removed=0 failed=0
  while IFS=$'\t' read -r m n _p _scope; do
    [ -z "${m:-}" ] && continue
    if remove_startup_entry "$m" "$n"; then
      removed=$((removed+1))
    else
      failed=$((failed+1))
    fi
  done < <(printf '%s\n' "$snapshot")

  log_ok "[64] prune: removed $removed entr$([ $removed -eq 1 ] && echo y || echo ies)$([ $failed -gt 0 ] && echo " ($failed failed)")"
  [ $failed -eq 0 ]
}

main "$@"
