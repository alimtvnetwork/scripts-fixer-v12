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
  list            [--method M] [--json|--csv|--format=table|json|csv] [--output FILE]
  duplicates      [--json|--csv] [--output FILE]
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
    duplicates|dupes|dups)         cmd_duplicates "$@"; exit $? ;;
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
  local fmt="table"
  local method=""
  local out_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)            fmt="json"; shift ;;
      --csv)             fmt="csv"; shift ;;
      --format)          fmt="${2:-table}"; shift 2 ;;
      --format=*)        fmt="${1#--format=}"; shift ;;
      --method)          method="${2:-}"; shift 2 ;;
      --method=*)        method="${1#--method=}"; shift ;;
      -o|--output)       out_file="${2:-}"; shift 2 ;;
      --output=*)        out_file="${1#--output=}"; shift ;;
      -h|--help)         usage; return 0 ;;
      *) log_warn "[64] list: ignoring extra arg: $1"; shift ;;
    esac
  done

  # When writing to a file, ensure the parent dir exists and the file is
  # creatable BEFORE we generate output, so failures are loud and early.
  if [ -n "$out_file" ]; then
    local out_dir
    out_dir=$(dirname -- "$out_file")
    if ! mkdir -p -- "$out_dir" 2>/dev/null; then
      log_file_error "$out_file" "cannot create parent directory: $out_dir"
      return 1
    fi
    if ! : >"$out_file" 2>/dev/null; then
      log_file_error "$out_file" "cannot write to output file"
      return 1
    fi
  fi

  case "$fmt" in
    table)
      _emit_list_table "$method" "$out_file"
      return $?
      ;;
    json)
      if [ -n "$out_file" ]; then
        _emit_list_json "$method" >"$out_file" || return $?
        log_info "[64] wrote JSON to: $out_file"
        return 0
      fi
      _emit_list_json "$method"
      return $?
      ;;
    csv)
      if [ -n "$out_file" ]; then
        _emit_list_csv "$method" >"$out_file" || return $?
        log_info "[64] wrote CSV to: $out_file"
        return 0
      fi
      _emit_list_csv "$method"
      return $?
      ;;
    *)
      log_warn "[64] list: unknown --format '$fmt' (use table|json|csv)"
      return 1
      ;;
  esac
}

# _row_status PATH METHOD -- echo "active" if the underlying path/file exists,
# else "orphaned". `path` for shell-rc-app/shell-rc-env is the rc file we wrote
# the block into; for autostart/systemd-user/launchagent it is the unit file.
_row_status() {
  local path="$1"
  if [ -n "$path" ] && [ -e "$path" ]; then
    echo "active"
  else
    echo "orphaned"
  fi
}

# Render the human table (optionally to a file). Adds a STATUS column so the
# operator can see at a glance which entries point at a missing target.
_emit_list_table() {
  local method="$1" out_file="$2"
  local tag="${STARTUP_TAG_PREFIX:-lovable-startup}"
  local count=0
  {
    printf 'METHOD          NAME                 STATUS    PATH/ID\n'
    printf -- '--------------- -------------------- --------- --------------------------------------------\n'
    while IFS=$'\t' read -r m n p _scope; do
      [ -z "${m:-}" ] && continue
      _method_matches "$method" "$m" || continue
      local st
      st=$(_row_status "$p" "$m")
      printf '%-15s %-20s %-9s %s\n' "$m" "$n" "$st" "$p"
      count=$((count+1))
    done < <(list_startup_entries)
    printf -- '--------------- -------------------- --------- --------------------------------------------\n'
    printf '%d entr%s tagged "%s".\n' "$count" "$([ $count -eq 1 ] && echo y || echo ies)" "$tag"
  } | { if [ -n "$out_file" ]; then tee "$out_file" >/dev/null; else cat; fi; }
  if [ -n "$out_file" ]; then
    log_info "[64] wrote table to: $out_file"
  fi
  return 0
}

