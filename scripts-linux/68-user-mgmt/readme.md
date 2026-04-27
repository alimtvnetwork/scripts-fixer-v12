# 68 — User & Group Management (cross-OS)

Linux + macOS counterpart to the Windows `os add-user` subcommand.
Creates local users and groups idempotently from either:

* direct CLI arguments, or
* a JSON file (single object **or** array — auto-detected).

The root `run.sh` is a **pure pass-through dispatcher** — it just routes
the subverb to the matching leaf script. You can call the leaves directly
if you prefer to bypass the dispatcher.

## Layout

```
68-user-mgmt/
├── run.sh                       # dispatcher (subverb -> leaf)
├── add-user.sh                  # leaf: one user
├── add-group.sh                 # leaf: one group
├── add-user-from-json.sh        # leaf: bulk users from JSON
├── add-group-from-json.sh       # leaf: bulk groups from JSON
├── config.json                  # OS defaults (shell, home base, sudo group)
├── log-messages.json            # message catalogue
├── helpers/_common.sh           # OS detect, password resolver, idempotent probes
├── examples/                    # ready-to-edit JSON samples
└── tests/01-smoke.sh            # dry-run smoke test (no root needed)
```

## Subverbs

| Subverb           | Leaf                          | Purpose                              |
|-------------------|-------------------------------|--------------------------------------|
| `add-user`        | `add-user.sh`                 | one user                             |
| `add-group`       | `add-group.sh`                | one group                            |
| `add-user-json`   | `add-user-from-json.sh`       | bulk users from JSON                 |
| `add-group-json`  | `add-group-from-json.sh`      | bulk groups from JSON                |
| `edit-user`       | `edit-user.sh`                | modify one user (rename/promote/...) |
| `edit-user-json`  | `edit-user-from-json.sh`      | bulk user edits from JSON            |
| `remove-user`     | `remove-user.sh`              | delete one user                      |
| `remove-user-json`| `remove-user-from-json.sh`    | bulk user removal from JSON          |

## CLI examples

```bash
# Single user, plain password (mirrors Windows 'os add-user' risk model)
sudo bash run.sh add-user alice --password 'P@ssw0rd!' --groups sudo,docker

# Single user, password from a 0600 file (preferred)
sudo bash run.sh add-user bob --password-file /etc/secrets/bob.pw \
      --primary-group devs --shell /bin/zsh --comment "Bob the Builder"

# Single group
sudo bash run.sh add-group devs --gid 2000

# Dry-run (no root needed; prints what WOULD happen)
bash run.sh add-user carol --password 'x' --sudo --dry-run
```

## JSON examples

The JSON loaders accept three shapes (auto-detected by the leaf scripts):

1. **Single object**
   ```json
   { "name": "dan", "password": "Welcome1!", "groups": ["sudo"] }
   ```
2. **Array**
   ```json
   [
     { "name": "alice", "password": "...", "groups": ["sudo"] },
     { "name": "bob",   "passwordFile": "/etc/secrets/bob.pw" }
   ]
   ```
3. **Wrapped**
   ```json
   { "users":  [ { "name": "carol", "password": "..." } ] }
   { "groups": [ { "name": "devs", "gid": 2000 } ] }
   ```

Run a batch:

```bash
sudo bash run.sh add-user-json  examples/users.json
sudo bash run.sh add-group-json examples/groups.json --dry-run
```

### Bulk edit / remove (added in 0.198.0)

`edit-user-from-json.sh` and `remove-user-from-json.sh` mirror the
add-from-json shapes (single object, array, wrapped `{ "users": [...] }`)
and re-use the same dispatcher routes (`edit-user-json`, `remove-user-json`).
`remove-user-from-json.sh` also accepts a **bare-string list** as a
convenience: `[ "alice", "bob" ]` is treated as `[ {name:"alice"}, {name:"bob"} ]`.

Per-record schemas:

```json
// edit-users.json -- every field optional except "name"
[
  { "name": "alice", "rename": "alyssa", "comment": "Alyssa P. Hacker" },
  { "name": "bob",   "promote": true, "addGroups": ["docker","dev"], "shell": "/bin/zsh" },
  { "name": "carol", "demote": true,  "removeGroups": ["video"] },
  { "name": "dave",  "passwordFile": "/etc/secrets/dave.pw", "disable": true }
]
```

```json
// remove-users.json -- every field optional except "name"
[
  { "name": "olduser1", "purgeHome": true },
  { "name": "olduser2" },
  { "name": "olduser3", "purgeHome": true, "removeMailSpool": true }
]
```

