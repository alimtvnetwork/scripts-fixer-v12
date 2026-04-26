#!/usr/bin/env bash
# --------------------------------------------------------------------------
#  _shared/git-config-defaults.sh
#
#  Bash twin of `scripts/shared/git-config-defaults.ps1`. Both helpers read
#  the same `scripts/shared/git-config-defaults.json` so Windows + Linux +
#  macOS toolchains apply the SAME defaults. Keep them in sync.
#
#  Public:
#    apply_default_git_config [--config <path>] [--dry-run]
#
#  Modes (mirrored from PS1):
#    set-if-empty          -- write only if `git config --global k` is empty
#    set-always            -- always overwrite
#    set-if-missing-value  -- --add semantics; skip if exact value present
# --------------------------------------------------------------------------

# Resolve repo paths.
_GCD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GCD_REPO_ROOT="$(cd "$_GCD_DIR/../.." && pwd)"
_GCD_DEFAULT_JSON="$_GCD_REPO_ROOT/scripts/shared/git-config-defaults.json"

# Logger guard: source if not already loaded.
if ! declare -f log_info >/dev/null 2>&1; then
  if [ -f "$_GCD_DIR/logger.sh" ]; then . "$_GCD_DIR/logger.sh"; fi
fi
if ! declare -f log_file_error >/dev/null 2>&1; then
  if [ -f "$_GCD_DIR/file-error.sh" ]; then . "$_GCD_DIR/file-error.sh"; fi
fi

# ---- JSON parser selection ----
# Prefer jq (fast, ubiquitous); fall back to python3 (always present on
# Debian/Ubuntu/macOS in 2025+); finally fail loudly.
_gcd_have_jq()     { command -v jq      >/dev/null 2>&1; }
_gcd_have_python() { command -v python3 >/dev/null 2>&1; }

# Print "key<TAB>value<TAB>mode" for each effective default, after applying
# osOverrides for the current `uname -s`.
_gcd_dump_defaults() {
  local json="$1" os
  case "$(uname -s)" in
    Linux*)  os="linux"   ;;
    Darwin*) os="darwin"  ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
    *)       os="linux"   ;;
  esac

  if _gcd_have_jq; then
    jq -r --arg os "$os" '
      (.osOverrides[$os] // {}) as $ov
      | .defaults[]
      | [.key,
         ($ov[.key] // .value),
         (.mode // "set-if-empty")]
      | @tsv
    ' "$json"
    return
  fi

  if _gcd_have_python; then
    python3 - "$json" "$os" <<'PY'
import json, sys
with open(sys.argv[1]) as f: spec = json.load(f)
os = sys.argv[2]
ov = (spec.get("osOverrides") or {}).get(os, {})
for d in spec.get("defaults", []):
    k = d["key"]
    v = ov.get(k, d.get("value", ""))
    m = d.get("mode", "set-if-empty")
    print(f"{k}\t{v}\t{m}")
PY
    return
  fi

  log_file_error "$json" "no JSON parser found (need jq or python3)"
  return 1
}

_gcd_dump_url_rewrites() {
  local json="$1"
  if _gcd_have_jq; then
    jq -r '(.urlRewrites // [])[] | "url." + .to + ".insteadOf\t" + .from' "$json"
    return
  fi
  if _gcd_have_python; then
    python3 - "$json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: spec = json.load(f)
for r in (spec.get("urlRewrites") or []):
    print(f"url.{r['to']}.insteadOf\t{r['from']}")
PY
    return
  fi
  return 0  # already errored in dump_defaults
}

# Apply one (key, value, mode). Honors $GCD_DRYRUN.
_gcd_apply_one() {
  local key="$1" value="$2" mode="$3"
  local current; current=$(git config --global --get-all "$key" 2>/dev/null || true)

  case "$mode" in
    set-if-empty)
      if [ -n "$current" ]; then
        log_info "[git-config] keep $key = $current (already set)"
        return 0
      fi
      ;;
    set-if-missing-value)
      # Multi-value: skip if exact value present.
      if printf '%s\n' "$current" | grep -Fxq -- "$value"; then
        log_info "[git-config] keep $key (value '$value' already present)"
        return 0
      fi
      if [ "${GCD_DRYRUN:-0}" = "1" ]; then
        log_info "[git-config] DRYRUN: git config --global --add $key '$value'"
        return 0
      fi
      if git config --global --add "$key" "$value"; then
        log_ok "[git-config] add  $key = $value"
      else
        log_file_error "(git config --global --add $key)" "exit=$?"
        return 1
      fi
      return 0
      ;;
    set-always) ;; # fall through
    *)
      log_warn "[git-config] unknown mode '$mode' for $key -- skipping"
      return 0
      ;;
  esac

  if [ "${GCD_DRYRUN:-0}" = "1" ]; then
    log_info "[git-config] DRYRUN: git config --global $key '$value'"
    return 0
  fi
  if git config --global "$key" "$value"; then
    log_ok "[git-config] set  $key = $value"
  else
    log_file_error "(git config --global $key)" "exit=$?"
    return 1
  fi
}

apply_default_git_config() {
  local json="$_GCD_DEFAULT_JSON"
  GCD_DRYRUN="${GCD_DRYRUN:-0}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)  json="${2:-}"; shift 2 ;;
      --dry-run|-n) GCD_DRYRUN=1; shift ;;
      -h|--help)
        printf 'apply_default_git_config [--config <path>] [--dry-run]\n'
        return 0 ;;
      *) log_warn "[git-config] ignoring extra arg: $1"; shift ;;
    esac
  done

  if ! command -v git >/dev/null 2>&1; then
    log_file_error "(git)" "git not on PATH -- cannot apply defaults"
    return 1
  fi
  if [ ! -f "$json" ]; then
    log_file_error "$json" "git-config-defaults.json missing"
    return 1
  fi

  log_info "[git-config] applying defaults from $json"

  local rc=0 line key value mode
  while IFS=$'\t' read -r key value mode; do
    [ -z "${key:-}" ] && continue
    _gcd_apply_one "$key" "$value" "$mode" || rc=1
  done < <(_gcd_dump_defaults "$json")

  while IFS=$'\t' read -r key value; do
    [ -z "${key:-}" ] && continue
    _gcd_apply_one "$key" "$value" "set-if-missing-value" || rc=1
  done < <(_gcd_dump_url_rewrites "$json")

  if [ $rc -eq 0 ]; then
    log_ok "[git-config] defaults applied"
  else
    log_warn "[git-config] defaults applied with errors"
  fi
  return $rc
}

# Allow direct CLI invocation: `bash git-config-defaults.sh [--dry-run]`
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  apply_default_git_config "$@"
fi