# Emit RFC 4180 CSV on stdout: header + one row per entry. Fields with commas,
# quotes, or newlines are double-quoted with internal quotes doubled.
_emit_list_csv() {
  local method="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    list_startup_entries | python3 -c '
import csv, os, sys
want = sys.argv[1] if len(sys.argv) > 1 else ""
def keep(method):
    if not want or want == "ALL":
        return True
    if want == method:
        return True
    if want == "shell-rc" and method in ("shell-rc-app", "shell-rc-env"):
        return True
    return False
w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(["method", "name", "path", "status", "scope"])
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    while len(parts) < 4:
        parts.append("")
    method, name, path, scope = parts[0], parts[1], parts[2], parts[3] or "user"
    if not keep(method):
        continue
    status = "active" if path and os.path.exists(path) else "orphaned"
    w.writerow([method, name, path, status, scope])
' "$method"
    return $?
  fi

  # awk fallback. We compute status by stat-ing each path via `test -e` from
  # inside the pipeline; awk has no portable way to test file existence.
  list_startup_entries | awk -F'\t' -v want="$method" '
    function csv_esc(s,    r) {
      r = s
      if (r ~ /[",\n\r]/) {
        gsub(/"/, "\"\"", r)
        r = "\"" r "\""
      }
      return r
    }
    function keep(meth) {
      if (want == "" || want == "ALL") return 1
      if (want == meth) return 1
      if (want == "shell-rc" && (meth == "shell-rc-app" || meth == "shell-rc-env")) return 1
      return 0
    }
    function status_of(path,    rc) {
      if (path == "") return "orphaned"
      # Use shell test -e via system(); avoids spawning stat.
      rc = system("test -e \"" path "\"")
      return (rc == 0) ? "active" : "orphaned"
    }
    BEGIN { print "method,name,path,status,scope" }
    NF==0 { next }
    {
      if (!keep($1)) next
      sc = ($4 == "" ? "user" : $4)
      printf "%s,%s,%s,%s,%s\n", csv_esc($1), csv_esc($2), csv_esc($3), status_of($3), csv_esc(sc)
    }
  '
}

# Emit a stable JSON array on stdout. Each element:
#   { "method": "...", "name": "...", "path": "...", "status": "active|orphaned", "scope": "user" }
# Strings are escaped per RFC 8259 (\, ", control chars). Empty list -> [].
_emit_list_json() {
  local method="${1:-}"
  local tag="${STARTUP_TAG_PREFIX:-lovable-startup}"

  # Use python3 when available for guaranteed-correct escaping; fall back to
  # an awk-based escaper that handles \, ", and the control chars we'd
  # plausibly see (tab, newline, CR, backspace, formfeed). The awk path
  # never executes when python3 is on PATH (it always is on every Linux
  # distro + macOS we target), so this stays simple in production.
  if command -v python3 >/dev/null 2>&1; then
    list_startup_entries | python3 -c '
import json, os, sys
want = sys.argv[1] if len(sys.argv) > 1 else ""
def keep(method):
    if not want or want == "ALL":
        return True
    if want == method:
        return True
    if want == "shell-rc" and method in ("shell-rc-app", "shell-rc-env"):
        return True
    return False
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    while len(parts) < 4:
        parts.append("")
    if not keep(parts[0]):
        continue
    path = parts[2]
    status = "active" if path and os.path.exists(path) else "orphaned"
    rows.append({
        "method": parts[0],
        "name":   parts[1],
        "path":   parts[2],
        "status": status,
        "scope":  parts[3] or "user",
    })
out = {"tag": '"\"$tag\""', "count": len(rows), "entries": rows}
json.dump(out, sys.stdout, indent=2, sort_keys=False)
sys.stdout.write("\n")
' "$method"
    return $?
  fi

  # awk fallback (POSIX awk + gawk both work).
  list_startup_entries | awk -F'\t' -v tag="$tag" -v want="$method" '
    function jesc(s,    r) {
      r = s
      gsub(/\\/, "\\\\", r)
      gsub(/"/,  "\\\"", r)
      gsub(/\t/, "\\t",  r)
      gsub(/\r/, "\\r",  r)
      gsub(/\n/, "\\n",  r)
      gsub(/\b/, "\\b",  r)
      gsub(/\f/, "\\f",  r)
      return r
    }
    function keep(meth) {
      if (want == "" || want == "ALL") return 1
      if (want == meth) return 1
      if (want == "shell-rc" && (meth == "shell-rc-app" || meth == "shell-rc-env")) return 1
      return 0
    }
    function status_of(path,    rc) {
      if (path == "") return "orphaned"
      rc = system("test -e \"" path "\"")
      return (rc == 0) ? "active" : "orphaned"
    }
    BEGIN { n=0 }
    NF==0 { next }
    {
      if (!keep($1)) next
      n++
      m[n]=$1; nm[n]=$2; p[n]=$3; sc[n]=($4==""?"user":$4); st[n]=status_of($3)
    }
    END {
      printf "{\n  \"tag\": \"%s\",\n  \"count\": %d,\n  \"entries\": [", jesc(tag), n
      for (i=1; i<=n; i++) {
        printf "%s\n    {\n      \"method\": \"%s\",\n      \"name\": \"%s\",\n      \"path\": \"%s\",\n      \"status\": \"%s\",\n      \"scope\": \"%s\"\n    }", \
          (i==1?"":","), jesc(m[i]), jesc(nm[i]), jesc(p[i]), jesc(st[i]), jesc(sc[i])
      }
      if (n>0) printf "\n  "
      printf "]\n}\n"
    }
  '
}

cmd_remove() {
  if ! declare -f remove_startup_entry >/dev/null 2>&1; then
    log_file_error "$SCRIPT_DIR/helpers/enumerate.sh" "remove_startup_entry not loaded"
    return 1
  fi
  local name="" method="" interactive=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --method) method="${2:-}"; shift 2 ;;
      --all) method="ALL"; shift ;;
      --interactive|-i) interactive=1; shift ;;
      --yes|-y) yes=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) [ -z "$name" ] && name="$1" || log_warn "[64] ignoring extra arg: $1"; shift ;;
    esac
  done

  # Interactive trigger: no name AND (--interactive OR stdin is a TTY).
  if [ -z "$name" ]; then
    if [ "$interactive" -eq 1 ] || [ -t 0 ]; then
      _cmd_remove_interactive "$method" "$yes"
      return $?
    fi
    log_warn "[64] remove: <name> required (or pass --interactive on a TTY)"; usage
    return 1
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

