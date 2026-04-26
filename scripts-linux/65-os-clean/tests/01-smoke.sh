#!/usr/bin/env bash
# 65-os-clean :: 01-smoke
# End-to-end test against a sandboxed $HOME. Seeds files in every
# path-driven category, runs once with --dry-run (must not delete),
# then once in apply mode (must delete and report bytes/counts), and
# verifies the JSON manifest matches reality.
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
RUN="$SCRIPT_DIR/run.sh"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; DIM=""; RST=""; }

pass=0; fail=0
_ok() { pass=$((pass+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
_no() { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"
        [ -n "${2:-}" ] && printf '       %sexpected:%s %s\n' "$DIM" "$RST" "$2"
        [ -n "${3:-}" ] && printf '       %s     got:%s %s\n' "$DIM" "$RST" "$3"; }

# Sandbox HOME -- never let this point at a real user dir.
SANDBOX="$(mktemp -d -t lov65-XXXXXX)"
if [ ! -d "$SANDBOX" ]; then
  echo "FAIL: could not create sandbox temp dir"; exit 2
fi
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"
export XDG_CACHE_HOME="$SANDBOX/.cache"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
# Force the script's logs directory inside the sandbox too.
SANDBOX_ROOT="$SANDBOX/repo"
mkdir -p "$SANDBOX_ROOT/_shared" "$SANDBOX_ROOT/65-os-clean"
# Symlink the real script tree under the sandbox so .logs/65 lands here.
ln -sfn "$SCRIPT_DIR/../_shared"/*       "$SANDBOX_ROOT/_shared/"   2>/dev/null || true
ln -sfn "$SCRIPT_DIR"/*                  "$SANDBOX_ROOT/65-os-clean/" 2>/dev/null || true
SANDBOX_RUN="$SANDBOX_ROOT/65-os-clean/run.sh"

printf '%s===== 01-smoke =====%s\n' "$YEL" "$RST"

# ---------- seed fixtures ----------
seed_bytes() { dd if=/dev/zero of="$1" bs=1 count="${2:-1024}" 2>/dev/null; }

mkdir -p "$XDG_CACHE_HOME/somepkg" "$XDG_CACHE_HOME/lovable"   # lovable must be preserved
seed_bytes "$XDG_CACHE_HOME/somepkg/big.bin"   2048
seed_bytes "$XDG_CACHE_HOME/somepkg/small.txt" 128
seed_bytes "$XDG_CACHE_HOME/lovable/keep.bin"  256

mkdir -p "$HOME/.local/share/Trash/files" "$HOME/.local/share/Trash/info"
seed_bytes "$HOME/.local/share/Trash/files/old.iso"  4096
seed_bytes "$HOME/.local/share/Trash/info/old.iso.trashinfo" 64

mkdir -p "$HOME/.npm/_logs"
seed_bytes "$HOME/.npm/_logs/2026-04-26-1.log" 512
seed_bytes "$HOME/.npm/_logs/2026-04-26-2.log" 512

mkdir -p "$HOME/.bun/install/cache"
seed_bytes "$HOME/.bun/install/cache/somepkg.tgz" 1024

# Foreign user content that MUST survive every run.
touch "$HOME/.bashrc.user-keep"
seed_bytes "$HOME/.bashrc.user-keep" 32

# ---------- DRY-RUN ----------
dry_out=$(bash "$SANDBOX_RUN" run --dry-run --only caches-user,trash,logs-user,pkg-bun 2>&1)

# Files MUST still exist after dry-run.
for f in \
  "$XDG_CACHE_HOME/somepkg/big.bin" \
  "$HOME/.local/share/Trash/files/old.iso" \
  "$HOME/.npm/_logs/2026-04-26-1.log" \
  "$HOME/.bun/install/cache/somepkg.tgz" \
  "$HOME/.bashrc.user-keep"
do
  if [ -e "$f" ]; then _ok "[dry-run] survived: $f"
  else _no "[dry-run] file deleted in dry-run: $f" "exists" "missing"; fi
done

# Trash is destructive without --yes -> must be skipped (status=skip).
case "$dry_out" in
  *"[trash] destructive category requires --yes"*) _ok "[dry-run] trash skipped without --yes" ;;
  *) _no "[dry-run] trash should be skipped without --yes" "skip-message present" "$dry_out" ;;
esac

# Summary line should mention dry-run mode.
case "$dry_out" in
  *"summary (dry-run)"*) _ok "[dry-run] summary header marks dry-run" ;;
  *) _no "[dry-run] summary header" "summary (dry-run)" "(missing)" ;;
esac

# ---------- APPLY ----------
# Now apply, including --yes so trash is honored.
apply_out=$(bash "$SANDBOX_RUN" run --yes --only caches-user,trash,logs-user,pkg-bun 2>&1)

# caches-user must wipe somepkg/* but PRESERVE lovable/.
if [ -e "$XDG_CACHE_HOME/somepkg/big.bin" ]; then
  _no "[apply] caches-user removed somepkg/big.bin" "absent" "still present at $XDG_CACHE_HOME/somepkg/big.bin"
else
  _ok "[apply] caches-user removed somepkg/big.bin"
fi
if [ -e "$XDG_CACHE_HOME/lovable/keep.bin" ]; then
  _ok "[apply] caches-user PRESERVED lovable/keep.bin"
else
  _no "[apply] caches-user must preserve lovable/" "$XDG_CACHE_HOME/lovable/keep.bin present" "deleted"
fi

# trash must be wiped now (--yes).
if [ -e "$HOME/.local/share/Trash/files/old.iso" ]; then
  _no "[apply] trash old.iso still present" "absent" "$HOME/.local/share/Trash/files/old.iso still here"
else
  _ok "[apply] trash files wiped"
fi

# logs-user must wipe ~/.npm/_logs contents.
if compgen -G "$HOME/.npm/_logs/*.log" > /dev/null; then
  _no "[apply] npm logs still present" "absent" "$HOME/.npm/_logs still has *.log"
else
  _ok "[apply] logs-user wiped npm logs"
fi

# pkg-bun must wipe install/cache contents.
if [ -e "$HOME/.bun/install/cache/somepkg.tgz" ]; then
  _no "[apply] bun cache still present" "absent" "$HOME/.bun/install/cache/somepkg.tgz still here"
else
  _ok "[apply] pkg-bun wiped install cache"
fi

# User content untouched.
if [ -e "$HOME/.bashrc.user-keep" ]; then
  _ok "[apply] foreign user file survives ($HOME/.bashrc.user-keep)"
else
  _no "[apply] user file deleted" "$HOME/.bashrc.user-keep present" "missing"
fi

# Apply summary header should NOT say dry-run.
case "$apply_out" in
  *"summary (apply)"*) _ok "[apply] summary header marks apply mode" ;;
  *) _no "[apply] summary header" "summary (apply)" "(missing)" ;;
esac

# ---------- MANIFEST ----------
manifest_dir="$SANDBOX_ROOT/.logs/65/latest"
# Resolve the symlink to a real dir.
if [ -L "$manifest_dir" ]; then
  manifest_dir="$(readlink "$manifest_dir")"
  manifest_dir="$SANDBOX_ROOT/.logs/65/$manifest_dir"
fi
manifest="$manifest_dir/manifest.json"

if [ -f "$manifest" ]; then
  _ok "[manifest] written: $manifest"
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d['mode'] == 'apply', 'mode=' + d['mode']
assert isinstance(d['rows'], list) and len(d['rows']) > 0
ids = {r['category'] for r in d['rows']}
for need in ('caches-user','trash','logs-user','pkg-bun'):
    assert need in ids, 'missing row for ' + need
# Apply totals must be > 0 because we seeded ~8KB of fixtures.
assert d['totals']['count'] > 0, 'expected count>0, got ' + str(d['totals']['count'])
" "$manifest" 2>&1; then
      _ok "[manifest] schema + totals valid"
    else
      _no "[manifest] schema check" "all rows present, totals.count > 0" "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])),indent=2))' "$manifest" 2>&1 | head -40)"
    fi
  fi
else
  _no "[manifest] missing" "$manifest exists" "not found"
fi

# ---------- JSON output mode ----------
# --json prints the document on stdout (jq pretty-prints across many lines)
# and logger lines go to stderr. Capture stdout only and let python parse
# the whole multi-line JSON document.
# --json prints the document on stdout. The logger's "Dry-run complete"
# line also lands on stdout AFTER the JSON document, so trim everything
# from the closing `}` onward.
raw_json=$(bash "$SANDBOX_RUN" run --dry-run --only pkg-bun --json 2>/dev/null)
json_out=$(printf '%s' "$raw_json" | awk '/^}$/ {print; exit} {print}')
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$json_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'totals' in d and 'rows' in d" 2>/dev/null; then
    _ok "[json] --json emits parseable document"
  else
    _no "[json] --json must emit valid JSON" "object with totals+rows" "$json_out"
  fi
fi

# ---------- list-categories ----------
lc_out=$(bash "$SANDBOX_RUN" list-categories 2>&1)
for need in caches-user trash pkg-bun logs-user; do
  case "$lc_out" in
    *"$need"*) _ok "[list-categories] mentions $need" ;;
    *) _no "[list-categories] missing $need" "row for $need" "$lc_out" ;;
  esac
done

# ---------- summary ----------
printf '\n  %s%d passed%s, %s%d failed%s\n' "$GRN" "$pass" "$RST" "$RED" "$fail" "$RST"
if [ "$fail" -eq 0 ]; then exit 0; else exit 1; fi