#!/usr/bin/env bash
# 66-vscode-menu-cleanup-mac :: 01-smoke.sh
#
# Sandboxed test: stage fake Services workflows + LaunchAgent plists +
# fake 'code' shims under a temp HOME, run the script in --dry-run and
# then apply mode, and assert the manifest reflects each surface.
#
# This test runs on Linux too (CI), because:
#   - the script's OS guard is checked separately
#   - we stub `uname` to report Darwin
#   - we stub `osascript` and `plutil` so the shell paths execute end-to-end
#
# All assertions print PASS/FAIL with the exact path that triggered them
# (CODE RED rule: every file/path failure must include the path + reason).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SANDBOX="$(mktemp -d -t scr66.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_HOME="$SANDBOX/home"
STUB_BIN="$SANDBOX/stub-bin"
mkdir -p "$FAKE_HOME/Library/Services" \
         "$FAKE_HOME/Library/LaunchAgents" \
         "$FAKE_HOME/.local/bin" \
         "$STUB_BIN"

# --- stub Darwin / plutil / osascript ------------------------------------
cat > "$STUB_BIN/uname" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo Darwin; else echo Darwin; fi
SH
cat > "$STUB_BIN/plutil" <<'SH'
#!/usr/bin/env bash
# -convert xml1 -o - <file>  : just cat the file (test plists are already XML).
f="${@: -1}"; cat "$f"
SH
cat > "$STUB_BIN/osascript" <<'SH'
#!/usr/bin/env bash
# Pretend no login items exist so the loginitem path is exercised + reports missing.
exit 0
SH
cat > "$STUB_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_BIN"/*

# --- stage targets -------------------------------------------------------
# Services workflow (matches *Code*.workflow)
mkdir -p "$FAKE_HOME/Library/Services/Open with Code.workflow"
touch    "$FAKE_HOME/Library/Services/Open with Code.workflow/Contents.plist"
# Unrelated workflow that must NOT be removed.
mkdir -p "$FAKE_HOME/Library/Services/Other Tool.workflow"

# User LaunchAgent referencing Code.app
cat > "$FAKE_HOME/Library/LaunchAgents/com.example.vscode-keepalive.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.vscode-keepalive</string>
  <key>ProgramArguments</key><array>
    <string>/Applications/Visual Studio Code.app/Contents/MacOS/Code</string>
  </array>
</dict></plist>
XML
# Unrelated agent that must be left alone.
cat > "$FAKE_HOME/Library/LaunchAgents/com.example.unrelated.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.unrelated</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
</dict></plist>
XML

# Fake user shim that DOES reference Code.app -> must be removed.
cat > "$FAKE_HOME/.local/bin/code" <<'SH'
#!/usr/bin/env bash
exec "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" "$@"
SH
chmod +x "$FAKE_HOME/.local/bin/code"

# Decoy shim that does NOT reference Code.app -> must be KEPT.
cat > "$FAKE_HOME/.local/bin/code-insiders" <<'SH'
#!/usr/bin/env bash
echo "this is not vscode"
SH
chmod +x "$FAKE_HOME/.local/bin/code-insiders"

# --- run script (dry-run + apply) ----------------------------------------
export HOME="$FAKE_HOME"
export PATH="$STUB_BIN:$PATH"
# Override the script's logs root so we don't pollute the repo.
export LOGS_OVERRIDE="$SANDBOX/logs"

cd "$SCRIPT_ROOT/.." || exit 2

echo "--- dry-run ---"
bash "$SCRIPT_ROOT/run.sh" --dry-run --scope user --no-color > "$SANDBOX/dry.out" 2>&1
RC_DRY=$?

# Dry-run assertions BEFORE the apply run (dry-run must not touch anything).
pass=0; fail=0
_assert() {
  local label="$1"; local cond="$2"
  if [ "$cond" -eq 0 ]; then echo "  PASS $label"; pass=$((pass+1));
  else echo "  FAIL $label"; fail=$((fail+1)); fi
}
[ -d "$FAKE_HOME/Library/Services/Open with Code.workflow" ]; _assert "dry-run kept Services workflow on disk" $?
[ -f "$FAKE_HOME/Library/LaunchAgents/com.example.vscode-keepalive.plist" ]; _assert "dry-run kept LaunchAgent plist on disk" $?
[ -x "$FAKE_HOME/.local/bin/code" ]; _assert "dry-run kept user shim on disk" $?
[ "$RC_DRY" -eq 0 ]; _assert "dry-run exit code = 0" $?

echo "--- apply ---"
bash "$SCRIPT_ROOT/run.sh"           --scope user --no-color --yes > "$SANDBOX/apply.out" 2>&1
RC_APPLY=$?
grep -q "Planned macOS VS Code menu cleanup" "$SANDBOX/apply.out"; _assert "apply rendered plan tree before deleting" $?
grep -q "Confirmation skipped: --yes"        "$SANDBOX/apply.out"; _assert "apply honored --yes" $?

# --- assertions ----------------------------------------------------------
# Apply: VS Code targets gone, decoys preserved.
[ ! -e "$FAKE_HOME/Library/Services/Open with Code.workflow" ]; _assert "apply removed Services workflow" $?
[   -d "$FAKE_HOME/Library/Services/Other Tool.workflow"      ]; _assert "apply preserved unrelated workflow" $?
[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.example.vscode-keepalive.plist" ]; _assert "apply removed VS Code LaunchAgent" $?
[   -f "$FAKE_HOME/Library/LaunchAgents/com.example.unrelated.plist"        ]; _assert "apply preserved unrelated LaunchAgent" $?
[ ! -e "$FAKE_HOME/.local/bin/code"                                          ]; _assert "apply removed VS Code user shim" $?
[   -x "$FAKE_HOME/.local/bin/code-insiders"                                 ]; _assert "apply preserved decoy shim" $?
[ "$RC_APPLY" -eq 0 ]; _assert "apply exit code = 0" $?

# Manifest exists + contains the surfaces we exercised.
manifest="$(ls -1 "$SANDBOX/logs/"*/manifest.json 2>/dev/null | tail -n 1)"
if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
  echo "  FAIL manifest written (looked for: $SANDBOX/logs/*/manifest.json)"
  fail=$((fail+1))
else
  echo "  PASS manifest written ($manifest)"; pass=$((pass+1))
  grep -q '"category":"services"'         "$manifest"; _assert "manifest mentions services"          $?
  grep -q '"category":"launchagents-user"' "$manifest"; _assert "manifest mentions launchagents-user" $?
  grep -q '"category":"shims-user"'        "$manifest"; _assert "manifest mentions shims-user"        $?

  # Verification block must be present in the manifest and must say PASS.
  grep -q '"verification"'                 "$manifest"; _assert "manifest contains verification block"          $?
  grep -q '"fail":0'                       "$manifest"; _assert "manifest reports verification fail=0"           $?
  grep -q '"result":"pass"'                "$manifest"; _assert "manifest contains at least one verify pass row" $?
fi

# Verify report must have been printed to the apply run output.
grep -q "verify phase (re-probing every targeted item)" "$SANDBOX/apply.out"; _assert "apply printed verify phase header" $?
grep -Eq "VERIFICATION VERDICT: .+ PASS"                "$SANDBOX/apply.out"; _assert "apply printed PASS verdict"        $?

# verify.tsv is written next to the manifest.
verify_tsv="$(dirname "$manifest")/verify.tsv"
[ -s "$verify_tsv" ]; _assert "verify.tsv written and non-empty ($verify_tsv)" $?

echo
echo "Results: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0