# ---- Interactive picker for cmd_remove --------------------------------------
# Method alias map: user types `shell-rc`, enumerators emit `shell-rc-app`
# for app blocks and `shell-rc-env` for env blocks. Treat `shell-rc` as
# "either of those". `ALL`/empty means "no filter". Defined at file scope
# so both cmd_remove and _cmd_remove_interactive can call it.
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

# _read_line VARNAME -- read one line from /dev/tty when usable, else from
# the inherited stdin, with all errors silenced. Always returns 0 and sets
# VARNAME (possibly to "") so callers can rely on a defined variable.
_read_line() {
  local __out_var="$1"
  local __line=""
  # `exec 3</dev/tty` will fail loudly on non-TTY hosts (CI/sandboxes), so
  # probe with a subshell first and swallow the diagnostic.
  if (exec 3</dev/tty) >/dev/null 2>&1; then
    IFS= read -r __line </dev/tty 2>/dev/null || __line=""
  else
    IFS= read -r __line 2>/dev/null || __line=""
  fi
  printf -v "$__out_var" '%s' "$__line"
}

# Renders a numbered table of all tagged entries (filtered by --method when
# provided), reads a selection like "1,3-5" or "all" from /dev/tty, confirms,
# then removes each chosen entry via remove_startup_entry.
_cmd_remove_interactive() {
  local method="$1" yes="$2"

  # Snapshot the live entries into parallel arrays so removals don't perturb
  # the indexing the user just picked from.
  local -a sel_method sel_name sel_path
  local idx=0
  while IFS=$'\t' read -r m n p _scope; do
    [ -z "${m:-}" ] && continue
    if [ -n "$method" ] && [ "$method" != "ALL" ]; then
      _method_matches "$method" "$m" || continue
    fi
    sel_method[idx]="$m"
    sel_name[idx]="$n"
    sel_path[idx]="$p"
    idx=$((idx+1))
  done < <(list_startup_entries)

  if [ "$idx" -eq 0 ]; then
    log_info "[64] no entries to remove (filter='${method:-any}')"
    return 0
  fi

  printf '\n  %sStartup entries tagged "%s"%s%s:\n' \
    $'\e[36m' "${STARTUP_TAG_PREFIX:-lovable-startup}" \
    "$([ -n "$method" ] && [ "$method" != "ALL" ] && printf ' (method=%s)' "$method")" \
    $'\e[0m'
  printf '  %3s  %-15s %-20s %s\n' '#' 'METHOD' 'NAME' 'PATH/ID'
  printf '  %3s  %-15s %-20s %s\n' '---' '---------------' '--------------------' '--------------------------------------------'
  local i
  for ((i=0; i<idx; i++)); do
    printf '  %3d  %-15s %-20s %s\n' "$((i+1))" "${sel_method[i]}" "${sel_name[i]}" "${sel_path[i]}"
  done
  printf '\n  Selection examples: 1   1,3,5   2-4   1,3-5   all   q (quit)\n'
  printf '  Select entries to remove: '

  # Read from /dev/tty so this works even when run.sh's stdin was redirected.
  local input=""
  _read_line input

  case "$input" in
    ""|q|Q|quit|exit) log_info "[64] cancelled (no selection)"; return 0 ;;
  esac

  # Parse selection -> a sorted, deduped list of 1-based indices.
  local -a picks
  if [ "$input" = "all" ] || [ "$input" = "ALL" ] || [ "$input" = "*" ]; then
    for ((i=0; i<idx; i++)); do picks[i]="$((i+1))"; done
  else
    # Strip whitespace, split on commas, expand a-b ranges.
    local cleaned
    cleaned=$(printf '%s' "$input" | tr -d '[:space:]')
    local pi=0 token a b j
    IFS=',' read -ra _tokens <<<"$cleaned"
    for token in "${_tokens[@]}"; do
      [ -z "$token" ] && continue
      if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
        a="${token%-*}"; b="${token#*-}"
        if [ "$a" -gt "$b" ]; then local t="$a"; a="$b"; b="$t"; fi
        for ((j=a; j<=b; j++)); do picks[pi]="$j"; pi=$((pi+1)); done
      elif [[ "$token" =~ ^[0-9]+$ ]]; then
        picks[pi]="$token"; pi=$((pi+1))
      else
        log_warn "[64] ignoring invalid selection token: $token"
      fi
    done
    # Dedupe + sort numerically.
    if [ "${#picks[@]}" -gt 0 ]; then
      mapfile -t picks < <(printf '%s\n' "${picks[@]}" | sort -un)
    fi
  fi

  if [ "${#picks[@]}" -eq 0 ]; then
    log_info "[64] no valid selections -- nothing to do"
    return 0
  fi

  # Validate range.
  local -a valid=()
  for p in "${picks[@]}"; do
    if [ "$p" -ge 1 ] && [ "$p" -le "$idx" ]; then
      valid+=("$p")
    else
      log_warn "[64] selection $p out of range (1..$idx) -- skipping"
    fi
  done
  if [ "${#valid[@]}" -eq 0 ]; then
    log_warn "[64] no in-range selections"; return 0
  fi

  # Confirm.
  printf '\n  About to remove %d entr%s:\n' "${#valid[@]}" "$([ ${#valid[@]} -eq 1 ] && echo y || echo ies)"
  for p in "${valid[@]}"; do
    local k=$((p-1))
    printf '    [%d] %s :: %s\n' "$p" "${sel_method[k]}" "${sel_name[k]}"
  done
  if [ "$yes" -ne 1 ]; then
    printf '  Confirm? [y/N] '
    local ans=""
    _read_line ans
    case "${ans:-}" in
      y|Y|yes|YES) ;;
      *) log_info "[64] cancelled at confirm"; return 0 ;;
    esac
  fi

  # Remove. Iterate the snapshot so indices stay stable.
  local rc=0 done=0 failed=0
  for p in "${valid[@]}"; do
    local k=$((p-1))
    if remove_startup_entry "${sel_method[k]}" "${sel_name[k]}"; then
      done=$((done+1))
    else
      failed=$((failed+1)); rc=1
    fi
  done

  log_ok "[64] interactive remove: $done removed$([ $failed -gt 0 ] && echo " ($failed failed)")"
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

