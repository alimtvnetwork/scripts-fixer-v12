---
name: 68-user-mgmt cross-OS user/group management
description: Script 68 layout, subverbs, JSON shape rules, password policy, OS dispatch (Linux useradd vs macOS dscl), and exit-code contract
type: feature
---
## scripts-linux/68-user-mgmt/

Cross-OS counterpart to Windows `os add-user`. Pure bash. No deps beyond
coreutils + the OS-native user-management tools (and `jq` for the JSON
leaves).

### Layout (root + 4 leaves, no monolith)
```
run.sh                       # pass-through dispatcher
add-user.sh                  # one user (CLI)
add-group.sh                 # one group (CLI)
add-user-from-json.sh        # bulk users (JSON)
add-group-from-json.sh       # bulk groups (JSON)
helpers/_common.sh           # OS detect + password resolver + idempotent probes
config.json + log-messages.json
examples/{user-single,users,users-wrapped,groups}.json
tests/01-smoke.sh
```

### Subverb -> leaf mapping
| run.sh subverb   | leaf                       |
|------------------|----------------------------|
| `add-user`       | `add-user.sh`              |
| `add-group`      | `add-group.sh`             |
| `add-user-json`  | `add-user-from-json.sh`    |
| `add-group-json` | `add-group-from-json.sh`   |
| `edit-user`      | `edit-user.sh`             |
| `remove-user`    | `remove-user.sh`           |

Aliases: `add-users-json` / `user-json`, `add-groups-json` / `group-json`.
`edit-user` aliases: `modify-user`, `edituser`.
`remove-user` aliases: `delete-user`, `deluser`, `removeuser`.

### JSON shapes (all auto-detected by both JSON leaves)
1. Single object:  `{ "name": "alice", ... }`
2. Array:          `[ { ... }, { ... } ]`
3. Wrapped:        `{ "users": [ ... ] }` or `{ "groups": [ ... ] }`

Detection happens via one `jq` expression that normalises any of the three
into an array on stdout. Anything else -> exit 2 with `jsonShapeUnknown`.

### Password policy (mirrors Windows decision)
Three sources, priority: `--password-file` > `UM_PASSWORD` env (set by JSON
loader from `password` field) > `--password` CLI. Empty -> account locked.
`--password-file` mode check: must be `0400`/`0600`, otherwise exit 2 with
the exact path + observed mode in the failure message. Plain password
accepted to mirror the Windows risk decision; never logged; console echo
masked via `um_mask_password` (`*` x min(len, 8)).

### OS dispatch
| Concern         | Linux                     | macOS                          |
|-----------------|---------------------------|--------------------------------|
| Detect          | `uname -s` -> `Linux`     | `uname -s` -> `Darwin`         |
| Create user     | `useradd --create-home`   | `dscl . -create /Users/<n>`    |
| Set password    | `chpasswd`                | `dscl . -passwd /Users/<n>`    |
| Add to group    | `usermod -aG`             | `dscl . -append /Groups/<g>`   |
| Default shell   | `/bin/bash`               | `/bin/zsh`                     |
| Default home    | `/home/<n>`               | `/Users/<n>`                   |
| Sudo group      | `sudo`                    | `admin`                        |
| UID/GID alloc   | tool-managed              | manual: next free >= 510       |

### Exit codes (contract — do NOT change without updating readme)
| Exit | Meaning                                                       |
|------|---------------------------------------------------------------|
| 0    | success (incl. idempotent "already existed -- skipped")       |
| 1    | underlying tool returned non-zero                             |
| 2    | input error (missing file, bad JSON, bad password-file mode)  |
| 13   | not root and not `--dry-run`                                  |
| 64   | bad CLI usage                                                 |
| 127  | required tool missing (`jq` for JSON leaves)                  |

### Idempotency
`um_user_exists` / `um_group_exists` probe via `id`/`getent group` (Linux)
or `dscl . -read` (macOS). Re-running on an existing user only adjusts
supplementary group membership + password; create is skipped with a warn.

### Smoke test
`bash scripts-linux/68-user-mgmt/tests/01-smoke.sh` -- runs in dry-run
only, needs no root, never mutates the host. Verifies dispatcher routing,
CLI parsing, all 3 JSON shapes, and the CODE RED missing-file error path.
9/9 PASS as of v0.127.0.