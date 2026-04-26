#!/usr/bin/env bash
# 67-vscode-cleanup-linux :: 01-smoke.sh
#
# Sandboxed test: stage fake "tarball" + "user-config" install artifacts
# under a temp HOME and run the script in dry-run, then apply mode, asserting
# only the matching artifacts get removed.
#
# We deliberately exercise the user-scope paths only (no sudo). Apt/snap/deb
# paths are tested via stubs that report "not installed" so the run is fast
# and deterministic on any CI box.
#
# Every assertion prints PASS/FAIL with the exact path that triggered it
# (CODE RED rule: every file/path failure must include the path + reason).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SANDBOX="$(mktemp -d -t scr67.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_HOME="$SANDBOX/home"
STUB_BIN="$SANDBOX/stub-bin"
mkdir -p "$FAKE_HOME/.config" \
         "$FAKE_HOME/.local/bin" \
         "$FAKE_HOME/.local/share" \
         "$STUB_BIN"

# --- stub Linux + dpkg/snap/apt-get (all report "not installed") --------
cat > "$STUB_BIN/dpkg" <<'SH'
#!/usr/bin/env bash
# dpkg -s <pkg> -> always exit 1 ("not installed") so apt/deb methods stay
# undetected and don't run any system-scope steps.
exit 1
SH
cat > "$STUB_BIN/snap" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$STUB_BIN/apt-get" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_BIN"/*

# --- stage targets -------------------------------------------------------
# tarball method: ~/.local/share/code dir + per-user shim that references it.
mkdir -p "$FAKE_HOME/.local/share/code/bin"
touch    "$FAKE_HOME/.local/share/code/bin/code"
cat > "$FAKE_HOME/.local/bin/code" <<'SH'
#!/usr/bin/env bash
exec "$HOME/.local/share/code/bin/code" "$@"
SH
chmod +x "$FAKE_HOME/.local/bin/code"

# user-config method: ~/.config/Code + ~/.vscode-server
mkdir -p "$FAKE_HOME/.config/Code/User"
echo '{"editor.fontSize":14}' > "$FAKE_HOME/.config/Code/User/settings.json"
mkdir -p "$FAKE_HOME/.vscode-server/data/Machine"
touch    "$FAKE_HOME/.vscode-server/data/Machine/settings.json"

# Decoy: an unrelated dotfile dir we must NOT touch.
mkdir -p "$FAKE_HOME/.config/UnrelatedTool"
touch    "$FAKE_HOME/.config/UnrelatedTool/settings.json"

# --- run script (detect, dry-run, apply) --------------------------------
export HOME="$FAKE_HOME"
export PATH="$STUB_BIN:$PATH"
# Override the script's logs root so we don't pollute the repo.
export LOGS_OVERRIDE="$SANDBOX/logs"

pass=0; fail=0
_assert() {
  local label="$1"; local cond="$2"
  if [ "$cond" -eq 0 ]; then echo "  PASS $label"; pass=$((pass+1));
  else echo "  FAIL $label"; fail=$((fail+1)); fi
}

echo "--- detect ---"
bash "$SCRIPT_ROOT/run.sh" detect --scope user --no-color > "$SANDBOX/detect.out" 2>&1
RC_DETECT=$?
grep -q "detected 'tarball'"     "$SANDBOX/detect.out"; _assert "detect found tarball method" $?
grep -q "detected 'user-config'" "$SANDBOX/detect.out"; _assert "detect found user-config method" $?
grep -Eq "'apt' not detected"   "$SANDBOX/detect.out"; _assert "detect reported apt as not present" $?
[ "$RC_DETECT" -eq 0 ]; _assert "detect exit code = 0" $?

echo "--- dry-run ---"
bash "$SCRIPT_ROOT/run.sh" --dry-run --scope user --no-color > "$SANDBOX/dry.out" 2>&1
RC_DRY=$?
# Dry-run must not touch anything.
[ -d "$FAKE_HOME/.local/share/code"   ]; _assert "dry-run kept tarball dir on disk"     $?
[ -d "$FAKE_HOME/.config/Code"        ]; _assert "dry-run kept user-config dir on disk" $?
[ -x "$FAKE_HOME/.local/bin/code"     ]; _assert "dry-run kept user shim on disk"       $?
[ "$RC_DRY" -eq 0 ]; _assert "dry-run exit code = 0" $?

echo "--- apply ---"
bash "$SCRIPT_ROOT/run.sh" --scope user --no-color > "$SANDBOX/apply.out" 2>&1
RC_APPLY=$?

# Apply: only matching artifacts gone, decoys preserved.
[ ! -d "$FAKE_HOME/.local/share/code"           ]; _assert "apply removed tarball dir"                $?
[ ! -e "$FAKE_HOME/.local/bin/code"             ]; _assert "apply removed per-user shim"              $?
[ ! -d "$FAKE_HOME/.config/Code"                ]; _assert "apply removed ~/.config/Code"             $?
[ ! -d "$FAKE_HOME/.vscode-server"              ]; _assert "apply removed ~/.vscode-server"           $?
[   -d "$FAKE_HOME/.config/UnrelatedTool"        ]; _assert "apply preserved decoy ~/.config/UnrelatedTool" $?
[ "$RC_APPLY" -eq 0 ]; _assert "apply exit code = 0" $?

# Manifest exists + lists detected methods.
manifest="$(ls -1 "$SANDBOX/logs/"*/manifest.json 2>/dev/null | tail -n 1)"
if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
  echo "  FAIL manifest written (looked for: $SANDBOX/logs/*/manifest.json)"
  fail=$((fail+1))
else
  echo "  PASS manifest written ($manifest)"; pass=$((pass+1))
  grep -q '"tarball"'                "$manifest"; _assert "manifest mentions tarball"     $?
  grep -q '"user-config"'            "$manifest"; _assert "manifest mentions user-config" $?
  grep -q '"method":"tarball"'       "$manifest"; _assert "manifest has tarball rows"     $?
fi

echo
echo "Results: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0