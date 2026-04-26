#!/usr/bin/env bash
# Verify `duplicates` reports same-name cross-method collisions and
# same-content file-body collisions in table, JSON, and CSV formats.
set -u
. "$(dirname "$0")/_framework.sh"
TF_NAME="13-duplicates"
tf_setup

# 1. Empty home -> "no duplicates found." in table mode.
out=$(tf_run duplicates 2>/dev/null); rc=$?
assert_exit 0 "$rc" "duplicates on empty home exits 0"
assert_contains 'no duplicates found.' "$out" "empty: friendly message"

# Empty home -> JSON with 0/0 counts and empty groups.
out=$(tf_run duplicates --json 2>/dev/null)
assert_contains '"by_name_count": 0'    "$out" "empty json: by_name=0"
assert_contains '"by_content_count": 0' "$out" "empty json: by_content=0"
assert_contains '"groups": []'          "$out" "empty json: groups=[]"

# 2. Plant a same-name collision: register 'demo' under TWO methods.
tf_run_quiet app /usr/bin/echo --name demo --method autostart
tf_run_quiet app /usr/bin/echo --name demo --method shell-rc
# And a unique entry that should NOT show up in the report.
tf_run_quiet app /usr/bin/echo --name solo --method autostart

out=$(tf_run duplicates 2>/dev/null); rc=$?
assert_exit 0 "$rc" "duplicates with collisions exits 0"
assert_contains 'DUPLICATES REPORT'     "$out" "table header present"
assert_contains '[by-name]'             "$out" "by-name section present"
assert_contains 'name = demo'           "$out" "demo group reported"
assert_contains 'autostart'             "$out" "demo: autostart row"
assert_contains 'shell-rc-app'          "$out" "demo: shell-rc-app row"
assert_not_contains 'name = solo'       "$out" "solo not flagged"
assert_contains '1 by-name group'       "$out" "summary counts 1 by-name"

# 3. JSON format: same expectations.
out=$(tf_run duplicates --json 2>/dev/null)
assert_contains '"by_name_count": 1'    "$out" "json: by_name_count=1"
assert_contains '"key": "demo"'         "$out" "json: demo key"
assert_contains '"kind": "by-name"'     "$out" "json: by-name kind"
assert_contains '"count": 2'            "$out" "json: 2 entries in group"
if command -v python3 >/dev/null 2>&1; then
  parsed=$(printf '%s' "$out" | python3 -c '
import sys, json
d = json.load(sys.stdin)
grp = [g for g in d["groups"] if g["key"] == "demo"][0]
methods = sorted(e["method"] for e in grp["entries"])
print(",".join(methods))
')
  assert_eq "autostart,shell-rc-app" "$parsed" "json: methods sorted correctly"
fi

# 4. CSV format: header + one row per entry in each group.
out=$(tf_run duplicates --csv 2>/dev/null)
assert_contains 'kind,key,method,name,path,scope' "$out" "csv: header"
assert_contains 'by-name,demo,autostart,demo,'    "$out" "csv: autostart row"
assert_contains 'by-name,demo,shell-rc-app,demo,' "$out" "csv: shell-rc-app row"

# 5. --output writes the table report to disk.
report_path="$TF_HOME/reports/dupes.txt"
tf_run duplicates --output "$report_path" >/dev/null 2>&1; rc=$?
assert_exit 0 "$rc" "duplicates --output exits 0"
assert_file "$report_path" "table report file created"
assert_contains 'name = demo' "$(cat "$report_path")" "report file: demo group"

# JSON to file.
json_path="$TF_HOME/reports/dupes.json"
tf_run duplicates --json --output "$json_path" >/dev/null 2>&1
assert_file "$json_path" "json report file created"
assert_contains '"by_name_count": 1' "$(cat "$json_path")" "json file: by_name_count"

# 6. Content-hash duplicate: two autostart entries pointing at the SAME
#    target command produce identical .desktop bodies up to the
#    `lovable-startup-NAME` self-reference, so they hash differently.
#    To force a content match, copy one .desktop on top of another after
#    creation. This isolates the by-content path.
tf_run_quiet app /usr/bin/true --name twin-a --method autostart
tf_run_quiet app /usr/bin/true --name twin-b --method autostart
cp "$XDG_CONFIG_HOME/autostart/lovable-startup-twin-a.desktop" \
   "$XDG_CONFIG_HOME/autostart/lovable-startup-twin-b.desktop"

out=$(tf_run duplicates 2>/dev/null)
assert_contains '[by-content]'      "$out" "by-content section present"
assert_contains 'twin-a'            "$out" "by-content: twin-a"
assert_contains 'twin-b'            "$out" "by-content: twin-b"
assert_contains 'by-content group'  "$out" "summary mentions by-content"

# 7. Foreign files in the autostart dir must NOT enter the report.
printf '[Desktop Entry]\nName=Foreign\n' > "$XDG_CONFIG_HOME/autostart/foreign.desktop"
out=$(tf_run duplicates --json 2>/dev/null)
assert_not_contains 'foreign' "$out" "foreign .desktop excluded from report"

tf_teardown
tf_summary