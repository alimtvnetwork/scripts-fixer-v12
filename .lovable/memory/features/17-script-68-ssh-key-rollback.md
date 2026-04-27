---
name: Script 68 ssh-key rollback via per-run manifests
description: add-user.sh / add-user-from-json.sh write a fingerprint manifest per run; remove-ssh-keys.sh strips ONLY those keys from authorized_keys
type: feature
---

# Script 68 -- ssh-key rollback (v0.172.0, counters renamed in v0.173.0)

Closes the loop on the SSH-key install pipeline. Every `add-user.sh` run
that actually appends keys writes a JSON manifest containing the
fingerprint, algorithm, source tag, and literal line of each NEW key
(net-new only -- pre-existing keys are excluded so rollback can never
touch them). `remove-ssh-keys.sh` reads that manifest and removes just
those lines.

## Storage

- Default dir: `/var/lib/68-user-mgmt/ssh-key-runs/` (mode 0700, root)
- Filename: `<run-id>__<user>.json` (mode 0600, root)
- One manifest per `(run-id, user)` tuple. A batch JSON run shares one
  `run-id` so a single rollback undoes the whole batch.

## Manifest schema (v1)

```json
{
  "manifestVersion": 1,
  "runId": "20260427-153045-ab12",
  "writtenAt": "2026-04-27T15:30:45+08:00",
  "host": "myhost",
  "user": "alice",
  "authorizedKeysFile": "/home/alice/.ssh/authorized_keys",
  "scriptVersion": "0.172.0",
  "keys": [
    {
      "fingerprint": "SHA256:abc...",
      "algo": "ssh-ed25519",
      "source": "url:https://github.com/alice.keys",
      "line": "ssh-ed25519 AAAA... alice@host"
    }
  ]
}
```

The literal line is kept as a fallback when fingerprint formats drift
between install and rollback (different `ssh-keygen` versions, exotic
algos). Match priority: fingerprint -> literal line.

## CLI

`add-user.sh` (and `add-user-from-json.sh`) gain:

| Flag                | Default                                   | Notes |
|---------------------|-------------------------------------------|-------|
| `--run-id <id>`     | auto: `YYYYmmdd-HHMMSS-<rand4>`           | batch loader prefixes `batch-` |
| `--manifest-dir D`  | `/var/lib/68-user-mgmt/ssh-key-runs`      | created 0700 root |
| `--no-manifest`     | off                                       | opt-out; rollback impossible |

`remove-ssh-keys.sh`:

```
remove-ssh-keys.sh --list                   # show all tracked runs
remove-ssh-keys.sh --run-id <id> --dry-run  # preview
remove-ssh-keys.sh --run-id <id>            # apply (root)
remove-ssh-keys.sh --manifest <path>        # roll back from arbitrary file
```

## Safety model

1. `authorized_keys` is backed up to `<file>.bak.<YYYYmmdd-HHMMSS>` BEFORE
   any edit. The log line includes the exact restore command.
2. Comments and blank lines in `authorized_keys` are preserved verbatim.
3. Keys whose fingerprint is in the manifest but NOT in the file are
   reported as "already missing" (warning, not error) -- safe to re-run.
4. After successful rollback the manifest is removed so `--list` stays
   accurate. `--keep-manifest` overrides for audit workflows.
5. Re-running rollback after manifest deletion exits `2` with
   `manifestNotFound` -- the operator gets a clear "already done" signal.

## Verified end-to-end

1. Pre-existing manually-added key survives rollback.
2. Both fingerprint-tracked keys removed cleanly.
3. Backup file created with timestamped suffix.
4. Manifest auto-deleted on success.
5. `--list` shows run-id, timestamp, user, key count, source list.
6. `--dry-run` reports identical removal plan, touches nothing.
7. Re-run after rollback returns `2 manifestNotFound` (idempotent signal).

## CODE RED compliance

Every file/path failure path logs the exact path + reason via
`log_file_error` or `manifestWriteFail` / `manifestParseFail` /
`removeWriteFail` / `removeNoAuthKeys`. No silent skips.

## v0.173.0 -- counter rename

The single ambiguous "requested vs installed" pair was split into a
5-stage pipeline so the summary tells the operator exactly what
happened at each step:

| Counter                  | Meaning |
|--------------------------|---------|
| `sources_requested`      | `--ssh-key` + `--ssh-key-file` + `--ssh-key-url` flag count (one per flag, regardless of how many keys each source carries) |
| `keys_parsed`            | Non-blank, non-comment, algo-valid key lines read from all sources -- BEFORE intra-run de-dup |
| `keys_unique`            | `keys_parsed` minus duplicates within this run |
| `keys_installed_new`     | Net-new lines actually appended to `authorized_keys` |
| `keys_preserved`         | Pre-existing lines we left untouched |

Console summary now reads e.g.
`sources=3 parsed=5 unique=2 installed_new=2 preserved=1`.

Old names removed: `UM_SSH_REQUESTED_COUNT`, `UM_SSH_INSTALLED_COUNT`.
New names: `UM_SSH_SOURCES_REQUESTED`, `UM_SSH_KEYS_PARSED`,
`UM_SSH_KEYS_UNIQUE`, `UM_SSH_KEYS_INSTALLED_NEW`,
`UM_SSH_KEYS_PRESERVED`. `sshKeyInstalled` log template now takes 6
args; `sshKeyNoneValid` wording clarified to "source(s)".