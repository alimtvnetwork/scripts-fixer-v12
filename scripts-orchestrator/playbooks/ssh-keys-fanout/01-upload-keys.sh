#!/usr/bin/env bash
# ssh-keys-fanout step 01: materialise the public-key bundle on the remote.
# Required env: KEYS_B64
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
TARGET="$REMOTE_TMP/fanout-keys.txt"
if [ -z "${KEYS_B64:-}" ]; then
  echo "[FILE-ERROR] path=KEYS_B64 reason=env var empty -- controller must export the base64 key bundle" >&2; exit 2
fi
if ! mkdir -p "$REMOTE_TMP"; then
  echo "[FILE-ERROR] path=$REMOTE_TMP reason=mkdir failed on $(hostname)" >&2; exit 2
fi
if ! printf '%s' "$KEYS_B64" | base64 -d > "$TARGET" 2>/dev/null; then
  echo "[FILE-ERROR] path=$TARGET reason=base64 decode failed" >&2; exit 2
fi
chmod 600 "$TARGET"
keycount=$(grep -cE '^(ssh-|ecdsa-)' "$TARGET" 2>/dev/null || echo 0)
echo "[OK] ssh-keys-fanout: $keycount key(s) landed at $TARGET on $(hostname)"
