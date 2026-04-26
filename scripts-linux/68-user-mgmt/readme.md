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

The JSON loaders accept three shapes:

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
wrapped), and the CODE RED missing-file error path.