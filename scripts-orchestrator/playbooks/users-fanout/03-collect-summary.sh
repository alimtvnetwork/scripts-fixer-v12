#!/usr/bin/env bash
# users-fanout step 03: emit a one-line JSON summary the controller can
# grep out of the audit log. Format:
#   ---FANOUT-SUMMARY-JSON--- {"playbook":"users-fanout","host":"...","users":N,"ok":true}
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
BUNDLE="$REMOTE_TMP/users-fanout.json"

count=0
if [ -f "$BUNDLE" ] && command -v jq >/dev/null 2>&1; then
  count=$(jq 'if type=="array" then length elif (type=="object" and has("users")) then (.users|length) else 1 end' "$BUNDLE" 2>/dev/null || echo 0)
fi

printf -- '---FANOUT-SUMMARY-JSON--- {"playbook":"users-fanout","host":"%s","users":%s,"ok":true}\n' \
  "$(hostname)" "$count"

# Best-effort cleanup so /tmp doesn't accumulate password-bearing JSON.
rm -f "$BUNDLE" 2>/dev/null || true
echo "[OK] users-fanout: summary emitted on $(hostname)"
