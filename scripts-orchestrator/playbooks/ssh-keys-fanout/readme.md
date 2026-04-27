# ssh-keys-fanout

Distribute one or more SSH public keys to a target user on every host
in a group, **idempotently** (trim/split/compare key bodies — never blind
appends, never duplicates). Records each install in
`~<TARGET_USER>/.lovable/ssh-keys-state.json` so future audits can
reconstruct who has which key where.

## Prerequisite

`scripts-linux/68-user-mgmt/` deployed to `$USERMGMT_DIR` on each remote.
The `TARGET_USER` must already exist on every host (use `users-fanout`
first if needed).

## Run

```bash
# A file with one ssh public key per line (blank + # comments OK)
cat > /tmp/team-keys.txt <<EOF
ssh-ed25519 AAAA... alice@laptop
ssh-ed25519 AAAA... bob@desktop
EOF

./run.sh playbook ssh-keys-fanout \
    --group production \
    --with-file KEYS_B64=/tmp/team-keys.txt \
    --with-env  TARGET_USER=deploy \
    --with-env  USERMGMT_DIR=/opt/68-user-mgmt
```

## Steps

| # | Script | Effect |
|---|---|---|
| 01 | `01-upload-keys.sh`     | Decodes `KEYS_B64` into `$REMOTE_TMP/fanout-keys.txt` (0600) |
| 02 | `02-install-keys.sh`    | Runs `add-user.sh <user> --ssh-key-file <bundle>` (idempotent) |
| 03 | `03-collect-ledger.sh`  | Emits `---FANOUT-SUMMARY-JSON---` + `---FANOUT-LEDGER-JSON---` (base64 ledger snapshot for central audit) |

## Central audit

Grep for `---FANOUT-LEDGER-JSON---` in your audit log; each entry is a
single-line JSON object with the host's ledger snapshot base64-encoded.
Decode + merge for a global view of who has what key where.
