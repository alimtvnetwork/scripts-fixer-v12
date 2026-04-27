#!/usr/bin/env bash
# ssh-keys-fanout step 03: emit ledger snapshot + summary so the controller
# can fold per-host history into a central audit picture.
#
# Format (one line, base64 to survive single-line audit log):
#   ---FANOUT-LEDGER-JSON--- {"host":"...","entries":N,"snapshot_b64":"..."}
set -e
TARGET_USER="${TARGET_USER:-$(id -un)}"
HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
LEDGER="${HOME_DIR}/.lovable/ssh-keys-state.json"

entries=0
snapshot_b64=""
if [ -f "$LEDGER" ]; then
  if command -v jq >/dev/null 2>&1; then
    entries=$(jq '.entries | length' "$LEDGER" 2>/dev/null || echo 0)
  fi
  snapshot_b64=$(base64 -w0 < "$LEDGER" 2>/dev/null || base64 < "$LEDGER" | tr -d '\n')
else
  echo "[INFO] ssh-keys-fanout: no ledger at $LEDGER on $(hostname) (first install or non-tracked path)"
fi

printf -- '---FANOUT-SUMMARY-JSON--- {"playbook":"ssh-keys-fanout","host":"%s","user":"%s","entries":%s,"ok":true}\n' \
  "$(hostname)" "$TARGET_USER" "$entries"
printf -- '---FANOUT-LEDGER-JSON--- {"host":"%s","user":"%s","entries":%s,"snapshot_b64":"%s"}\n' \
  "$(hostname)" "$TARGET_USER" "$entries" "$snapshot_b64"

# Best-effort cleanup of the staged key file.
rm -f "${REMOTE_TMP:-/tmp}/fanout-keys.txt" 2>/dev/null || true
echo "[OK] ssh-keys-fanout: ledger collected on $(hostname) ($entries entries)"
