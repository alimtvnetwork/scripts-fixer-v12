#!/usr/bin/env bash
# 68-user-mgmt/verify-summary.sh -- READ-ONLY validator for ssh-key install
# summary JSON documents emitted by add-user.sh (--summary-json) and the
# batch rollups emitted by add-user-from-json.sh.
#
# What it checks (per file):
#   1. File exists and is readable
#   2. Parses as valid JSON (jq)
#   3. Top-level required fields present:
#        - per-user (kind absent or != "batch"):
#            summaryVersion, writtenAt, host, user, runId,
#            authorizedKeysFile, summary{}, sources{}, ok
#        - batch (kind == "batch"):
#            summaryVersion, writtenAt, runId, sourceFile,
#            userCount, aggregate{}, users[]
#   4. summaryVersion == 1 (the only schema we know about)
#   5. Every counter in summary{}/aggregate{} is:
#        - present
#        - numeric (jq type == "number")
#        - integer (no fractional part)
#        - >= 0 (no negative counters)
#      Required counters:
#        sources_requested, keys_parsed, keys_unique,
#        keys_installed_new, keys_preserved
#   6. sources{} (per-user only): inline, file, url -- numeric, integer, >= 0
#   7. ok is a boolean (per-user only)
#   8. Soft consistency checks (warnings, not errors):
#        - keys_installed_new + keys_preserved == keys_unique  (when ok=true)
#        - keys_unique <= keys_parsed
#        - keys_parsed >= keys_installed_new
#      These are warnings because rejected/malformed keys legitimately make
#      keys_parsed < keys_unique impossible but other paths may differ.
#   9. For batch: aggregate counters must equal sum across users[].summary
#      (within tolerance 0). Mismatch -> error.
#
# Inputs (any combo, at least one required unless --auto):
#   --file PATH             validate a single file (repeatable)
#   --dir  DIR              validate every *.summary.json under DIR
#                           (non-recursive; matches the layout add-user.sh
#                           produces in <manifest-dir>/summaries/)
#   --auto                  shorthand for --dir <UM_MANIFEST_DIR>/summaries
#                           (default UM_MANIFEST_DIR=/var/lib/68-user-mgmt/
#                           ssh-key-runs)
#   --root DIR              base directory for --glob discovery (default:
#                           UM_MANIFEST_DIR or /var/lib/68-user-mgmt/
#                           ssh-key-runs). Patterns are evaluated relative
#                           to this dir.
#   --glob PATTERN          glob pattern to discover summary JSONs under
#                           --root (repeatable). When omitted, the patterns
#                           from config.json -> summaryDiscovery.defaultPatterns
#                           are used. Use shell-glob syntax; '**' requires
#                           --recursive (bash globstar).
#   --recursive             enable bash globstar so '**' matches across
#                           subdirectories. Default from config.json
#                           (summaryDiscovery.recursiveDefault, true).
#   --no-recursive          disable globstar even if config defaults to on.
#   --follow-symlinks       resolve symlinks in matched paths (default off).
#   --no-follow-symlinks    explicitly keep symlink-as-given.
#   --discover              run glob discovery using default patterns under
#                           the resolved root. Combinable with --file/--dir.
#   --run-id ID             when combined with --dir/--auto, only validate
#                           files whose name starts with "<ID>__"
#   --json                  emit one JSON document per validated file to
#                           stdout in NDJSON form, plus a final summary
#                           object on the last line. Suppresses pretty logs.
#   --strict                promote consistency warnings to errors
#   --quiet                 suppress per-file pretty output, keep tally
#   -h | --help             this help
#
# Exit codes:
#   0   every validated file passed (warnings allowed unless --strict)
#   1   at least one file failed validation
#   2   bad input (file/dir missing, jq missing, unreadable, etc.)
#  64   bad CLI usage
#
# CODE RED rule honored: every file/path failure logs the EXACT path and the
# precise reason (parse error from jq, stat() error, etc).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

