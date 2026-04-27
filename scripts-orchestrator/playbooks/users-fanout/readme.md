# users-fanout

Apply a single `users.json` bundle across every host in a target group.
Idempotent on the remote (delegates to `add-user-from-json.sh`).

## Prerequisite (on every remote)

Deploy `scripts-linux/68-user-mgmt/` to `/opt/68-user-mgmt` (or set
`USERMGMT_DIR` to wherever it lives). `jq` must also be installed.

## Run

```bash
cd scripts-orchestrator
./run.sh playbook users-fanout \
    --group production \
    --with-file USERS_JSON_B64=/path/to/users.json \
    --with-env  USERMGMT_DIR=/opt/68-user-mgmt \
    --with-env  REMOTE_TMP=/tmp \
    --with-env  DRY_RUN=0
```

## Steps

| # | Script | Effect |
|---|---|---|
| 01 | `01-upload-bundle.sh` | Decodes `USERS_JSON_B64` into `$REMOTE_TMP/users-fanout.json` (mode 0600) |
| 02 | `02-apply-users.sh`   | Runs `add-user-from-json.sh <bundle>` (forwards `--dry-run`) |
| 03 | `03-collect-summary.sh` | Emits `---FANOUT-SUMMARY-JSON--- {...}` for the audit log + cleans up |

Per-host failures log a `[FILE-ERROR] path=... reason=...` line and propagate
the original rc so the orchestrator's audit log captures it.
