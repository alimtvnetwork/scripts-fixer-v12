#!/usr/bin/env bash
# scripts-orchestrator/run.sh -- root dispatcher.
# Subcommands: bootstrap, run, playbook, inventory, log
set -u

ORCH_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/01-logger.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/02-os-detect.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/03-ssh-exec.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/04-parallel.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/05-vault.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/06-sqlite-audit.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/07-inventory.sh"
# shellcheck disable=SC1091
. "$ORCH_DIR/lib/08-bootstrap.sh"

INVENTORY_DIR="${INVENTORY_DIR:-$ORCH_DIR/inventory}"
[ -d "$INVENTORY_DIR" ] || INVENTORY_DIR="$ORCH_DIR/inventory.example"
export INVENTORY_DIR

usage() {
  cat <<'EOF'
ssh-orchestrator -- multi-OS SSH dispatcher

Usage:
  run.sh bootstrap <host-alias>
      Password->key bootstrap for one host. Prompts for password.

  run.sh run "<inline-cmd>" --group <group> [--parallel N] [--on-error mode]
      Run an inline command on every host in <group>. Requires --allow-inline.

  run.sh playbook <name> --group <group> [--role control-plane|worker]
      Run a playbook directory under playbooks/<name>/.
      Optional, repeatable:
        --with-env  KEY=VALUE       Export KEY on each remote before each step.
        --with-file ENV_KEY=path    base64-encode the local file and export it
                                    as ENV_KEY on each remote (use for the
                                    fanout playbooks: USERS_JSON_B64 / GROUPS_JSON_B64
                                    / KEYS_B64).

  run.sh inventory list | show <alias>
      Inspect parsed inventory.

  run.sh log tail
      Tail the audit log.

  run.sh --version
      Print the orchestrator version.

Environment:
  INVENTORY_DIR   default: scripts-orchestrator/inventory  (falls back to .example)
  DB_PATH         default: ~/.local/share/ssh-orchestrator/orchestrator.sqlite
  ORCH_HOME       default: ~/.ssh/Orchestrator
EOF
}

ORCH_VERSION="0.1.0"

cmd_bootstrap() {
  [ $# -ge 1 ] || { usage; exit 2; }
  ensure_db
  bootstrap_host "$1"
}

cmd_run() {
  local cmd="" group="" parallel=8 on_error="failAfterAll" allow_inline=0
  cmd="$1"; shift || { usage; exit 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --group)         group="$2"; shift 2;;
      --parallel)      parallel="$2"; shift 2;;
      --on-error)      on_error="$2"; shift 2;;
      --allow-inline)  allow_inline=1; shift;;
      *) log_error "run: unknown flag $1"; exit 2;;
    esac
  done
  if [ "$allow_inline" -ne 1 ]; then
    log_error "run: inline commands require --allow-inline (audited verbatim)"
    exit 2
  fi
  [ -n "$group" ] || { log_error "run: --group required"; exit 2; }

  local hosts
  hosts="$(inventory_hosts_in_group "$group")"
  if [ -z "$hosts" ]; then
    log_error "run: no hosts found in group=$group"
    exit 1
  fi

  ensure_db
  local exec_id; exec_id="exec-$(date +%s)-$$"
  log_step "run: group=$group hosts=$(echo "$hosts" | wc -l) parallel=$parallel on-error=$on_error"

  _job() {
    local h="$1" t0 rc
    t0="$(date +%s)"
    log_info "[$h] >>> $cmd"
    if ssh_run "$h" "$cmd"; then rc=0; else rc=$?; fi
    audit_log "InlineRun" "$h" "$exec_id" "rc=$rc cmd=$cmd"
    log_dim "[$h] <<< rc=$rc dt=$(( $(date +%s) - t0 ))s"
    return "$rc"
  }
  # shellcheck disable=SC2086
  run_parallel "$parallel" _job -- $hosts
  local fails=$?
  if [ "$fails" -gt 0 ]; then
    log_error "run: $fails host(s) failed"
    [ "$on_error" = "failFast" ] && exit 1
    exit 1
  fi
  log_ok "run: all hosts succeeded"
}