# ---- duplicates report -----------------------------------------------------
# Identifies entries that are "the same thing" registered more than once.
# Two notions of duplicate are reported:
#   1. by-name   : same logical name registered under 2+ methods (e.g. an app
#                  installed both as a launchagent and as a login item).
#   2. by-content: file-based entries (autostart, systemd-user, launchagent,
#                  login-item plist) whose body hashes to the same SHA-256.
#                  For shell-rc-app blocks we hash the body of the marker
#                  block; for shell-rc-env we hash each `export KEY=VAL` line.
# Output formats: human table (default), --json, --csv, all routable to
# --output FILE just like `list`.
cmd_duplicates() {
  if ! declare -f list_startup_entries >/dev/null 2>&1; then
    log_file_error "$SCRIPT_DIR/helpers/enumerate.sh" "list_startup_entries not loaded"
    return 1
  fi
  local fmt="table" out_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)        fmt="json"; shift ;;
      --csv)         fmt="csv";  shift ;;
      --format)      fmt="${2:-table}"; shift 2 ;;
      --format=*)    fmt="${1#--format=}"; shift ;;
      -o|--output)   out_file="${2:-}"; shift 2 ;;
      --output=*)    out_file="${1#--output=}"; shift ;;
      -h|--help)     usage; return 0 ;;
      *) log_warn "[64] duplicates: ignoring extra arg: $1"; shift ;;
    esac
  done

  if [ -n "$out_file" ]; then
    local out_dir; out_dir=$(dirname -- "$out_file")
    if ! mkdir -p -- "$out_dir" 2>/dev/null; then
      log_file_error "$out_file" "cannot create parent directory: $out_dir"
      return 1
    fi
    if ! : >"$out_file" 2>/dev/null; then
      log_file_error "$out_file" "cannot write to output file"
      return 1
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "[64] duplicates: python3 not found; report limited to name-based grouping"
    _emit_dupes_bash "$fmt" "$out_file"
    return $?
  fi

  local generator
  generator="$(_collect_dupe_inputs)"
  if [ -n "$out_file" ]; then
    printf '%s' "$generator" | _emit_dupes_python "$fmt" >"$out_file" || return $?
    log_info "[64] wrote $fmt duplicates report to: $out_file"
    return 0
  fi
  printf '%s' "$generator" | _emit_dupes_python "$fmt"
}

