#!/usr/bin/env bash
# ssh-keys-fanout step 02: install keys idempotently into TARGET_USER's
# authorized_keys via scripts-linux/68-user-mgmt/add-user.sh's --ssh-key-file
# pathway (which already does trim/split/compare + ledger writes).
#
# When the user already exists, we use install-key semantics by re-running
# add-user.sh with --ssh-key-file (it skips create + only appends new keys).
set -e
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
USERMGMT_DIR="${USERMGMT_DIR:-/opt/68-user-mgmt}"
KEYS="$REMOTE_TMP/fanout-keys.txt"
HELPER="$USERMGMT_DIR/add-user.sh"
TARGET_USER="${TARGET_USER:-$(id -un)}"

if [ ! -f "$KEYS" ]; then
  echo "[FILE-ERROR] path=$KEYS reason=key bundle missing -- step 01 did not upload" >&2; exit 2
fi
if [ ! -f "$HELPER" ]; then
  echo "[FILE-ERROR] path=$HELPER reason=add-user.sh not deployed on $(hostname). Deploy scripts-linux/68-user-mgmt to $USERMGMT_DIR first." >&2
  exit 2
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "[FILE-ERROR] path=user:$TARGET_USER reason=local user does not exist on $(hostname); create it first via users-fanout playbook" >&2
  exit 2
fi

ARGS=("$TARGET_USER" --ssh-key-file "$KEYS")
[ "${DRY_RUN:-0}" = "1" ] && ARGS+=(--dry-run)

if bash "$HELPER" "${ARGS[@]}"; then
  echo "[OK] ssh-keys-fanout: installed keys for '$TARGET_USER' on $(hostname)"
else
  rc=$?
  echo "[FILE-ERROR] path=$HELPER reason=add-user.sh exited rc=$rc on $(hostname)" >&2
  exit "$rc"
fi
