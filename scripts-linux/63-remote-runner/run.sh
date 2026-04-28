#!/usr/bin/env bash
# 63-remote-runner
# Run a command on one host, a group, or every host defined in config.json.
# Defaults to PASSWORD auth via sshpass; supports key auth and interactive
# password prompts. Each invocation writes a structured run directory:
#   .logs/63/<TIMESTAMP>-<target>/
#     ├── command.txt              exact command run
#     ├── session.log              combined chronological log
#     ├── manifest.json            machine-readable summary
#     └── hosts/
#         ├── <name>.log           raw stdout+stderr per host
#         └── <name>.meta.json     {host, exit, duration, ts_start, ts_end, status}
# A 'latest' symlink in .logs/63/ always points to the newest run.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="63"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
SAMPLE="$SCRIPT_DIR/config.sample.json"
LOGS_ROOT="$ROOT/.logs/63"
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
# Echo 8 lines (one field per line) so empty fields aren't collapsed by IFS:
#   name, host, user, port, auth, password, identity, connect_timeout
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
        ] | .[]
      end
  ' "$CONFIG"
}

# ---------- runner: structured per-run log directory ----------
# These are exported because `run_on_host` is invoked in subshells in
# parallel mode, and bash sub-shells inherit env vars but NOT plain locals.
RUN_DIR=""           # absolute path: .logs/63/<TS>-<target>/
RUN_HOSTS_DIR=""     # RUN_DIR/hosts/
RUN_SESSION_LOG=""   # RUN_DIR/session.log
RUN_TS_START=""      # epoch seconds when this run started
RUN_TARGET=""        # original target spec (e.g. "group:web")
RUN_CMD=""           # the exact command being executed

# Sanitise an arbitrary string into a filename-safe token.
__safe_token() {
  echo "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*/_/g; s/^_//; s/_$//'
}

init_run_dir() {
  RUN_TARGET="$1"
  RUN_CMD="$2"
  RUN_TS_START=$(date +%s)
  local ts; ts=$(date '+%Y%m%d-%H%M%S')
  local target_safe; target_safe=$(__safe_token "$RUN_TARGET")
  RUN_DIR="$LOGS_ROOT/$ts-$target_safe"
  RUN_HOSTS_DIR="$RUN_DIR/hosts"
  RUN_SESSION_LOG="$RUN_DIR/session.log"

  if ! ensure_dir "$RUN_HOSTS_DIR"; then
    log_err "[63] Could not create run dir -- continuing without per-run logs"
    RUN_DIR=""; RUN_HOSTS_DIR=""; RUN_SESSION_LOG=""
    return 1
  fi

  # Exact command -- separate file so it's safe to cat without shell quoting issues.
  printf '%s\n' "$RUN_CMD"   > "$RUN_DIR/command.txt"
  printf '%s\n' "$RUN_TARGET" > "$RUN_DIR/target.txt"

  {
    echo "# Session:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Target:    $RUN_TARGET"
    echo "# Command:   $RUN_CMD"
    echo "# Run dir:   $RUN_DIR"
    echo "# ---"
  } > "$RUN_SESSION_LOG"

  # Update 'latest' symlink (atomic via mv)
  local latest_link="$LOGS_ROOT/latest"
  ln -sfn "$(basename "$RUN_DIR")" "$latest_link" 2>/dev/null || true

  # Export for parallel-mode subshells
  export RUN_DIR RUN_HOSTS_DIR RUN_SESSION_LOG RUN_TS_START RUN_TARGET RUN_CMD

  write_install_paths \
    --tool   "Remote-runner (target=$RUN_TARGET)" \
    --source "$CONFIG (host inventory) + cmd: $RUN_CMD" \
    --temp   "$TMPDIR/scripts-fixer/63-remote-runner" \
    --target "$RUN_DIR (manifest.json + hosts/*.log + session.log)"
  log_info "[63] Run dir: $RUN_DIR"
}

