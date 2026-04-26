#!/usr/bin/env bash
# Verify `list --method M` filters table + JSON output by registration type.
set -u
. "$(dirname "$0")/_framework.sh"
TF_NAME="11-list-method-filter"
tf_setup

# Plant one entry per supported method so each filter has a clear hit/miss.
tf_run_quiet app /usr/bin/echo --name app1 --method autostart
tf_run_quiet app /usr/bin/echo --name app2 --method shell-rc
tf_run_quiet env "FOO=bar"             --method shell-rc

# 1. Table: --method autostart shows only the autostart row.
out=$(tf_run list --method autostart 2>/dev/null); rc=$?
assert_exit 0 "$rc" "list --method autostart exits 0"
assert_contains 'autostart'    "$out" "autostart row present"
assert_contains '1 entry'      "$out" "footer reports 1 entry"
assert_not_contains 'shell-rc-app' "$out" "shell-rc-app row excluded"
assert_not_contains 'shell-rc-env' "$out" "shell-rc-env row excluded"

# 2. Table: --method shell-rc is a family alias matching app + env blocks.
out=$(tf_run list --method shell-rc 2>/dev/null)
assert_contains 'shell-rc-app' "$out" "alias: shell-rc-app present"
assert_contains 'shell-rc-env' "$out" "alias: shell-rc-env present"
assert_contains '2 entries'    "$out" "alias: 2 entries reported"
assert_not_contains 'autostart' "$out" "alias: autostart excluded"

# 3. Table: --method=KEY=VAL form (= syntax) works for shell-rc-env.
out=$(tf_run list --method=shell-rc-env 2>/dev/null)
assert_contains 'shell-rc-env' "$out" "= syntax: env row present"
assert_not_contains 'shell-rc-app' "$out" "= syntax: app row excluded"

# 4. JSON: --json + --method autostart -> count=1, only autostart entry.
out=$(tf_run list --json --method autostart 2>/dev/null); rc=$?
assert_exit 0 "$rc" "list --json --method autostart exits 0"
assert_contains '"count": 1'              "$out" "json: count=1"
assert_contains '"method": "autostart"'   "$out" "json: autostart entry"
assert_not_contains '"method": "shell-rc-app"' "$out" "json: shell-rc-app excluded"
assert_not_contains '"method": "shell-rc-env"' "$out" "json: shell-rc-env excluded"

# 5. JSON: --method shell-rc family alias -> count=2, no autostart.
out=$(tf_run list --json --method shell-rc 2>/dev/null)
assert_contains '"count": 2'              "$out" "json alias: count=2"
assert_contains '"method": "shell-rc-app"' "$out" "json alias: app entry"
assert_contains '"method": "shell-rc-env"' "$out" "json alias: env entry"
assert_not_contains '"method": "autostart"' "$out" "json alias: autostart excluded"

# 6. Unknown method -> no rows in either format (no crash, exit 0).
out=$(tf_run list --method bogus-method 2>/dev/null); rc=$?
assert_exit 0 "$rc" "list --method bogus exits 0"
assert_contains '0 entries' "$out" "bogus method: 0 entries"

out=$(tf_run list --json --method bogus-method 2>/dev/null)
assert_contains '"count": 0'    "$out" "json bogus: count=0"
assert_contains '"entries": []' "$out" "json bogus: empty entries"

# 7. Omitting --method preserves prior behaviour (all 3 entries).
out=$(tf_run list 2>/dev/null)
assert_contains '3 entries' "$out" "no filter: all 3 entries listed"

tf_teardown
tf_summary