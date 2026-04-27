#!/usr/bin/env bash
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
BUNDLE="$REMOTE_TMP/groups-fanout.json"
count=0
if [ -f "$BUNDLE" ] && command -v jq >/dev/null 2>&1; then
  count=$(jq 'if type=="array" then length elif (type=="object" and has("groups")) then (.groups|length) else 1 end' "$BUNDLE" 2>/dev/null || echo 0)
fi
printf -- '---FANOUT-SUMMARY-JSON--- {"playbook":"groups-fanout","host":"%s","groups":%s,"ok":true}\n' \
  "$(hostname)" "$count"
rm -f "$BUNDLE" 2>/dev/null || true
echo "[OK] groups-fanout: summary emitted on $(hostname)"
