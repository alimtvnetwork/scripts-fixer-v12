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
  list            [--method M] [--json|--format=table|json]
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
  local fmt="table"
  local method=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)            fmt="json"; shift ;;
      --format)          fmt="${2:-table}"; shift 2 ;;
      --format=*)        fmt="${1#--format=}"; shift ;;
      --method)          method="${2:-}"; shift 2 ;;
      --method=*)        method="${1#--method=}"; shift ;;
      -h|--help)         usage; return 0 ;;
      *) log_warn "[64] list: ignoring extra arg: $1"; shift ;;
    esac
  done

  case "$fmt" in
    table)
      local count=0
      printf 'METHOD          NAME                 PATH/ID\n'
      printf -- '--------------- -------------------- --------------------------------------------\n'
      while IFS=$'\t' read -r m n p _scope; do
        [ -z "${m:-}" ] && continue
        _method_matches "$method" "$m" || continue
        printf '%-15s %-20s %s\n' "$m" "$n" "$p"
        count=$((count+1))
      done < <(list_startup_entries)
      printf -- '--------------- -------------------- --------------------------------------------\n'
      printf '%d entr%s tagged "%s".\n' "$count" "$([ $count -eq 1 ] && echo y || echo ies)" "${STARTUP_TAG_PREFIX:-lovable-startup}"
      return 0
      ;;
    json)
      _emit_list_json "$method"
      return $?
      ;;
    *)
      log_warn "[64] list: unknown --format '$fmt' (use table|json)"
      return 1
      ;;
  esac
}

# Emit a stable JSON array on stdout. Each element:
#   { "method": "...", "name": "...", "path": "...", "scope": "user" }
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
import json, sys
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
    rows.append({
        "method": parts[0],
        "name":   parts[1],
        "path":   parts[2],
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
    BEGIN { n=0 }
    NF==0 { next }
    {
      if (!keep($1)) next
      n++
      m[n]=$1; nm[n]=$2; p[n]=$3; sc[n]=($4==""?"user":$4)
    }
    END {
      printf "{\n  \"tag\": \"%s\",\n  \"count\": %d,\n  \"entries\": [", jesc(tag), n
      for (i=1; i<=n; i++) {
        printf "%s\n    {\n      \"method\": \"%s\",\n      \"name\": \"%s\",\n      \"path\": \"%s\",\n      \"scope\": \"%s\"\n    }", \
          (i==1?"":","), jesc(m[i]), jesc(nm[i]), jesc(p[i]), jesc(sc[i])
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

main "$@"