vs_usage() {
  sed -n '2,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Examples:
  bash verify-summary.sh --auto
  bash verify-summary.sh --dir /var/lib/68-user-mgmt/ssh-key-runs/summaries
  bash verify-summary.sh --file /tmp/run-XYZ__alice.summary.json --json
  bash verify-summary.sh --auto --run-id 20260427-101530-abcd --strict
  bash verify-summary.sh --discover                              # use config defaults
  bash verify-summary.sh --root /srv/runs --glob 'summaries/*.summary.json'
  bash verify-summary.sh --root /srv/runs --recursive --glob '**/*.summary.json'
  bash verify-summary.sh --root /srv/runs --glob '2026-*/summaries/*.summary.json' --json
EOF
}

# ---- arg parse -------------------------------------------------------------
VS_FILES=()
VS_DIRS=()
VS_GLOBS=()
VS_ROOT=""
VS_DISCOVER=0
VS_RECURSIVE=""           # tri-state: ""=use config default, "1"=on, "0"=off
VS_FOLLOW_SYMLINKS=""     # tri-state: ""=config, "1"=on, "0"=off
VS_RUN_FILTER=""
VS_JSON=0
VS_STRICT=0
VS_QUIET=0
VS_AUTO=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)   vs_usage; exit 0 ;;
    --file)      VS_FILES+=("${2:-}"); shift 2 ;;
    --file=*)    VS_FILES+=("${1#--file=}"); shift ;;
    --dir)       VS_DIRS+=("${2:-}");  shift 2 ;;
    --dir=*)     VS_DIRS+=("${1#--dir=}");  shift ;;
    --auto)      VS_AUTO=1; shift ;;
    --discover)  VS_DISCOVER=1; shift ;;
    --root)      VS_ROOT="${2:-}"; shift 2 ;;
    --root=*)    VS_ROOT="${1#--root=}"; shift ;;
    --glob)      VS_GLOBS+=("${2:-}"); shift 2 ;;
    --glob=*)    VS_GLOBS+=("${1#--glob=}"); shift ;;
    --recursive) VS_RECURSIVE=1; shift ;;
    --no-recursive) VS_RECURSIVE=0; shift ;;
    --follow-symlinks) VS_FOLLOW_SYMLINKS=1; shift ;;
    --no-follow-symlinks) VS_FOLLOW_SYMLINKS=0; shift ;;
    --run-id)    VS_RUN_FILTER="${2:-}"; shift 2 ;;
    --run-id=*)  VS_RUN_FILTER="${1#--run-id=}"; shift ;;
    --json)      VS_JSON=1;   shift ;;
    --strict)    VS_STRICT=1; shift ;;
    --quiet)     VS_QUIET=1;  shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1' (failure: see --help)"; exit 64 ;;
    *)  log_err "unexpected positional: '$1' (failure: verify-summary.sh has no positionals -- use --file/--dir)"; exit 64 ;;
  esac
done

if [ "$VS_AUTO" = "1" ]; then
  _auto_dir="${UM_MANIFEST_DIR:-/var/lib/68-user-mgmt/ssh-key-runs}/summaries"
  VS_DIRS+=("$_auto_dir")
fi

# Trigger glob discovery when any glob-related flag is supplied.
_have_glob_intent=0
if [ "$VS_DISCOVER" = "1" ] || [ "${#VS_GLOBS[@]}" -gt 0 ] || [ -n "$VS_ROOT" ]; then
  _have_glob_intent=1
fi

if [ "${#VS_FILES[@]}" -eq 0 ] && [ "${#VS_DIRS[@]}" -eq 0 ] && [ "$_have_glob_intent" = "0" ]; then
  log_err "no inputs supplied (failure: pass --file, --dir, --auto, --discover, or --glob -- see --help)"
  exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
  log_err "$(um_msg missingTool "jq")"
  exit 127
fi

