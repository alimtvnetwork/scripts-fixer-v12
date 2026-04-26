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
    app)    ensure_run_dir; cmd_app    "$@"; exit $? ;;
    env)    ensure_run_dir; cmd_env    "$@"; exit $? ;;
    list)   cmd_list   "$@"; exit $? ;;
    remove) ensure_run_dir; cmd_remove "$@"; exit $? ;;
    ""|help|-h|--help) usage; exit 0 ;;
    *) log_warn "[64] Unknown subverb: '$sub'"; usage; exit 1 ;;
  esac
}

# cmd_app + cmd_env still stubbed (waiting for Step 12 wiring); list + remove are live.
cmd_app()    { log_warn "[64] cmd_app wiring lands in Step 12 -- helpers ready (write_autostart_desktop / write_launchagent_plist / etc.)"; return 0; }
cmd_env()    { log_warn "[64] cmd_env wiring lands in Step 12 -- helpers ready (write_shell_rc_env / write_launchctl_env)";                return 0; }

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

  local rc=0 hits=0
  while IFS=$'\t' read -r m n _p _scope; do
    [ -z "${m:-}" ] && continue
    if [ "$n" = "$name" ] && { [ -z "$method" ] || [ "$method" = "ALL" ] || [ "$method" = "$m" ]; }; then
      hits=$((hits+1))
      remove_startup_entry "$m" "$n" || rc=1
    fi
  done < <(list_startup_entries)

  if [ $hits -eq 0 ]; then
    log_warn "[64] no entries matched name='$name' method='${method:-any}'"
  else
    log_ok "[64] removed $hits entr$([ $hits -eq 1 ] && echo y || echo ies) for '$name'"
  fi
  return $rc
}

main "$@"
