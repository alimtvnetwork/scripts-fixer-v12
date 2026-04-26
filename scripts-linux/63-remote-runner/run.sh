#!/usr/bin/env bash
# 63-remote-runner
# Run a command on one host, a group, or every host defined in config.json.
# Defaults to PASSWORD auth via sshpass; supports key auth and interactive
# password prompts. Logs each session to .logs/63/<TS>-<target>.log.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="63"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
SAMPLE="$SCRIPT_DIR/config.sample.json"
SESSION_DIR="$ROOT/.logs/63"
GITIGNORE_LINE="scripts-linux/63-remote-runner/config.json"

# ---------- bootstrap ----------
ensure_config_or_exit() {
  if [ -f "$CONFIG" ]; then return 0; fi
  log_warn "[63] config.json missing -- copy config.sample.json -> config.json and edit"
  log_info "[63]   cp $SAMPLE $CONFIG"
  log_info "[63]   chmod 600 $CONFIG   # the script does this for you next run"
  exit 1
}

tighten_config_perms() {
  # chmod 600 -- file contains plaintext passwords by default
  if [ "$(stat -c '%a' "$CONFIG" 2>/dev/null)" != "600" ]; then
    chmod 600 "$CONFIG" 2>/dev/null && log_ok "[63] config.json permissions tightened to 600"
  fi
}

ensure_gitignore() {
  # Walk up from $ROOT looking for .gitignore (project root)
  local d="$ROOT" gi=""
  while [ "$d" != "/" ]; do
    if [ -f "$d/.gitignore" ]; then gi="$d/.gitignore"; break; fi
    d=$(dirname "$d")
  done
  [ -n "$gi" ] || return 0
  if ! grep -Fxq "$GITIGNORE_LINE" "$gi" 2>/dev/null; then
    {
      echo ""
      echo "# 63-remote-runner -- never commit host inventory with passwords"
      echo "$GITIGNORE_LINE"
    } >> "$gi"
    log_ok "[63] Added '$GITIGNORE_LINE' to $gi (security)"
  fi
}

ensure_deps() {
  local missing=()
  has_jq         || missing+=("jq")
  command -v ssh >/dev/null 2>&1 || missing+=("openssh-client")
  command -v sshpass >/dev/null 2>&1 || missing+=("sshpass")
  if [ "${#missing[@]}" -eq 0 ]; then return 0; fi
  log_info "[63] Installing required deps: ${missing[*]}"
  if is_apt_available; then
    sudo apt-get install -y "${missing[@]}" || {
      for d in "${missing[@]}"; do
        log_err "[63] Missing dep: $d (apt install $d)"
      done
      return 1
    }
  else
    for d in "${missing[@]}"; do log_err "[63] Missing dep: $d"; done
    return 1
  fi
}

# ---------- target resolution ----------
# Echo space-separated host *names* for the given target spec.
#   all                -> every host in groups.all if defined, else every host[].name
#   group:<name>       -> every host name in groups.<name>
#   host:<name>        -> just <name>
#   <bare-name>        -> if it's a group key -> group; else treat as host name
resolve_target() {
  local target="$1"
  case "$target" in
    all)
      if jq -e '.groups.all' "$CONFIG" >/dev/null 2>&1; then
        jq -r '.groups.all[]' "$CONFIG"
      else
        jq -r '.hosts[].name' "$CONFIG"
      fi
      ;;
    group:*)
      local name="${target#group:}"
      jq -er ".groups[\"$name\"][]?" "$CONFIG" 2>/dev/null
      ;;
    host:*)
      echo "${target#host:}"
      ;;
    *)
      # ambiguous: try group first, then host
      if jq -e ".groups[\"$target\"]" "$CONFIG" >/dev/null 2>&1; then
        jq -r ".groups[\"$target\"][]" "$CONFIG"
      else
        echo "$target"
      fi
      ;;
  esac
}