# Append host record to manifest.json hosts[]. Atomic via temp + mv.
# Args: host_name exit duration ts_start ts_end status
__write_host_meta() {
  [ -n "$RUN_HOSTS_DIR" ] || return 0
  local name="$1" rc="$2" dur="$3" t0="$4" t1="$5" status="$6"
  local meta="$RUN_HOSTS_DIR/$(__safe_token "$name").meta.json"
  jq -n \
    --arg name "$name" --arg status "$status" \
    --argjson exit "$rc" --argjson dur "$dur" \
    --argjson ts_start "$t0" --argjson ts_end "$t1" \
    '{host:$name, exit:$exit, duration_seconds:$dur, ts_start:$ts_start, ts_end:$ts_end, status:$status}' \
    > "$meta" 2>/dev/null || true
}

# Write the run-level manifest.json by aggregating every hosts/*.meta.json.
# Args: ok fail total
__write_run_manifest() {
  [ -n "$RUN_DIR" ] || return 0
  local ok="$1" fail="$2" total="$3"
  local ts_end; ts_end=$(date +%s)
  local dur=$(( ts_end - RUN_TS_START ))
  local manifest="$RUN_DIR/manifest.json"

  # Slurp every host meta into one array
  local host_metas="[]"
  if ls "$RUN_HOSTS_DIR"/*.meta.json >/dev/null 2>&1; then
    host_metas=$(jq -s '.' "$RUN_HOSTS_DIR"/*.meta.json 2>/dev/null || echo "[]")
  fi

  jq -n \
    --arg target "$RUN_TARGET" \
    --arg cmd "$RUN_CMD" \
    --arg run_dir "$RUN_DIR" \
    --argjson ts_start "$RUN_TS_START" \
    --argjson ts_end "$ts_end" \
    --argjson dur "$dur" \
    --argjson ok "$ok" --argjson fail "$fail" --argjson total "$total" \
    --argjson hosts "$host_metas" \
    '{
       schema: "63-remote-runner.run/v1",
       run_dir: $run_dir,
       target: $target,
       command: $cmd,
       ts_start: $ts_start,
       ts_end:   $ts_end,
       duration_seconds: $dur,
       summary: {ok: $ok, fail: $fail, total: $total},
       hosts:   $hosts
     }' > "$manifest" 2>/dev/null || true
}

# Append a chronological line to the combined session log (locked-ish via O_APPEND).
__session_append() {
  [ -n "$RUN_SESSION_LOG" ] || return 0
  printf '%s\n' "$*" >> "$RUN_SESSION_LOG"
}

# Apply retention policy: keep newest N run-dirs per .logs/63/, delete the rest.
# Reads .logging.retain_runs from config.json (default 50, 0 = keep all).
__apply_retention() {
  local retain
  retain=$(jq -r '.logging.retain_runs // 50' "$CONFIG" 2>/dev/null)
  [ "$retain" -gt 0 ] 2>/dev/null || return 0
  local dirs
  # `latest` is a symlink, not a dir, so -type d won't match it. Good.
  dirs=$(find "$LOGS_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
  local count=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    count=$((count + 1))
    if [ "$count" -gt "$retain" ]; then
      rm -rf "$LOGS_ROOT/$d" 2>/dev/null && \
        log_info "[63] Retention: pruned old run dir $d (kept newest $retain)"
    fi
  done <<<"$dirs"
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
  # Read 8 newline-separated fields from host_record (empty fields preserved).
  local h_name h_host h_user h_port h_auth h_pw h_id h_to
  { IFS= read -r h_name
    IFS= read -r h_host
    IFS= read -r h_user
    IFS= read -r h_port
    IFS= read -r h_auth
    IFS= read -r h_pw
    IFS= read -r h_id
    IFS= read -r h_to
  } <<<"$rec"

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
  local host_log=""
  if [ -n "$RUN_HOSTS_DIR" ]; then
    host_log="$RUN_HOSTS_DIR/$(__safe_token "$h_name").log"
    {
      echo "# Host:    $h_name ($h_user@$h_host:$h_port  auth=$h_auth)"
      echo "# Command: $cmd"
      echo "# Started: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "# ---"
    } > "$host_log"
  fi

  log_info "[63] [$h_name] >>> $cmd"
  __session_append "[$(date '+%H:%M:%S')] [$h_name] >>> $cmd"
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

  # Per-host raw log (full stdout+stderr, no host-prefix munging)
  if [ -n "$host_log" ]; then
    {
      printf '%s\n' "$out"
      echo ""
      echo "# ---"
      echo "# Finished: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "# Exit:     $rc"
      echo "# Duration: ${dur}s"
    } >> "$host_log"
  fi

  # Combined session log (one host block, chronological)
  if [ -n "$RUN_SESSION_LOG" ]; then
    {
      echo ""
      echo "## [$h_name] exit=$rc dur=${dur}s"
      printf '%s\n' "$out"
    } >> "$RUN_SESSION_LOG"
  fi

  # Map exit code -> status string for the meta JSON
  local status="fail"
  case "$rc" in
    0)   status="ok" ;;
    5)   status="auth_fail" ;;
    255) status="unreachable" ;;
  esac
  __write_host_meta "$h_name" "$rc" "$dur" "$t0" "$t1" "$status"

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
  # Two-pass parser: flags can appear anywhere (before target, after --, etc.).
  # Pass 1: collect flags and split positionals at the `--` separator.
  local -a before_dd=() after_dd=()
  local seen_dd=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)   dry=1; shift ;;
      --parallel)  parallel="${2:-1}"; shift 2 ;;
      -h|--help)   verb_help; return 0 ;;
      --)          seen_dd=1; shift ;;
      *)
        if [ "$seen_dd" = "1" ]; then after_dd+=("$1"); else before_dd+=("$1"); fi
        shift
        ;;
    esac
  done
  # Pass 2: target = first positional before `--`; command = everything after `--`
  # (or, if no `--`, every positional after the target).
  if [ "${#before_dd[@]}" -ge 1 ]; then target="${before_dd[0]}"; fi
  if [ "$seen_dd" = "1" ]; then
    cmd="${after_dd[*]}"
  elif [ "${#before_dd[@]}" -ge 2 ]; then
    cmd="${before_dd[*]:1}"
  fi

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

  init_run_dir "$target" "$cmd"

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
  __write_run_manifest "$ok" "$fail" "$total"
  if [ -n "$RUN_DIR" ]; then
    log_info "[63] Manifest: $RUN_DIR/manifest.json"
    log_info "[63] Per-host: $RUN_HOSTS_DIR/<name>.log"
    log_info "[63] Latest:   $LOGS_ROOT/latest -> $(basename "$RUN_DIR")"
  fi
  __apply_retention
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
    local _x h_host h_port h_to
    { IFS= read -r _x        # name
      IFS= read -r h_host
      IFS= read -r _x        # user
      IFS= read -r h_port
      IFS= read -r _x        # auth
      IFS= read -r _x        # password
      IFS= read -r _x        # identity
      IFS= read -r h_to
    } <<<"$rec"
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
    run.sh logs                       # list recent runs (newest first)
    run.sh logs show [<run>]          # cat session.log for a run (default: latest)
    run.sh logs host <name> [<run>]   # cat one host's log from a run
    run.sh logs manifest [<run>]      # pretty-print manifest.json
    run.sh logs clear                 # remove ALL run dirs (asks for confirmation)
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
    run.sh logs                       # see all past runs
    run.sh logs show                  # session.log of newest run
    run.sh logs host web-1 latest     # raw stdout from web-1 in newest run
    run.sh logs manifest latest       # JSON summary of newest run

  Auth (per-host or defaults.auth):
    password   uses sshpass; reads from .password or prompts
    key        uses ssh -i .identity_file (~ expanded)

  Security:
    config.json is auto-chmod 600 and added to .gitignore on every run.
    Passwords are passed via SSHPASS env (never on argv).
    Use 'auth: key' for production -- password mode is for lab/training.

  Log layout (per run):
    .logs/63/<TIMESTAMP>-<target>/
      ├── command.txt              exact command run
      ├── target.txt               original target spec
      ├── session.log              combined chronological output
      ├── manifest.json            structured summary {target, hosts[], summary}
      └── hosts/
          ├── <name>.log           raw stdout+stderr per host
          └── <name>.meta.json     {exit, duration_seconds, ts_start, ts_end, status}
    .logs/63/latest -> <newest run dir>

TXT
}

# ---------- verb: logs ----------
# Resolve a run-dir argument: empty -> latest symlink; absolute -> as-is;
# bare name -> $LOGS_ROOT/<name>; "latest" -> latest symlink target.
__resolve_run_dir() {
  local r="${1:-}"
  if [ -z "$r" ] || [ "$r" = "latest" ]; then
    if [ -L "$LOGS_ROOT/latest" ]; then
      echo "$LOGS_ROOT/$(readlink "$LOGS_ROOT/latest")"
    elif [ -d "$LOGS_ROOT/latest" ]; then
      echo "$LOGS_ROOT/latest"
    else
      echo ""
    fi
    return
  fi
  if [ -d "$r" ]; then echo "$r"; return; fi
  if [ -d "$LOGS_ROOT/$r" ]; then echo "$LOGS_ROOT/$r"; return; fi
  echo ""
}

verb_logs() {
  local sub="${1:-list}"; shift 2>/dev/null || true

  if [ ! -d "$LOGS_ROOT" ]; then
    log_warn "[63] No log directory yet: $LOGS_ROOT (run something first)"
    return 0
  fi

  case "$sub" in
    ""|list)
      echo ""
      echo "Recent runs (newest first) in $LOGS_ROOT:"
      local found=0
      for d in $(find "$LOGS_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r); do
        found=1
        local m="$LOGS_ROOT/$d/manifest.json"
        if [ -f "$m" ]; then
          jq -r --arg d "$d" '"  \($d)  target=\(.target)  cmd=\(.command|tostring|.[0:60])  ok=\(.summary.ok) fail=\(.summary.fail)  dur=\(.duration_seconds)s"' "$m" 2>/dev/null \
            || echo "  $d  (manifest unreadable)"
        else
          echo "  $d  (no manifest -- run may have aborted)"
        fi
      done
      [ "$found" = "0" ] && echo "  (no runs recorded)"
      if [ -L "$LOGS_ROOT/latest" ]; then
        echo ""
        echo "  latest -> $(readlink "$LOGS_ROOT/latest")"
      fi
      echo ""
      ;;
    show)
      local rd; rd=$(__resolve_run_dir "${1:-}")
      [ -n "$rd" ] || { log_err "[63] no such run: ${1:-latest}"; return 1; }
      [ -f "$rd/session.log" ] || { log_err "[63] no session.log in $rd"; return 1; }
      cat "$rd/session.log"
      ;;
    host)
      local hname="${1:-}"; local rd; rd=$(__resolve_run_dir "${2:-}")
      [ -n "$hname" ] || { log_err "[63] usage: logs host <name> [<run>]"; return 2; }
      [ -n "$rd" ]    || { log_err "[63] no such run: ${2:-latest}"; return 1; }
      local hlog="$rd/hosts/$(__safe_token "$hname").log"
      [ -f "$hlog" ] || { log_err "[63] no host log: $hlog"; return 1; }
      cat "$hlog"
      ;;
    manifest)
      local rd; rd=$(__resolve_run_dir "${1:-}")
      [ -n "$rd" ] || { log_err "[63] no such run: ${1:-latest}"; return 1; }
      [ -f "$rd/manifest.json" ] || { log_err "[63] no manifest.json in $rd"; return 1; }
      jq '.' "$rd/manifest.json"
      ;;
    clear)
      printf 'Delete ALL runs in %s ? [y/N] ' "$LOGS_ROOT"
      local ans; read -r ans
      case "$ans" in
        y|Y|yes|YES)
          find "$LOGS_ROOT" -maxdepth 1 -mindepth 1 \( -type d -o -type l \) -exec rm -rf {} +
          log_ok "[63] Cleared $LOGS_ROOT"
          ;;
        *) log_info "[63] Aborted -- nothing deleted." ;;
      esac
      ;;
    *) log_err "[63] Unknown logs subcommand: $sub"; verb_help; return 2 ;;
  esac
}

# ---------- entry ----------
case "${1:-help}" in
  run)        shift; verb_run "$@" ;;
  list)       verb_list ;;
  check)      shift; verb_check "$@" ;;
  logs)       shift; verb_logs "$@" ;;
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