# Build TSV input for the python reporter:
#   <method>\t<name>\t<path>\t<scope>\t<content-hash>
# `content-hash` is sha256 of the underlying body, or empty if we cannot read
# the entry (e.g. login-item paths we cannot stat).
_collect_dupe_inputs() {
  local tag="${STARTUP_TAG_PREFIX:-lovable-startup}"
  local rc_path=""
  if declare -f detect_shell_rc >/dev/null 2>&1; then
    rc_path=$(detect_shell_rc 2>/dev/null || true)
  fi

  while IFS=$'\t' read -r m n p scope; do
    [ -z "${m:-}" ] && continue
    local hash=""
    case "$m" in
      autostart|systemd-user|launchagent)
        if [ -f "$p" ]; then
          hash=$(_sha256_of_file "$p")
        fi
        ;;
      shell-rc-app)
        if [ -f "$p" ]; then
          hash=$(_extract_shell_rc_block "$p" "$tag" "$n" "app" | _sha256_of_stdin)
        fi
        ;;
      shell-rc-env)
        if [ -f "$p" ]; then
          hash=$(_extract_shell_rc_env_line "$p" "$tag" "$n" | _sha256_of_stdin)
        fi
        ;;
      login-item)
        # `p` is the on-disk app bundle. Hashing a .app would be huge; use the
        # path itself as the identity so two login items pointing at the same
        # bundle still collide.
        hash=$(printf 'path:%s' "$p" | _sha256_of_stdin)
        ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$n" "$p" "${scope:-user}" "$hash"
  done < <(list_startup_entries)
}

_sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}'
  else echo ""; fi
}
_sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 2>/dev/null | awk '{print $1}'
  else cat >/dev/null; echo ""; fi
}

# Print the body of a `# >>> tag-name (tag-app) >>>` ... `# <<< tag-name <<<`
# block from the rc file, excluding the marker lines themselves.
_extract_shell_rc_block() {
  local rc="$1" tag="$2" name="$3" kind="$4"
  awk -v tag="$tag" -v name="$name" -v kind="$kind" '
    $0 == "# >>> "tag"-"name" ("tag"-"kind") >>>" {inb=1; next}
    $0 == "# <<< "tag"-"name" <<<"                {inb=0; next}
    inb { print }
  ' "$rc"
}