```bash
sudo bash run.sh edit-user-json   examples/edit-users.json   --dry-run
sudo bash run.sh remove-user-json examples/remove-users.json --dry-run
```

`remove-user-json` always passes `--yes` to its children (no per-record
confirmation prompts in bulk mode). Removing a missing user is treated
as success, so re-running the same JSON is idempotent. `edit-user-json`
rejects mutually-exclusive intents up front (e.g. `promote: true` with
`demote: true`) so a half-applied batch is impossible.

The orchestrator (`useradm-bootstrap`) also accepts a fourth shape, the
**unified `--spec`** file:

```json
{
  "groups": [ { "name": "devs", "gid": 2000 } ],
  "users":  [ { "name": "alice", "password": "...", "primaryGroup": "devs" } ]
}
```

Run it via the bootstrap shortcut (groups are always created before users
so `primaryGroup` / `groups` references resolve):

```bash
sudo bash ../run.sh useradm-bootstrap --spec examples/full-bootstrap.json --dry-run
```

### Bundled example files

| File                              | Shape                          | Used by                                |
|-----------------------------------|--------------------------------|----------------------------------------|
| `examples/group-single.json`      | single object (group)          | `add-group-json`                       |
| `examples/groups.json`            | array of groups                | `add-group-json`                       |
| `examples/groups-wrapped.json`    | wrapped `{ "groups": [...] }`  | `add-group-json`                       |
| `examples/user-single.json`       | single object (user)           | `add-user-json`                        |
| `examples/users.json`             | array of users (mixed keys)    | `add-user-json`                        |
| `examples/users-wrapped.json`     | wrapped `{ "users": [...] }`   | `add-user-json`                        |
| `examples/users-with-keyfiles.json` | array, exercises `sshKeyFiles` + mixed `sshKeys` | `add-user-json` |
| `examples/full-bootstrap.json`    | unified `{ "groups": [...], "users": [...] }` | `useradm-bootstrap --spec` |

### User record fields

| Field          | Type      | Notes                                                              |
|----------------|-----------|--------------------------------------------------------------------|
| `name`         | string    | **required**                                                       |
| `password`     | string    | plain text (never logged; masked in console)                       |
| `passwordFile` | string    | path to a 0600/0400 file containing the password (preferred)       |
| `uid`          | number    | explicit UID (auto-allocated on macOS if omitted)                  |
| `primaryGroup` | string    | primary group; created if missing on Linux                         |
| `groups`       | string[]  | supplementary groups                                               |
| `shell`        | string    | login shell (default: `/bin/bash` Linux, `/bin/zsh` macOS)         |
| `home`         | string    | home dir (default: `/home/<name>` or `/Users/<name>`)              |
| `comment`      | string    | GECOS / RealName                                                   |
| `sudo`         | bool      | also add to `sudo` (Linux) or `admin` (macOS)                      |
| `system`       | bool      | system account (Linux only; ignored on macOS)                      |
| `sshKeys`      | string[]  | inline OpenSSH public keys to install in `~/.ssh/authorized_keys`  |
| `sshKeyFiles`  | string[]  | host paths to `.pub` files (one or many keys per file; comments ok)|

SSH-key install behaviour:
- Dir/file perms enforced: `~/.ssh` → `0700`, `authorized_keys` → `0600`,
  both `chown`'d to the new user + their primary group.
- Existing `authorized_keys` content is preserved; new keys are appended
  and the merged file is de-duplicated.
- Each key is sanity-checked for an OpenSSH algo prefix (`ssh-rsa`,
  `ssh-ed25519`, `ecdsa-sha2-*`, `sk-*`, `ssh-dss`); malformed lines are
  warn-logged and skipped.
- **Key bodies are never written to logs** — only a SHA-256 fingerprint
  per installed key.
- Both fields can be combined; both flags (`--ssh-key`, `--ssh-key-file`)
  are repeatable on the CLI.

### Group record fields

| Field    | Type   | Notes                                            |
|----------|--------|--------------------------------------------------|
| `name`   | string | **required**                                     |
| `gid`    | number | explicit GID (auto-allocated on macOS if omitted)|
| `system` | bool   | system group (Linux only; ignored on macOS)      |

## OS-specific behaviour