# ---- glob discovery -------------------------------------------------------
# Defaults come from config.json -> summaryDiscovery; fall back hard-coded
# if the block is missing/corrupt so the script still works.
_vs_cfg="$SCRIPT_DIR/config.json"
_vs_default_root="${UM_MANIFEST_DIR:-/var/lib/68-user-mgmt/ssh-key-runs}"
_vs_default_recursive="true"
_vs_default_follow="false"
_vs_default_max=5000
_vs_default_patterns=()

if [ -r "$_vs_cfg" ]; then
  _vs_default_recursive=$(jq -r '.summaryDiscovery.recursiveDefault // true'  "$_vs_cfg" 2>/dev/null || echo true)
  _vs_default_follow=$(jq    -r '.summaryDiscovery.followSymlinks   // false' "$_vs_cfg" 2>/dev/null || echo false)
  _vs_default_max=$(jq       -r '.summaryDiscovery.maxFiles         // 5000'  "$_vs_cfg" 2>/dev/null || echo 5000)
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    _vs_default_patterns+=("$_p")
  done < <(jq -r '(.summaryDiscovery.defaultPatterns // []) | .[]' "$_vs_cfg" 2>/dev/null)
fi
if [ "${#_vs_default_patterns[@]}" -eq 0 ]; then
  _vs_default_patterns=("summaries/*.summary.json" "summaries/**/*.summary.json")
fi