# For shell-rc-env: emit the single `export KEY=VALUE` line for KEY = $name,
# from inside the env block. That makes "same KEY -> same VALUE" hash equal.
_extract_shell_rc_env_line() {
  local rc="$1" tag="$2" key="$3"
  awk -v tag="$tag" -v key="$key" '
    $0 == "# >>> "tag"-env (managed) >>>" {inb=1; next}
    $0 == "# <<< "tag"-env <<<"           {inb=0; next}
    inb && $0 ~ ("^export "key"=") { print; exit }
  ' "$rc"
}

# Python reporter: read TSV (method,name,path,scope,hash) on stdin, emit a
# table/json/csv on stdout. Exit 0 always (a clean report with zero groups
# is a valid result); the human table writes "no duplicates found." in that
# case.
_emit_dupes_python() {
  local fmt="$1"
  local tag="${STARTUP_TAG_PREFIX:-lovable-startup}"
  python3 -c '
import json, sys, csv, collections
fmt = sys.argv[1]
tag = sys.argv[2]
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    parts = line.split("\t")
    while len(parts) < 5: parts.append("")
    rows.append(dict(method=parts[0], name=parts[1], path=parts[2],
                     scope=parts[3] or "user", hash=parts[4]))

# Group by name (cross-method dupes).
by_name = collections.defaultdict(list)
for r in rows:
    by_name[r["name"]].append(r)
name_groups = []
for name, entries in by_name.items():
    if len(entries) >= 2:
        name_groups.append({
            "kind": "by-name",
            "key":  name,
            "count": len(entries),
            "entries": [{k: e[k] for k in ("method","name","path","scope")} for e in entries],
        })

# Group by content-hash (skip empty hashes; skip groups already covered by
# a single-method same-name pair, since that is shown elsewhere).
by_hash = collections.defaultdict(list)
for r in rows:
    if r["hash"]:
        by_hash[r["hash"]].append(r)
hash_groups = []
for h, entries in by_hash.items():
    if len(entries) < 2: continue
    hash_groups.append({
        "kind": "by-content",
        "key":  h[:12],   # short prefix is enough for humans
        "count": len(entries),
        "entries": [{k: e[k] for k in ("method","name","path","scope")} for e in entries],
    })

name_groups.sort(key=lambda g: g["key"])
hash_groups.sort(key=lambda g: (-g["count"], g["key"]))
groups = name_groups + hash_groups

if fmt == "json":
    out = {
        "tag": tag,
        "by_name_count": len(name_groups),
        "by_content_count": len(hash_groups),
        "groups": groups,
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
elif fmt == "csv":
    w = csv.writer(sys.stdout, lineterminator="\n")
    w.writerow(["kind","key","method","name","path","scope"])
    for g in groups:
        for e in g["entries"]:
            w.writerow([g["kind"], g["key"], e["method"], e["name"], e["path"], e["scope"]])
else:  # table
    if not groups:
        print("no duplicates found.")
        sys.exit(0)
    print("DUPLICATES REPORT")
    print("-" * 60)
    for g in groups:
        label = "name" if g["kind"] == "by-name" else "content sha256"
        kind = g["kind"]; key = g["key"]; cnt = g["count"]
        print("\n[%s] %s = %s  (%d entries)" % (kind, label, key, cnt))
        for e in g["entries"]:
            print("  - %-14s %-20s %s" % (e["method"], e["name"], e["path"]))
    print("")
    print("summary: %d by-name group(s), %d by-content group(s)." %
          (len(name_groups), len(hash_groups)))
' "$fmt" "$tag"
}

# Bash-only fallback when python3 is missing. Reports name-based duplicates
# only (no content hashing) using sort+uniq. Always exits 0.
_emit_dupes_bash() {
  local fmt="$1" out_file="$2"
  local body
  body=$(list_startup_entries | awk -F'\t' '
    NF==0 { next }
    { count[$2]++; lines[$2] = lines[$2] $0 "\n" }
    END {
      groups=0
      for (n in count) if (count[n] >= 2) {
        groups++
        printf "\n[by-name] name = %s  (%d entries)\n", n, count[n]
        printf "%s", lines[n]
      }
      if (groups == 0) print "no duplicates found."
      else printf "\nsummary: %d by-name group(s).\n", groups
    }
  ')
  if [ -n "$out_file" ]; then printf '%s\n' "$body" >"$out_file"
                              log_info "[64] wrote $fmt duplicates report to: $out_file"
                         else printf '%s\n' "$body"
  fi
  return 0
}

main "$@"