cmd_playbook() {
  local name="" group="" role=""
  local -a env_pairs=()       # KEY=VAL pairs to export on remote
  local -a file_pairs=()      # ENV_KEY=path pairs to base64-load
  name="$1"; shift || { usage; exit 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) group="$2"; shift 2;;
      --role)  role="$2";  shift 2;;
      --with-env)
        env_pairs+=("$2"); shift 2;;
      --with-file)
        file_pairs+=("$2"); shift 2;;
      *) log_error "playbook: unknown flag $1"; exit 2;;
    esac
  done
  [ -n "$group" ] || { log_error "playbook: --group required"; exit 2; }
  local pb_dir="$ORCH_DIR/playbooks/$name"
  if [ ! -d "$pb_dir" ]; then
    log_file_error "$pb_dir" "playbook: directory not found"
    exit 1
  fi
  local manifest="$pb_dir/playbook.json"
  if [ ! -f "$manifest" ]; then
    log_file_error "$manifest" "playbook: playbook.json not found"
    exit 1
  fi

  # Resolve --with-file pairs into additional env_pairs by base64-encoding
  # the local file. CODE-RED: every missing local file is named explicitly.
  for fp in "${file_pairs[@]}"; do
    local fkey="${fp%%=*}"
    local fpath="${fp#*=}"
    if [ -z "$fkey" ] || [ "$fkey" = "$fp" ]; then
      log_error "playbook: --with-file expects KEY=path, got '$fp'"
      exit 2
    fi
    if [ ! -f "$fpath" ]; then
      log_file_error "$fpath" "playbook: --with-file source not found"
      exit 1
    fi
    local b64
    b64=$(base64 -w0 < "$fpath" 2>/dev/null || base64 < "$fpath" | tr -d '\n')
    env_pairs+=("${fkey}=${b64}")
  done

  # Build the inlined env-export prefix once per playbook run.
  local env_prefix=""
  for kv in "${env_pairs[@]}"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    env_prefix+="export $(printf '%s=%q' "$k" "$v"); "
  done

  log_step "playbook: $name (group=$group role=${role:-any})"
  log_info  "playbook: see $manifest for ordered steps; this dispatcher runs each .sh in order on matching hosts"
  if [ "${#env_pairs[@]}" -gt 0 ]; then
    log_info "playbook: forwarding ${#env_pairs[@]} env var(s) to each host"
  fi
  local hosts; hosts="$(inventory_hosts_in_group "$group")"
  for h in $hosts; do
    local host_role; host_role="$(inventory_get_field "$h" role)"
    if [ -n "$role" ] && [ "$host_role" != "$role" ]; then
      log_dim "[$h] skip (role=$host_role does not match --role $role)"
      continue
    fi
    log_step "[$h] role=$host_role -- running playbook $name"
    for step in "$pb_dir"/[0-9][0-9]-*.sh; do
      [ -e "$step" ] || continue
      local base; base="$(basename "$step")"
      log_info "[$h] step $base"
      ssh_put "$h" "$step" "/tmp/$base" || return 1
      # Note: we use `sudo -E` so the env we exported is preserved into the
      # sudo'd step. The env_prefix runs BEFORE sudo so the parent shell
      # has the vars to forward.
      ssh_run "$h" "${env_prefix}chmod +x /tmp/$base && sudo -E /tmp/$base; rc=\$?; rm -f /tmp/$base; exit \$rc"
    done
  done
}

cmd_inventory() {
  case "${1:-list}" in
    list)
      [ -f "$INVENTORY_DIR/hosts.conf" ] || { log_file_error "$INVENTORY_DIR/hosts.conf" "inventory: file missing"; exit 1; }
      grep -E '^\[' "$INVENTORY_DIR/hosts.conf" | tr -d '[]'
      ;;
    show)
      [ -n "${2:-}" ] || { log_error "inventory show: alias required"; exit 2; }
      for f in hostname user port role group; do
        printf '%-10s = %s\n' "$f" "$(inventory_get_field "$2" "$f")"
      done
      ;;
    *) usage; exit 2;;
  esac
}

cmd_log() {
  ensure_db || exit 1
  case "${1:-tail}" in
    tail) sqlite3 -header -column "$DB_PATH" \
            "SELECT At, Event, HostId, ExecutionId, Detail FROM AuditLogs ORDER BY At DESC LIMIT 30;";;
    *) usage; exit 2;;
  esac
}

main() {
  if [ $# -eq 0 ]; then usage; exit 0; fi
  case "$1" in
    --version|-V) echo "ssh-orchestrator $ORCH_VERSION"; exit 0;;
    --help|-h)    usage; exit 0;;
    bootstrap)    shift; cmd_bootstrap "$@";;
    run)          shift; cmd_run "$@";;
    playbook)     shift; cmd_playbook "$@";;
    inventory)    shift; cmd_inventory "$@";;
    log)          shift; cmd_log "$@";;
    *) usage; exit 2;;
  esac
}
main "$@"