if [ "$_have_glob_intent" = "1" ]; then
  _eff_root="${VS_ROOT:-$_vs_default_root}"
  if [ "${#VS_GLOBS[@]}" -eq 0 ]; then
    _eff_globs=("${_vs_default_patterns[@]}")
  else
    _eff_globs=("${VS_GLOBS[@]}")
  fi

  case "$VS_RECURSIVE" in
    1) _eff_recursive=1 ;;
    0) _eff_recursive=0 ;;
    *) [ "$_vs_default_recursive" = "true" ] && _eff_recursive=1 || _eff_recursive=0 ;;
  esac
  case "$VS_FOLLOW_SYMLINKS" in
    1) _eff_follow=1 ;;
    0) _eff_follow=0 ;;
    *) [ "$_vs_default_follow" = "true" ] && _eff_follow=1 || _eff_follow=0 ;;
  esac

  # CODE RED: every root failure logs exact path + reason.
  if [ ! -e "$_eff_root" ]; then
    log_err "$(um_msg summaryDiscoveryRootMissing "$_eff_root")"
    exit 2
  fi
  if [ ! -d "$_eff_root" ]; then
    log_file_error "$_eff_root" "discovery root is not a directory (failure: pass --root <dir>, not a file)"
    exit 2
  fi
  if [ ! -r "$_eff_root" ] || [ ! -x "$_eff_root" ]; then
    log_err "$(um_msg summaryDiscoveryRootUnreadable "$_eff_root")"
    exit 2
  fi

  if [ "$VS_JSON" != "1" ] && [ "$VS_QUIET" != "1" ]; then
    _patstr=$(printf "'%s' " "${_eff_globs[@]}")
    log_info "$(um_msg summaryDiscoveryBegin "$_eff_root" "${_patstr% }" "$_eff_recursive" "$_eff_follow")"
  fi

  shopt -s nullglob
  if [ "$_eff_recursive" = "1" ]; then shopt -s globstar; else shopt -u globstar; fi

  _vs_seen="$(mktemp -t 68-vs-discover.XXXXXX)" || {
    log_err "could not create dedupe tempfile under \$TMPDIR (failure: check disk/perm; tried mktemp -t 68-vs-discover)"
    exit 2
  }
  trap 'rm -f "$_vs_seen"' EXIT

  _discover_total=0
  _cap_hit=0
  for _gp in "${_eff_globs[@]}"; do
    [ -z "$_gp" ] && continue
    _matches_for_pat=()
    while IFS= read -r -d '' _hit; do
      _matches_for_pat+=("$_hit")
    done < <(
      cd "$_eff_root" 2>/dev/null && \
      for _m in $_gp; do
        [ -e "$_m" ] || continue
        [ -f "$_m" ] || continue
        if [ "$_eff_follow" = "1" ]; then
          _abs=$(readlink -f -- "$_m" 2>/dev/null) || _abs="$_eff_root/$_m"
        else
          case "$_m" in
            /*) _abs="$_m" ;;
            *)  _abs="$_eff_root/$_m" ;;
          esac
        fi
        printf '%s\0' "$_abs"
      done
    )

    _added_for_pat=0
    for _hit in "${_matches_for_pat[@]:-}"; do
      [ -z "$_hit" ] && continue
      if [ -n "$VS_RUN_FILTER" ]; then
        case "$(basename -- "$_hit")" in
          "${VS_RUN_FILTER}__"*) : ;;
          *) continue ;;
        esac
      fi
      if grep -Fxq -- "$_hit" "$_vs_seen" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$_hit" >> "$_vs_seen"
      VS_FILES+=("$_hit")
      _added_for_pat=$((_added_for_pat+1))
      _discover_total=$((_discover_total+1))
      if [ "$_discover_total" -ge "$_vs_default_max" ]; then
        _cap_hit=1
        break
      fi
    done

    if [ "$VS_JSON" != "1" ] && [ "$VS_QUIET" != "1" ]; then
      log_info "$(um_msg summaryDiscoveryMatch "$_added_for_pat" "$_gp")"
    fi
    [ "$_cap_hit" = "1" ] && break
  done

  shopt -u nullglob globstar

  if [ "$_cap_hit" = "1" ]; then
    log_warn "$(um_msg summaryDiscoveryCapHit "$_vs_default_max" "$_eff_root")"
  fi

  if [ "$VS_JSON" != "1" ] && [ "$VS_QUIET" != "1" ]; then
    log_info "$(um_msg summaryDiscoveryTotal "$_discover_total" "${#_eff_globs[@]}" "$_eff_root")"
  fi

  # If discovery was the SOLE source and yielded nothing, that's a hard error.
  if [ "$_discover_total" -eq 0 ] && [ "${#VS_DIRS[@]}" -eq 0 ] && \
     [ "${#VS_FILES[@]}" -eq 0 ]; then
    if [ "$VS_JSON" = "1" ]; then
      printf '{"summary":{"checked":0,"passed":0,"failed":0,"warned":0},"ok":false,"empty":true,"reason":"no glob matches under root"}\n'
    else
      log_err "$(um_msg summaryDiscoveryNone "$_eff_root")"
    fi
    exit 2
  fi
fi

# ---- expand --dir into --file list ----------------------------------------
for d in "${VS_DIRS[@]}"; do
  if [ -z "$d" ]; then continue; fi
  if [ ! -d "$d" ]; then
    log_file_error "$d" "summaries dir does not exist (failure: nothing to validate; create the dir or run add-user.sh --summary-json first)"
    exit 2
  fi
  if [ ! -r "$d" ]; then
    log_file_error "$d" "summaries dir is not readable (failure: re-run with sudo or fix dir mode 0700)"
    exit 2
  fi
  shopt -s nullglob
  if [ -n "$VS_RUN_FILTER" ]; then
    _matches=("$d/${VS_RUN_FILTER}__"*.summary.json)
  else
    _matches=("$d/"*.summary.json)
  fi
  shopt -u nullglob
  if [ "${#_matches[@]}" -eq 0 ]; then
    if [ -n "$VS_RUN_FILTER" ]; then
      log_warn "[68][verify-summary] no *.summary.json under '$d' matching run-id '$VS_RUN_FILTER' (nothing to validate for this filter)"
    else
      log_warn "[68][verify-summary] no *.summary.json files under '$d' (nothing to validate -- did any add-user.sh run with --summary-json yet?)"
    fi
  fi
  for f in "${_matches[@]}"; do
    VS_FILES+=("$f")
  done
done

if [ "${#VS_FILES[@]}" -eq 0 ]; then
  # Nothing to do is not a failure unless the user explicitly listed files.
  if [ "$VS_JSON" = "1" ]; then
    printf '{"summary":{"checked":0,"passed":0,"failed":0,"warned":0},"ok":true,"empty":true}\n'
  else
    log_warn "[68][verify-summary] nothing to validate -- exiting cleanly (rc=0)"
  fi
  exit 0
fi

# ---- per-file validator ----------------------------------------------------
# Required counter keys for both summary{} and aggregate{}.
VS_REQ_COUNTERS=(sources_requested keys_parsed keys_unique keys_installed_new keys_preserved)
VS_REQ_SOURCES=(inline file url)

# Validate one file. Echos one JSON object on success/failure (single line).
# Sets globals: per-call we just print; the outer loop tallies via the JSON.
vs_validate_one() {
  local f="$1"
  local errors=() warnings=()

  if [ ! -f "$f" ]; then
    errors+=("file does not exist (failure: cannot stat '$f')")
    vs_emit_result "$f" "unknown" "" errors warnings
    return 1
  fi
  if [ ! -r "$f" ]; then
    errors+=("file is not readable (failure: re-run with sudo or fix mode 0600 ownership)")
    vs_emit_result "$f" "unknown" "" errors warnings
    return 1
  fi

  # Parse JSON. If jq fails, that's the whole story -- bail with the exact
  # parser error so the operator can fix the file.
  local parsed
  parsed=$(jq -c '.' "$f" 2>/tmp/68-vs-jqerr.$$)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    local jqerr; jqerr=$(cat /tmp/68-vs-jqerr.$$ 2>/dev/null | tr '\n' ' ' | head -c 300)
    rm -f /tmp/68-vs-jqerr.$$
    errors+=("not valid JSON (failure: $jqerr)")
    vs_emit_result "$f" "unknown" "" errors warnings
    return 1
  fi
  rm -f /tmp/68-vs-jqerr.$$

  # Discriminate per-user vs batch.
  local kind
  kind=$(printf '%s' "$parsed" | jq -r '.kind // "user"')
  local schema_ver
  schema_ver=$(printf '%s' "$parsed" | jq -r '.summaryVersion // "missing"')

  if [ "$schema_ver" != "1" ]; then
    errors+=("summaryVersion is '$schema_ver' (failure: expected integer 1 -- this validator only knows v1)")
  fi

  # Required top-level fields.
  local req_top
  if [ "$kind" = "batch" ]; then
    req_top=(summaryVersion writtenAt runId sourceFile userCount aggregate users)
  else
    req_top=(summaryVersion writtenAt host user runId authorizedKeysFile summary sources ok)
  fi
  for fld in "${req_top[@]}"; do
    if ! printf '%s' "$parsed" | jq -e --arg k "$fld" 'has($k)' >/dev/null 2>&1; then
      errors+=("missing required top-level field '$fld' (failure: schema v1 $kind doc requires it)")
    fi
  done

  # Counter block: summary{} for user, aggregate{} for batch.
  local cblock
  if [ "$kind" = "batch" ]; then cblock="aggregate"; else cblock="summary"; fi

  for c in "${VS_REQ_COUNTERS[@]}"; do
    # Pull type + value in one shot. type=="missing" if absent.
    local pair
    pair=$(printf '%s' "$parsed" | jq -r --arg b "$cblock" --arg c "$c" '
      if (.[$b]|type) != "object" then "missing\tnull"
      elif (.[$b] | has($c)) | not then "missing\tnull"
      else "\((.[$b][$c]|type))\t\((.[$b][$c]|tostring))"
      end')
    local ctype="${pair%%$'\t'*}"
    local cval="${pair#*$'\t'}"
    if [ "$ctype" = "missing" ]; then
      errors+=("$cblock.$c is missing (failure: required numeric counter)")
      continue
    fi
    if [ "$ctype" != "number" ]; then
      errors+=("$cblock.$c has wrong type '$ctype' (value=$cval) (failure: expected JSON number)")
      continue
    fi
    # Integer-ness + non-negative. jq's `floor == .` is the integer test.
    local intchk
    intchk=$(printf '%s' "$parsed" | jq -r --arg b "$cblock" --arg c "$c" '
      .[$b][$c] as $v
      | if ($v|floor) == $v and $v >= 0 then "ok"
        elif $v < 0 then "negative"
        else "fractional"
        end')
    case "$intchk" in
      ok) : ;;
      negative)   errors+=("$cblock.$c is negative ($cval) (failure: counters must be >= 0)") ;;
      fractional) errors+=("$cblock.$c is not an integer ($cval) (failure: counters must be whole numbers)") ;;
    esac
  done

  # sources{} block -- per-user only.
  if [ "$kind" != "batch" ]; then
    for c in "${VS_REQ_SOURCES[@]}"; do
      local pair
      pair=$(printf '%s' "$parsed" | jq -r --arg c "$c" '
        if (.sources|type) != "object" then "missing\tnull"
        elif (.sources | has($c)) | not then "missing\tnull"
        else "\((.sources[$c]|type))\t\((.sources[$c]|tostring))"
        end')
      local ctype="${pair%%$'\t'*}"
      local cval="${pair#*$'\t'}"
      if [ "$ctype" = "missing" ]; then
        errors+=("sources.$c is missing (failure: required numeric counter)")
        continue
      fi
      if [ "$ctype" != "number" ]; then
        errors+=("sources.$c has wrong type '$ctype' (value=$cval) (failure: expected JSON number)")
        continue
      fi
      local intchk
      intchk=$(printf '%s' "$parsed" | jq -r --arg c "$c" '
        .sources[$c] as $v
        | if ($v|floor) == $v and $v >= 0 then "ok"
          elif $v < 0 then "negative" else "fractional" end')
      case "$intchk" in
        ok) : ;;
        negative)   errors+=("sources.$c is negative ($cval) (failure: counters must be >= 0)") ;;
        fractional) errors+=("sources.$c is not an integer ($cval) (failure: counters must be whole numbers)") ;;
      esac
    done

    # ok must be boolean.
    local oktype
    oktype=$(printf '%s' "$parsed" | jq -r '.ok | type')
    if [ "$oktype" != "boolean" ]; then
      errors+=("'ok' has wrong type '$oktype' (failure: expected JSON boolean true/false)")
    fi
  fi

  # Soft consistency checks (only meaningful if counters parsed).
  if [ "${#errors[@]}" -eq 0 ]; then
    if [ "$kind" != "batch" ]; then
      local cons
      cons=$(printf '%s' "$parsed" | jq -r '
        .summary as $s
        | [
            (if ($s.keys_installed_new + $s.keys_preserved) != $s.keys_unique
                then "installed_new(\($s.keys_installed_new))+preserved(\($s.keys_preserved))!=unique(\($s.keys_unique))"
                else empty end),
            (if $s.keys_unique > $s.keys_parsed
                then "unique(\($s.keys_unique))>parsed(\($s.keys_parsed))"
                else empty end),
            (if $s.keys_installed_new > $s.keys_parsed
                then "installed_new(\($s.keys_installed_new))>parsed(\($s.keys_parsed))"
                else empty end)
          ] | .[]')
      if [ -n "$cons" ]; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          warnings+=("counter consistency: $line (warning: counters look internally inconsistent)")
        done <<< "$cons"
      fi
    else
      # Batch: aggregate must equal sum across users[].summary.
      local mismatch
      mismatch=$(printf '%s' "$parsed" | jq -r '
        . as $root
        | [ "sources_requested","keys_parsed","keys_unique",
            "keys_installed_new","keys_preserved" ]
        | map(
            . as $k
            | { k: $k,
                got: ($root.aggregate[$k]),
                sum: ([$root.users[].summary[$k] // 0] | add // 0) }
          )
        | map(select(.got != .sum))
        | map("aggregate.\(.k)=\(.got) but sum across users=\(.sum)")
        | .[]')
      if [ -n "$mismatch" ]; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          errors+=("$line (failure: batch rollup is inconsistent with per-user docs)")
        done <<< "$mismatch"
      fi
    fi
  fi

  vs_emit_result "$f" "$kind" "$schema_ver" errors warnings
  if [ "${#errors[@]}" -gt 0 ]; then return 1; fi
  if [ "$VS_STRICT" = "1" ] && [ "${#warnings[@]}" -gt 0 ]; then return 1; fi
  return 0
}

# ---- result emitters -------------------------------------------------------
# Stash NDJSON results and pretty lines so we can print a clean tally at end.
VS_RESULTS_NDJSON=()   # one JSON object per file
VS_PASS=0
VS_FAIL=0
VS_WARN=0

vs_emit_result() {
  # $1=path $2=kind $3=schemaVer $4=errors-array-name $5=warnings-array-name
  local path="$1" kind="$2" sv="$3"
  local -n _errs="$4"
  local -n _warns="$5"
  local status="pass"
  if [ "${#_errs[@]}" -gt 0 ]; then
    status="fail"
  elif [ "${#_warns[@]}" -gt 0 ]; then
    status="warn"
  fi

  # Build NDJSON via jq (escapes everything correctly).
  local ndjson
  ndjson=$(jq -cn \
    --arg p "$path" --arg k "$kind" --arg sv "$sv" --arg st "$status" \
    --argjson e "$(printf '%s\n' "${_errs[@]:-}" | jq -R . | jq -s '[.[]|select(.!="")]' )" \
    --argjson w "$(printf '%s\n' "${_warns[@]:-}" | jq -R . | jq -s '[.[]|select(.!="")]' )" \
    '{file:$p, kind:$k, summaryVersion:$sv, status:$st, errors:$e, warnings:$w}')
  VS_RESULTS_NDJSON+=("$ndjson")

  case "$status" in
    pass) VS_PASS=$((VS_PASS+1)) ;;
    warn) VS_WARN=$((VS_WARN+1)) ;;
    fail) VS_FAIL=$((VS_FAIL+1)) ;;
  esac

  if [ "$VS_JSON" = "1" ]; then
    printf '%s\n' "$ndjson"
    return 0
  fi
  if [ "$VS_QUIET" = "1" ]; then return 0; fi

  case "$status" in
    pass) log_ok   "[pass] $kind v$sv  $path" ;;
    warn) log_warn "[warn] $kind v$sv  $path" ;;
    fail) log_err  "[fail] $kind v$sv  $path" ;;
  esac
  for e in "${_errs[@]:-}";  do [ -z "$e" ] || log_err  "        ! $e"; done
  for w in "${_warns[@]:-}"; do [ -z "$w" ] || log_warn "        ~ $w"; done
}

# ---- main loop -------------------------------------------------------------
for f in "${VS_FILES[@]}"; do
  vs_validate_one "$f" || true
done

VS_TOTAL=$((VS_PASS + VS_WARN + VS_FAIL))
VS_OK=true
if [ "$VS_FAIL" -gt 0 ]; then VS_OK=false; fi
if [ "$VS_STRICT" = "1" ] && [ "$VS_WARN" -gt 0 ]; then VS_OK=false; fi

if [ "$VS_JSON" = "1" ]; then
  jq -cn \
    --argjson c "$VS_TOTAL" --argjson p "$VS_PASS" \
    --argjson f "$VS_FAIL"  --argjson w "$VS_WARN" \
    --argjson ok $([ "$VS_OK" = "true" ] && echo true || echo false) \
    --argjson strict $([ "$VS_STRICT" = "1" ] && echo true || echo false) \
    '{summary:{checked:$c,passed:$p,failed:$f,warned:$w}, strict:$strict, ok:$ok}'
else
  printf '\n'
  if [ "$VS_OK" = "true" ]; then
    log_ok "verify-summary: $VS_PASS pass / $VS_WARN warn / $VS_FAIL fail (of $VS_TOTAL) -- OK (exit 0)"
  else
    log_err "verify-summary: $VS_PASS pass / $VS_WARN warn / $VS_FAIL fail (of $VS_TOTAL) -- FAILED (exit 1)"
  fi
fi

[ "$VS_OK" = "true" ] && exit 0 || exit 1