# ---------- per-host record ----------
# Echo TAB-separated: name<TAB>host<TAB>user<TAB>port<TAB>auth<TAB>password<TAB>identity<TAB>connect_timeout
host_record() {
  local name="$1"
  jq -r --arg n "$name" '
    (.defaults // {}) as $d
    | (.hosts[] | select(.name == $n)) as $h
    | if $h == null then "MISSING" else
        [
          $h.name,
          ($h.host // $h.name),
          ($h.user                       // $d.user                       // "root"),
          (($h.port                      // $d.port                       // 22) | tostring),
          ($h.auth                       // $d.auth                       // "password"),
          ($h.password                   // $d.password                   // ""),
          ($h.identity_file              // $d.identity_file              // ""),
          (($h.connect_timeout           // $d.connect_timeout            // 8) | tostring)
        ] | @tsv
      end
  ' "$CONFIG"
}

# ---------- runner ----------
SESSION_LOG=""
init_session_log() {
  ensure_dir "$SESSION_DIR" || return 0
  local ts; ts=$(date '+%Y%m%d-%H%M%S')
  local target_safe; target_safe=$(echo "$1" | tr -c 'A-Za-z0-9._-' '_')
  SESSION_LOG="$SESSION_DIR/$ts-$target_safe.log"
  {
    echo "# Session: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Target:  $1"
    echo "# Command: $2"
    echo "# ---"
  } >> "$SESSION_LOG"
  log_info "[63] Session log: $SESSION_LOG"
}

prompt_password_if_needed() {
  # $1 = host name, $2 = current pw (may be empty)
  local name="$1" pw="$2"
  if [ -n "$pw" ]; then printf '%s' "$pw"; return 0; fi
  log_warn "[63] No password set for $name -- prompt user" >&2
  printf 'Password for %s: ' "$name" >&2
  local entered=""
  if [ -t 0 ]; then
    stty -echo 2>/dev/null
    IFS= read -r entered
    stty echo  2>/dev/null
    printf '\n' >&2
  else
    IFS= read -r entered
  fi
  printf '%s' "$entered"
}

# Run command on one host. Echos one of: OK|FAIL|AUTH|UNREACH plus exit code + duration.
run_on_host() {
  local name="$1" cmd="$2" dry="$3"
  local rec; rec=$(host_record "$name")
  if [ "$rec" = "MISSING" ]; then
    log_err "[63] Unknown host or group: '$name'"
    return 2
  fi
  IFS=$'\t' read -r h_name h_host h_user h_port h_auth h_pw h_id h_to <<<"$rec"

  if [ "$dry" = "1" ]; then
    log_info "[63] [DRY-RUN] would run on $h_name ($h_user@$h_host:$h_port): $cmd"
    return 0
  fi

  local ssh_opts=( -o "ConnectTimeout=$h_to" -o "BatchMode=no" -p "$h_port" )
  local strict
  strict=$(jq -r '.defaults.strict_host_key_checking // false' "$CONFIG")
  if [ "$strict" = "false" ]; then
    ssh_opts+=( -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" -o "LogLevel=ERROR" )
  fi

  local target_user_host="$h_user@$h_host"
  local t0 t1 dur rc=0 out

  log_info "[63] [$h_name] >>> $cmd"
  t0=$(date +%s)

  case "$h_auth" in
    key)
      local id="${h_id/#\~/$HOME}"
      [ -n "$id" ] && ssh_opts+=( -i "$id" )
      out=$(ssh "${ssh_opts[@]}" "$target_user_host" "$cmd" 2>&1)
      rc=$?
      ;;
    password|*)
      local pw; pw=$(prompt_password_if_needed "$h_name" "$h_pw")
      if [ -z "$pw" ]; then
        log_err "[63] [$h_name] AUTH FAIL -- no password provided"
        return 5
      fi
      # Use SSHPASS env to avoid putting password on argv.
      out=$(SSHPASS="$pw" sshpass -e ssh "${ssh_opts[@]}" "$target_user_host" "$cmd" 2>&1)
      rc=$?
      ;;
  esac

  t1=$(date +%s); dur=$((t1 - t0))

  # Log full output to session log (one block per host)
  if [ -n "$SESSION_LOG" ]; then
    {
      echo ""
      echo "## [$h_name] exit=$rc dur=${dur}s"
      printf '%s\n' "$out"
    } >> "$SESSION_LOG"
  fi

  # Echo command output to console (indented)
  printf '%s\n' "$out" | sed "s/^/    [$h_name] /"

  case "$rc" in
    0)   log_ok   "[63] [$h_name] OK (exit=0, ${dur}s)" ;;
    5)   log_err  "[63] [$h_name] AUTH FAIL -- check user/password/identity_file" ;;
    255) log_err  "[63] [$h_name] UNREACHABLE (timeout ${h_to}s) -- check IP/port/firewall" ;;
    *)   log_err  "[63] [$h_name] FAIL (exit=$rc, ${dur}s)" ;;
  esac
  return $rc
}

# ---------- verbs ----------
verb_run() {
  local target="" cmd="" dry=0 parallel=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)   dry=1; shift ;;
      --parallel)  parallel="${2:-1}"; shift 2 ;;
      --)          shift; cmd="$*"; break ;;
      -h|--help)   verb_help; return 0 ;;
      *)
        if [ -z "$target" ]; then target="$1"; shift
        elif [ -z "$cmd" ]; then cmd="$1"; shift
        else cmd="$cmd $1"; shift
        fi
        ;;
    esac
  done

  [ -n "$target" ] || { log_err "[63] missing <target>";   verb_help; return 2; }
  [ -n "$cmd"    ] || { log_err "[63] missing <command>";  verb_help; return 2; }

  ensure_config_or_exit
  tighten_config_perms
  ensure_gitignore
  ensure_deps || return 1

  local hosts; hosts=$(resolve_target "$target")
  if [ -z "$hosts" ]; then
    log_warn "[63] Target '$target' resolved to 0 hosts -- nothing to do"
    return 0
  fi
  local n; n=$(printf '%s\n' "$hosts" | wc -l)
  log_info "[63] Target '$target' resolved to $n host(s): $(echo "$hosts" | tr '\n' ' ')"

  init_session_log "$target" "$cmd"

  local ok=0 fail=0 skip=0
  # Parallel mode is intentionally simple: background jobs + wait + per-host exit code via files.
  if [ "$parallel" -gt 1 ] && [ "$dry" = "0" ]; then
    log_info "[63] Parallel mode: $parallel concurrent hosts"
    local rcdir; rcdir=$(mktemp -d)
    local active=0
    for name in $hosts; do
      ( run_on_host "$name" "$cmd" "$dry"; echo $? > "$rcdir/$name.rc" ) &
      active=$((active + 1))
      if [ "$active" -ge "$parallel" ]; then wait -n 2>/dev/null || wait; active=$((active - 1)); fi
    done
    wait
    for name in $hosts; do
      local rc; rc=$(cat "$rcdir/$name.rc" 2>/dev/null || echo 99)
      if [ "$rc" = "0" ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done
    rm -rf "$rcdir"
  else
    for name in $hosts; do
      if run_on_host "$name" "$cmd" "$dry"; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done
  fi

  local total=$((ok + fail + skip))
  log_info "[63] Summary: $ok ok, $fail fail, $skip skipped (total $total)"
  [ "$fail" = "0" ]
}

verb_list() {
  ensure_config_or_exit
  echo ""
  echo "Hosts:"
  jq -r '.hosts[] | "  \(.name)  \(.user // "-")@\(.host // .name):\(.port // 22)  auth=\(.auth // "password")"' "$CONFIG"
  echo ""
  echo "Groups:"
  jq -r '.groups | to_entries[] | "  \(.key) -> [\(.value | join(", "))]"' "$CONFIG"
  echo ""
}

verb_check() {
  ensure_config_or_exit
  ensure_deps || return 1
  local target="${1:-all}"
  local hosts; hosts=$(resolve_target "$target")
  [ -n "$hosts" ] || { log_warn "[63] no hosts for '$target'"; return 1; }
  local ok=0 bad=0
  for name in $hosts; do
    local rec; rec=$(host_record "$name")
    [ "$rec" = "MISSING" ] && { log_err "[63] [$name] not in config"; bad=$((bad+1)); continue; }
    IFS=$'\t' read -r _ h_host _ h_port _ _ _ h_to <<<"$rec"
    if timeout "$h_to" bash -c "</dev/tcp/$h_host/$h_port" 2>/dev/null; then
      log_ok "[63] [$name] reachable ($h_host:$h_port)"
      ok=$((ok+1))
    else
      log_err "[63] [$name] UNREACHABLE ($h_host:$h_port, timeout ${h_to}s)"
      bad=$((bad+1))
    fi
  done
  log_info "[63] Reachability: $ok ok, $bad bad"
  [ "$bad" = "0" ]
}

verb_help() {
  cat <<'TXT'

  63-remote-runner -- Multi-host SSH command executor

  Usage:
    run.sh run <target> -- "<command>"   [--parallel N] [--dry-run]
    run.sh list
    run.sh check [<target>]
    run.sh help

  Targets:
    all                 every host in groups.all (or every host[] if undefined)
    group:<name>        all hosts in groups.<name>
    host:<name>         single host by name
    <bare-name>         resolved as group first, then as host

  Examples:
    run.sh run all -- "uptime"
    run.sh run group:web -- "sudo systemctl restart nginx"
    run.sh run host:db-1 -- "df -h /var/lib/postgresql"
    run.sh run web -- "hostname" --parallel 4
    run.sh run all -- "whoami" --dry-run

  Auth (per-host or defaults.auth):
    password   uses sshpass; reads from .password or prompts
    key        uses ssh -i .identity_file (~ expanded)

  Security:
    config.json is auto-chmod 600 and added to .gitignore on every run.
    Passwords are passed via SSHPASS env (never on argv).
    Use 'auth: key' for production -- password mode is for lab/training.

TXT
}

# ---------- entry ----------
case "${1:-help}" in
  run)        shift; verb_run "$@" ;;
  list)       verb_list ;;
  check)      shift; verb_check "$@" ;;
  help|-h|--help|"") verb_help ;;
  install)
    # The dispatcher calls install -- treat it as a no-op bootstrap that
    # creates config.json from sample if absent, tightens perms, updates gitignore.
    if [ ! -f "$CONFIG" ]; then
      cp "$SAMPLE" "$CONFIG" && log_ok "[63] Created config.json from sample (edit it before running 'run')"
    fi
    tighten_config_perms
    ensure_gitignore
    ensure_deps || true
    log_info "[63] Bootstrap complete. Edit $CONFIG, then: run.sh run all -- \"hostname\""
    ;;
  *) log_err "[63] Unknown verb: $1"; verb_help; exit 2 ;;
esac
