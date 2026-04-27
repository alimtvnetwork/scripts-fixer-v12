# Windows — User, Group & SSH key management

Windows counterpart to `scripts-linux/68-user-mgmt/`. Same CLI surface,
same JSON shapes, same cross-OS ledger.

`scripts/os/run.ps1` is a pure dispatcher; every leaf lives under
`scripts/os/helpers/` and can be invoked directly.

## Subverbs

| Subverb            | Leaf                          | Purpose                                |
|--------------------|-------------------------------|----------------------------------------|
| `add-user`         | `add-user.ps1`                | one local user                         |
| `add-user-json`    | `add-user-from-json.ps1`      | bulk users from JSON                   |
| `edit-user`        | `edit-user.ps1`               | rename / re-comment / toggle admin     |
| `remove-user`      | `remove-user.ps1`             | delete user (optional `--purge-home`)  |
| `add-group`        | `add-group.ps1`               | one local group                        |
| `add-group-json`   | `add-group-from-json.ps1`     | bulk groups from JSON                  |
| `gen-key`          | `gen-key.ps1`                 | generate ed25519 / rsa / ecdsa keypair |
| `install-key`      | `install-key.ps1`             | append public key to `authorized_keys` |
| `revoke-key`       | `revoke-key.ps1`              | remove by fingerprint / comment / body |

All leaves accept `--ask` (interactive prompts for missing fields) and
`--dry-run` (no host mutation, full log trail).

## CLI examples

```powershell
# create a user, prompt for password
pwsh scripts/os/run.ps1 add-user --name alice --ask

# bulk-load
pwsh scripts/os/run.ps1 add-user-json --file scripts/os/helpers/examples/users.json

# generate then install a key
pwsh scripts/os/run.ps1 gen-key --type ed25519 --comment "alice@laptop"
pwsh scripts/os/run.ps1 install-key --user alice --key-file C:\keys\alice.pub

# remove all of bob's keys
pwsh scripts/os/run.ps1 revoke-key --user bob --all
```

## Idempotency contract — `install-key`

1. Load `%USERPROFILE%\.ssh\authorized_keys` (create with `0600`-equiv
   ACL if missing — only the user + SYSTEM + Administrators get access
   via `icacls`).
2. For each existing line: trim, skip empties / comments, **split on
   whitespace, take column 2 = key body**.
3. Compare incoming key body. If already present, log `skip` and exit 0.
4. Otherwise append the full original line (algo + body + comment),
   re-harden ACL, log `installed` with SHA-256 fingerprint.

The Linux helper applies the same algorithm, so a key installed on one
OS will be skipped if the file is later sync'd to the other OS.

## Cross-OS ledger

`%USERPROFILE%\.lovable\ssh-keys-state.json` (Windows) and
`~/.lovable/ssh-keys-state.json` (Linux/macOS) share one schema:

```json
{
  "version": 1,
  "entries": [
    {
      "fingerprint": "SHA256:abcd...",
      "type":        "ssh-ed25519",
      "comment":     "alice@laptop",
      "user":        "alice",
      "host":        "DESKTOP-AB12",
      "os":          "windows",
      "action":      "install",
      "ts":          "2026-04-27T10:32:11Z",
      "keyPath":     "C:\\Users\\alice\\.ssh\\authorized_keys"
    }
  ]
}
```

Writes are atomic: the helper writes `…state.json.tmp`, then
`Move-Item -Force`. Concurrent writers from a fan-out are serialised by
a sibling `…state.json.lock` mutex with 30 s timeout.

## CODE RED file/path errors

Every file/path failure goes through `Write-FileError` and includes the
exact path + reason:

```
FILE-ERROR path='C:\nope\users.json' reason='JSON input not found'
FILE-ERROR path='C:\keys\alice.pub' reason='public key file unreadable'
```

## Animated demos

Tape sources at `scripts/os/tests/vhs/`. Render locally with `vhs`.