| Concern               | Linux                        | macOS                                    |
|-----------------------|------------------------------|------------------------------------------|
| Tooling               | `useradd`, `groupadd`, `chpasswd`, `usermod` | `dscl .`, `dscl . -passwd`               |
| Default shell         | `/bin/bash`                  | `/bin/zsh`                               |
| Default home base     | `/home`                      | `/Users`                                 |
| Default user group    | per-user (matches name)      | `staff`                                  |
| Sudo group            | `sudo`                       | `admin`                                  |
| Numeric ID allocation | `useradd`/`groupadd` choose  | manual: next free ≥ 510 (probed via dscl)|
| Home dir creation     | `useradd --create-home`      | manual `mkdir -p` + `chown`              |

## Security notes

* Plain `--password` and `"password"` JSON fields are accepted to mirror
  the Windows `os add-user` decision. Passwords appear in shell history
  / process listings — **prefer `--password-file` (mode `0600`) for any
  account you care about.**
* Passwords are **never** written to log files. Only the masked form
  (`*` × min(len, 8)) is echoed to the console.
* Mode check on `--password-file` rejects anything looser than `0600`
  with the exact path + observed mode in the failure message.
* All operations require `root` (the Windows side requires Admin).
  `--dry-run` is the only mode that runs without root.

## Idempotency & exit codes

| Exit | Meaning                                                          |
|------|------------------------------------------------------------------|
| 0    | success (including "user/group already existed — skipped")       |
| 1    | underlying tool (useradd/dscl/chpasswd/groupadd) returned non-0  |
| 2    | input error (missing file, bad JSON, bad password-file mode)     |
| 13   | not root and not `--dry-run`                                     |
| 64   | bad CLI usage                                                    |
| 127  | required tool missing (e.g. `jq` not installed for JSON loader)  |

## CODE RED file/path errors

Every file/path failure is logged via `log_file_error` with the **exact
path** plus a **failure reason**. Examples:

```
FILE-ERROR path='/nonexistent/users.json' reason='JSON input not found'
FILE-ERROR path='/etc/secrets/bob.pw' reason='password file not found'
```

## Smoke test

```bash
bash scripts-linux/68-user-mgmt/tests/01-smoke.sh
```

Runs in dry-run mode — needs no root, never mutates the host. Verifies
dispatcher routing, CLI parsing, JSON shape auto-detect (object / array /

## SSH key lifecycle (added in 0.192.0)

Three new leaves give per-host SSH key control. All three update the
cross-OS ledger at `~/.lovable/ssh-keys-state.json` so the same key state
can be inspected from Windows or Linux.

| Subverb        | Leaf            | Purpose                                              |
|----------------|-----------------|------------------------------------------------------|
| `gen-key`      | `gen-key.sh`    | generate ed25519 / rsa / ecdsa key pair (`--ask` ok) |
| `install-key`  | (inline)        | append a public key to a user's `authorized_keys`    |
| `revoke-key`   | `remove-ssh-keys.sh` | remove keys by `--fingerprint`, `--comment`, `--key`, or `--all` |

**Idempotency contract** — `install-key` reads the target
`authorized_keys`, splits each line on whitespace, compares **only the
key body** (column 2) against the incoming key body, and appends only
when no match exists. Comments and options are ignored for the
comparison. Re-running with the same key is a no-op.

## Multi-host fan-out (added in 0.193.0)

Playbooks under `scripts-orchestrator/playbooks/` apply this module
across N hosts in parallel via `lib/04-parallel.sh`:

| Playbook                 | What it fans out                                       |
|--------------------------|--------------------------------------------------------|
| `users-fanout`           | a `users.json` bundle to every host                    |
| `groups-fanout`          | a `groups.json` bundle to every host                   |
| `ssh-keys-fanout`        | a key bundle (ed25519 `.pub` files)                    |

Each playbook emits a `---FANOUT-RESULT-JSON---` audit line per host and
a `---FANOUT-SUMMARY-JSON---` roll-up at the end (host counts, pass /
fail / skipped, total wall-time). Pass `--with-env KEY=VAL` and
`--with-file LOCAL:REMOTE` to thread secrets and bundles through.

## Animated demos (vhs)

Tape sources live in `tests/vhs/`. Render with
[charmbracelet/vhs](https://github.com/charmbracelet/vhs):

```bash
vhs scripts-linux/68-user-mgmt/tests/vhs/add-user-ask.tape
vhs scripts-linux/68-user-mgmt/tests/vhs/install-key-idempotent.tape
```

GIFs are written next to the `.tape` files. They are **not** committed
to git — render on demand.

wrapped), and the CODE RED missing-file error path.