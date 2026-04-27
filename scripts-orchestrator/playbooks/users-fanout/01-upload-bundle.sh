#!/usr/bin/env bash
# users-fanout step 01: materialise users.json on the remote from the
# controller-supplied USERS_JSON_B64 env var. The orchestrator export
# step runs `base64 -w0 < $USERS_JSON` and ships it via ssh env.
#
# Required env: USERS_JSON_B64
# Optional env: REMOTE_TMP (default /tmp)
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
TARGET="$REMOTE_TMP/users-fanout.json"

if [ -z "${USERS_JSON_B64:-}" ]; then
  echo "[FILE-ERROR] path=USERS_JSON_B64 reason=env var empty -- controller must export the base64 bundle" >&2
  exit 2
fi
if ! mkdir -p "$REMOTE_TMP"; then
  echo "[FILE-ERROR] path=$REMOTE_TMP reason=mkdir failed on $(hostname)" >&2
  exit 2
fi
if ! printf '%s' "$USERS_JSON_B64" | base64 -d > "$TARGET" 2>/dev/null; then
  echo "[FILE-ERROR] path=$TARGET reason=base64 decode failed" >&2
  exit 2
fi
chmod 600 "$TARGET"
echo "[OK] users-fanout: bundle landed at $TARGET on $(hostname)"
