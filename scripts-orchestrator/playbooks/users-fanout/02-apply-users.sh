#!/usr/bin/env bash
# users-fanout step 02: run add-user-from-json.sh against the bundle
# uploaded in step 01.
#
# Required env: USERMGMT_DIR (path to scripts-linux/68-user-mgmt on remote)
# Optional env: REMOTE_TMP (default /tmp), DRY_RUN (1 = pass --dry-run)
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
USERMGMT_DIR="${USERMGMT_DIR:-/opt/68-user-mgmt}"
BUNDLE="$REMOTE_TMP/users-fanout.json"
HELPER="$USERMGMT_DIR/add-user-from-json.sh"

if [ ! -f "$BUNDLE" ]; then
  echo "[FILE-ERROR] path=$BUNDLE reason=bundle missing -- step 01 did not upload" >&2
  exit 2
fi
if [ ! -x "$HELPER" ] && [ ! -f "$HELPER" ]; then
  echo "[FILE-ERROR] path=$HELPER reason=add-user-from-json.sh not deployed on $(hostname). Deploy scripts-linux/68-user-mgmt to $USERMGMT_DIR first." >&2
  exit 2
fi

ARGS=("$BUNDLE")
[ "${DRY_RUN:-0}" = "1" ] && ARGS+=(--dry-run)

if bash "$HELPER" "${ARGS[@]}"; then
  echo "[OK] users-fanout: applied bundle on $(hostname)"
else
  rc=$?
  echo "[FILE-ERROR] path=$HELPER reason=add-user-from-json.sh exited rc=$rc on $(hostname)" >&2
  exit "$rc"
fi
