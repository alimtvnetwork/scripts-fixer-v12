#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 14-e2e-all-methods :: end-to-end inventory smoke
#
# Installs ONE sample entry under every method that's reachable on this
# host (autostart, systemd-user, shell-rc-app, shell-rc-env on Linux;
# launchagent + shell-rc-* on macOS), then runs a single `list` and a
# single `list --json` and asserts every entry shows up exactly where it
# was registered. Finally, tears every entry back down and asserts the
# inventory is empty (and the underlying artifacts are gone).
#
# The point of this test is to catch bugs that ONLY appear when multiple
# methods coexist -- e.g. one method's enumerator accidentally claiming
# another method's artifacts, or `list` collapsing duplicate names across
# methods. Per-method correctness is already covered by tests 02-08.
# ---------------------------------------------------------------------------
set -u
. "$(dirname "$0")/_framework.sh"
TF_NAME="14-e2e-all-methods"
tf_setup

os="$(uname -s)"
rc_file="$HOME/.bashrc"
printf '# user-content-keep\nalias ll="ls -la"\n' > "$rc_file"

# ---------- per-OS plan: list of "method|name|kind|artifact_path" rows ----
# kind is "app" or "env". artifact_path is the file we expect to exist
# after install (empty for env -- shell-rc-env is verified via grep).
plan=()
if [ "$os" = "Darwin" ]; then
  plan+=("launchagent|e2e-launch|app|$HOME/Library/LaunchAgents/com.lovable-startup.e2e-launch.plist")
  plan+=("shell-rc|e2e-shellapp|app|")
  plan+=("shell-rc|E2E_SHELL_VAR=hello|env|")
else
  plan+=("autostart|e2e-auto|app|$XDG_CONFIG_HOME/autostart/lovable-startup-e2e-auto.desktop")
  plan+=("systemd-user|e2e-sysd|app|$XDG_CONFIG_HOME/systemd/user/lovable-startup-e2e-sysd.service")
  plan+=("shell-rc|e2e-shellapp|app|")
  plan+=("shell-rc|E2E_SHELL_VAR=hello|env|")
fi

# ---------- INSTALL phase ------------------------------------------------
for row in "${plan[@]}"; do
  IFS='|' read -r method name kind path <<<"$row"
  if [ "$kind" = "app" ]; then
    case "$name" in
      e2e-sysd) tf_run_quiet app /usr/bin/sleep --name "$name" --method "$method" --args "3600" ;;
      *)        tf_run_quiet app /usr/bin/echo --name "$name" --method "$method" ;;
    esac
  else
    tf_run_quiet env "$name" --method "$method"
  fi
done

# Confirm each on-disk artifact landed where we expected (CODE RED rule:
# every file failure must report the exact path).
for row in "${plan[@]}"; do
  IFS='|' read -r method name kind path <<<"$row"
  if [ -n "$path" ]; then
    assert_file "$path" "[$method] artifact present at $path"
  fi
done
# Env block: verify markers + key are written into the rc file, and user
# content is untouched.
content=$(cat "$rc_file")
assert_contains '# >>> lovable-startup-env (managed) >>>' "$content" "[shell-rc-env] open marker present in $rc_file"
assert_contains "export E2E_SHELL_VAR='hello'"           "$content" "[shell-rc-env] key exported in $rc_file"
assert_contains 'alias ll="ls -la"'                      "$content" "[shell-rc-env] user content preserved in $rc_file"

# ---------- INVENTORY (text) --------------------------------------------
out=$(tf_run list 2>&1)
for row in "${plan[@]}"; do
  IFS='|' read -r method name kind path <<<"$row"
  expected_method="$method"
  [ "$method" = "shell-rc" ] && expected_method="shell-rc-$kind"
  assert_contains "$expected_method" "$out" "[list] reports method $expected_method"
  short="${name%%=*}"   # strip =value for env keys
  assert_contains "$short" "$out" "[list] reports entry name '$short' (method $expected_method)"
done

# ---------- INVENTORY (JSON) --------------------------------------------
# Each (method,name) pair must appear EXACTLY once in the JSON output --
# this is what catches cross-method enumeration bleed-through.
json=$(tf_run list --json 2>&1)
if command -v python3 >/dev/null 2>&1; then
  for row in "${plan[@]}"; do
    IFS='|' read -r method name kind path <<<"$row"
    expected_method="$method"
    [ "$method" = "shell-rc" ] && expected_method="shell-rc-$kind"
    short="${name%%=*}"
    count=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception as exc:
    print('JSON_PARSE_FAIL:' + str(exc))
    sys.exit(0)
rows = data if isinstance(data, list) else data.get('entries', [])
m, n = '$expected_method', '$short'
print(sum(1 for r in rows if r.get('method') == m and r.get('name') == n))
")
    assert_eq "1" "$count" "[list --json] exactly one row for ($expected_method, $short)"
  done
else
  printf '  %sSKIP%s python3 unavailable -- skipping JSON shape assertions\n' "$TF_YEL" "$TF_RST"
fi

# ---------- TEARDOWN phase ----------------------------------------------
for row in "${plan[@]}"; do
  IFS='|' read -r method name kind path <<<"$row"
  if [ "$kind" = "app" ]; then
    tf_run_quiet remove "$name" --method "$method"
  else
    short="${name%%=*}"
    tf_run_quiet remove "$short" --method "shell-rc-env"
  fi
done

# Artifacts must be gone; user rc content must survive.
for row in "${plan[@]}"; do
  IFS='|' read -r method name kind path <<<"$row"
  if [ -n "$path" ]; then
    assert_no_file "$path" "[teardown] artifact removed at $path"
  fi
done
content=$(cat "$rc_file")
assert_not_contains 'lovable-startup-env'      "$content" "[teardown] env markers gone from $rc_file"
assert_not_contains 'lovable-startup-app'      "$content" "[teardown] shell-rc-app markers gone from $rc_file"
assert_contains    'alias ll="ls -la"'         "$content" "[teardown] user content survives in $rc_file"

# Final inventory must be empty.
final=$(tf_run list 2>&1)
for row in "${plan[@]}"; do
  IFS='|' read -r method name kind path <<<"$row"
  short="${name%%=*}"
  assert_not_contains "$short" "$final" "[final list] no trace of '$short'"
done

tf_teardown
tf_summary