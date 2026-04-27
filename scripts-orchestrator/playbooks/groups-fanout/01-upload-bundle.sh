#!/usr/bin/env bash
# groups-fanout step 01: materialise groups.json on the remote.
# Required env: GROUPS_JSON_B64
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
TARGET="$REMOTE_TMP/groups-fanout.json"
if [ -z "${GROUPS_JSON_B64:-}" ]; then
  echo "[FILE-ERROR] path=GROUPS_JSON_B64 reason=env var empty -- controller must export the base64 bundle" >&2
  exit 2
fi
if ! mkdir -p "$REMOTE_TMP"; then
  echo "[FILE-ERROR] path=$REMOTE_TMP reason=mkdir failed on $(hostname)" >&2; exit 2
fi
if ! printf '%s' "$GROUPS_JSON_B64" | base64 -d > "$TARGET" 2>/dev/null; then
  echo "[FILE-ERROR] path=$TARGET reason=base64 decode failed" >&2; exit 2
fi
chmod 600 "$TARGET"
echo "[OK] groups-fanout: bundle landed at $TARGET on $(hostname)"
