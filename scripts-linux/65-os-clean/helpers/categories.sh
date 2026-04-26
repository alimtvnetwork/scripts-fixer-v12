#!/usr/bin/env bash
# 65-os-clean :: helpers/categories.sh
# Reads config.json (jq if available, python3 fallback) and provides
# per-category accessors. Keeps the JSON shape opaque to run.sh.

_OSC_CFG=""             # cached config path
_OSC_CFG_RAW=""         # cached raw JSON for python fallback
_OSC_OS=""              # "linux" | "macos"

osc_init() {
  _OSC_CFG="$1"
  if [ ! -f "$_OSC_CFG" ]; then
    log_file_error "$_OSC_CFG" "config.json missing"
    return 1
  fi
  _OSC_CFG_RAW="$(cat "$_OSC_CFG")"
  case "$(uname -s)" in
    Darwin) _OSC_OS="macos" ;;
    Linux)  _OSC_OS="linux" ;;
    *)      _OSC_OS="linux" ;;
  esac
}

osc_os() { printf '%s\n' "$_OSC_OS"; }

_osc_jq()  { command -v jq      >/dev/null 2>&1; }
_osc_py()  { command -v python3 >/dev/null 2>&1; }

_osc_query() {
  # $1 = jq filter
  if _osc_jq; then
    printf '%s' "$_OSC_CFG_RAW" | jq -r "$1"
    return $?
  fi
  if _osc_py; then
    printf '%s' "$_OSC_CFG_RAW" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# Translate a tiny subset of jq we need into python expressions.
expr = sys.argv[1]
def get(node, path):
    for p in path:
        if p == '': continue
        if isinstance(node, dict): node = node.get(p)
        elif isinstance(node, list):
            try: node = node[int(p)]
            except: return None
        else: return None
        if node is None: return None
    return node
# Supported expressions (kept narrow on purpose):
#   .categories | keys[]
#   .categories.<id>.<field>
#   .categories.<id>.paths.<os>[]
#   .categories.<id>.applyCmd[]
#   .categories.<id>.dryCmd[]
#   .destructiveRequiresYes[]
#   .excludeCategories[]
#   .applyByDefault
if expr == '.categories | keys[]':
    for k in (d.get('categories') or {}).keys(): print(k)
elif expr == '.destructiveRequiresYes[]':
    for v in d.get('destructiveRequiresYes') or []: print(v)
elif expr == '.excludeCategories[]':
    for v in d.get('excludeCategories') or []: print(v)
elif expr == '.applyByDefault':
    print('true' if d.get('applyByDefault') else 'false')
elif expr.startswith('.categories.'):
    rest = expr[len('.categories.'):]
    # strip array-iter suffix '[]' if present
    is_iter = rest.endswith('[]')
    if is_iter: rest = rest[:-2]
    # Honor double-quoted segments so '.\"caches-user\".mode' parses to
    # ['caches-user', 'mode'] instead of being split on the hyphen-free
    # boundaries (jq quotes hyphenated ids; we mirror that here).
    parts = []
    buf = ''
    in_q = False
    for ch in rest:
        if ch == '\"':
            in_q = not in_q
        elif ch == '.' and not in_q:
            if buf != '': parts.append(buf)
            buf = ''
        else:
            buf += ch
    if buf != '': parts.append(buf)
    node = get(d.get('categories') or {}, parts)
    if node is None: pass
    elif is_iter and isinstance(node, list):
        for v in node: print(v)
    elif isinstance(node, (dict,list)): print(json.dumps(node))
    elif isinstance(node, bool): print('true' if node else 'false')
    else: print(node)
else:
    print('UNSUPPORTED_EXPR:'+expr, file=sys.stderr); sys.exit(2)
" "$1"
    return $?
  fi
  log_file_error "$_OSC_CFG" "neither jq nor python3 available to parse config"
  return 1
}

osc_category_ids() { _osc_query '.categories | keys[]'; }

osc_field() {
  # $1=cat $2=field
  # NOTE: jq treats `.foo-bar` as subtraction, so always quote category ids.
  _osc_query ".categories.\"$1\".$2"
}

osc_paths_for_os() {
  # Print one expanded path per line. Honors per-OS branch and runs the
  # raw entries through `eval echo` so $HOME/${XDG_*}/${TMPDIR:-...} expand.
  local cat="$1" os="${2:-$_OSC_OS}"
  _osc_query ".categories.\"$cat\".paths.$os[]" 2>/dev/null \
    | while IFS= read -r raw; do
        [ -z "$raw" ] && continue
        # Safe expansion: only env-var refs, no command substitution allowed.
        case "$raw" in
          *'`'*|*'$('*)
            log_file_error "$raw" "config path contains command substitution -- refusing to expand"
            continue
            ;;
        esac
        # shellcheck disable=SC2086
        eval "printf '%s\n' \"$raw\""
      done
}

osc_cmd_array() {
  # $1=cat $2=applyCmd|dryCmd
  # Emits one argv element per line.
  local cat="$1" which="$2"
  _osc_query ".categories.\"$cat\".$which[]" 2>/dev/null
}

osc_in_list() {
  # $1=needle, rest=haystack
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

osc_destructive_requires_yes() { _osc_query '.destructiveRequiresYes[]'; }
osc_excluded_default()         { _osc_query '.excludeCategories[]'; }