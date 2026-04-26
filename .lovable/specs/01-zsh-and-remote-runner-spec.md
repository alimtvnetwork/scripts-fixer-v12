# Spec 01 -- ZSH stack + Multi-machine Remote Runner

Date: 2026-04-26 17:30 (UTC+8)
Status: **Draft -- awaiting approval before implementation**
Source repo: https://github.com/aukgit/kubernetes-training-v1
Target tree: scripts-linux/

---

## 1. Goal

Port two capability groups from the user's older Kubernetes-training repo into the cross-platform `scripts-linux/` library, generalised so they are useful outside a Kubernetes context:

1. **ZSH stack** -- install Oh-My-Zsh, deploy curated `.zshrc`, switch themes interactively (with non-interactive flag fallback), and a clean reset verb.
2. **Multi-machine remote runner** -- log into N Linux machines over SSH using passwords (sshpass) and execute one shell command across `all`, a named `group:`, or a single `host:`. Generalises the k8s-locked `kubernetes/07-remote-commands/run-cmd.sh`.

---

## 2. User decisions (locked)

| Q | Decision |
|---|----------|
| ZSH numbering | **60-series** -- 60-install-zsh, 61-install-zsh-theme-switcher, 62-install-zsh-clear |
| Theme UX | **Interactive by default + flag-driven** (`--theme agnoster --no-prompt`) |
| Remote runner targets | **Generic** -- `all` / `group:<name>` / `host:<name>` over `config.json hosts[]` |
| Credentials | **Password by default** + warning + auto `.gitignore` + `chmod 600` enforcement; optional `keyFile` per host |

---

## 3. Source files to import

### 3.1 ZSH stack -- from `02-ubuntu-install/`

| Source file | Size | Imports as | Purpose |
|---|---:|---|---|
| `.zshrc` | 3.3 KB | `60-install-zsh/payload/zshrc` | User-facing zshrc |
| `.zshrc-base` | 7.1 KB | `60-install-zsh/payload/zshrc-base` | Base fragment sourced from zshrc |
| `05-omy-zsh-only.sh` | 3.4 KB | reference for `60-install-zsh/run.sh` | OMZ installer |
| `01-zsh-theme-change-v2.sh` | 7.4 KB | reference for `61-install-zsh-theme-switcher/run.sh` | Theme picker |
| `11-clear-ohmyzsh.sh` | 1.2 KB | reference for `62-install-zsh-clear/run.sh` | Reset/uninstall |

**Skipped (k8s/user-mgmt -- out of scope):** `00-set-ip.sh`, `00-base-packages-install.sh`, `02-create-root-user.sh`, `04-kill-user-processes.sh`, `06-remove-users.sh`, `07-auto-purge.sh`, `08-create-root-user-nozsh.sh`, `09-create-root-user-v2.sh`, `09-repo-permissions.sh`, `10-git-pull.sh`, `authorized_keys`, `.ssh/`.

### 3.2 Remote runner -- from `05-server-cmds/` and `06-Sessions/`

| Source file | Size | Imports as | Purpose |
|---|---:|---|---|
| `02-run-cmd-v2.sh` | 5.3 KB | reference for `63-remote-runner/run.sh` | Multi-host SSH executor |
| `01-config-sample.json` | 247 B | reference for `63-remote-runner/config-sample.json` | Hosts/credentials template |
| `06-Sessions/` (empty) | -- | `63-remote-runner/.sessions/` | Per-run output directory |

### 3.3 Base helpers worth promoting -- from `01-base-shell-scripts/`

| Source file | Imports into `_shared/` | Notes |
|---|---|---|
| `03-aria2c-download.sh` | `_shared/aria2c-download.sh` | Parallel downloader (future use) |
| `04-is-package-installed.sh` | merge into `_shared/install-apt.sh` | Idempotency helper |
| `05-combine_path.sh` | `_shared/combine-path.sh` | PATH dedupe helper |

**Skipped:** `00-import-all.sh`, `01-logger.sh`, `02-install-apt.sh`, `06-control-node-ip.sh` -- already covered by current `scripts-linux/_shared/`.

---

## 4. Target file layout

```
scripts-linux/
|-- _shared/
|   |-- aria2c-download.sh         (NEW)
|   `-- combine-path.sh            (NEW)
|
|-- 60-install-zsh/
|   |-- run.sh                     check|install|uninstall|repair
|   |-- config.json                { default_theme, plugins[], install_omz: true }
|   |-- log-messages.json
|   |-- readme.txt
|   `-- payload/
|       |-- zshrc                  (verbatim port of .zshrc)
|       `-- zshrc-base             (verbatim port of .zshrc-base)
|
|-- 61-install-zsh-theme-switcher/
|   |-- run.sh                     check|install|switch|list|uninstall
|   |                              flags: --theme <name> --no-prompt
|   |-- config.json                { themes[], default_theme, custom_themes[] }
|   |-- log-messages.json
|   `-- readme.txt
|
|-- 62-install-zsh-clear/
|   |-- run.sh                     check|install (=perform reset)|uninstall (no-op)
|   |-- config.json                { backup_before_clear, restore_shell }
|   |-- log-messages.json
|   `-- readme.txt
|
`-- 63-remote-runner/
    |-- run.sh                     check|install (=verify deps)|exec
    |                              positional: <target> "<command>"
    |                              targets: all | group:<name> | host:<name>
    |                              flags: --parallel N --timeout S --dry-run
    |-- config-sample.json         template (committed)
    |-- config.json                user copy (gitignored, chmod 600)
    |-- log-messages.json
    |-- readme.txt
    `-- .sessions/                 per-run logs
```

---

## 5. config.json schemas

### 5.1 `60-install-zsh/config.json`
```json
{
  "install_omz": true,
  "default_theme": "agnoster",
  "plugins": ["git", "z", "sudo", "history", "command-not-found"],
  "deploy_zshrc": true,
  "backup_existing_zshrc": true
}
```

### 5.2 `61-install-zsh-theme-switcher/config.json`
```json
{
  "default_theme": "agnoster",
  "themes": ["agnoster","robbyrussell","powerlevel10k/powerlevel10k","bira","avit","candy","fishy","gnzh"],
  "custom_themes": [],
  "interactive_by_default": true
}
```

### 5.3 `62-install-zsh-clear/config.json`
```json
{
  "backup_before_clear": true,
  "restore_shell": "/bin/bash",
  "remove_zshrc": false,
  "remove_oh_my_zsh_dir": true
}
```

### 5.4 `63-remote-runner/config-sample.json`
```json
{
  "defaults": {
    "user": "ubuntu",
    "password": "CHANGE_ME",
    "port": 22,
    "timeout_seconds": 30
  },
  "groups": {
    "web": ["web-1","web-2"],
    "db":  ["db-1"],
    "k8s": ["control","worker-1","worker-2"]
  },
  "hosts": [
    { "name": "web-1",    "ip": "192.168.1.10", "user": "ubuntu" },
    { "name": "web-2",    "ip": "192.168.1.11" },
    { "name": "db-1",     "ip": "192.168.1.20", "user": "postgres", "password": "..." },
    { "name": "control",  "ip": "192.168.1.30", "keyFile": "~/.ssh/id_ed25519" },
    { "name": "worker-1", "ip": "192.168.1.31" },
    { "name": "worker-2", "ip": "192.168.1.32" }
  ]
}
```

Resolution: per-host `user/password/port/keyFile` overrides `defaults.*`. `keyFile` (if set) wins over password.

---

## 6. Behaviour contracts

### 6.1 60-install-zsh
- **check**: zsh installed AND `~/.oh-my-zsh/` exists AND `~/.zshrc` exists
- **install**:
  1. `apt install zsh git curl` (idempotent)
  2. Run OMZ installer non-interactively (`RUNZSH=no CHSH=no`)
  3. Backup existing `~/.zshrc` -> `~/.zshrc.backup-<TS>`
  4. Deploy `payload/zshrc` and `payload/zshrc-base`
  5. Set theme from `config.default_theme`
  6. `chsh -s "$(command -v zsh)"` (skip if non-interactive)
  7. Write `.installed/60.ok`
- **uninstall**: defer to `62-install-zsh-clear`
- **repair**: re-deploy zshrc files only

### 6.2 61-install-zsh-theme-switcher
- **check**: `~/.zshrc` exists AND has `ZSH_THEME=` line
- **install**: ensure OMZ present (soft-skip otherwise)
- **list**: print themes
- **switch**: interactive menu (default) OR `--theme <name> --no-prompt`. Validates theme exists in `~/.oh-my-zsh/themes/` or `custom_themes[]`. Edits `ZSH_THEME="..."` in `~/.zshrc`.

### 6.3 62-install-zsh-clear
- **install** (destructive verb):
  1. Backup `~/.zshrc` and `~/.oh-my-zsh/` -> `~/.zsh-backup-<TS>/`
  2. Run upstream `uninstall_oh_my_zsh` if present
  3. Remove `~/.oh-my-zsh/`
  4. `chsh -s <restore_shell>`
  5. Clear `.installed/60.ok` and `.installed/61.ok`

### 6.4 63-remote-runner
- **check**: `sshpass`, `jq`, `ssh` present + `config.json` is mode 600
- **install**: `apt install sshpass jq` + create `config.json` from sample if missing + `chmod 600` + add to `.gitignore`
- **exec** `<target> "<command>"`:
  - `all` -> every entry in `hosts[]`
  - `group:web` -> `groups.web[]`
  - `host:web-1` -> single host
  - Per host: resolve effective user/password/port/keyFile
  - SSH key takes precedence over password
  - Stream output prefixed with `[<host>]`
  - `--parallel N` -> `xargs -P N` (matches 12-orchestrator)
  - `--dry-run` -> print plan, exit 0
  - On finish: write `.sessions/<TS>-<target>.json` (per-host status, exit, duration) + `.log` (full output, passwords redacted)

---

## 7. Security hardening

- `check` refuses to proceed if:
  - `config.json` mode != `0600`
  - `config.json` is tracked by git
- `install` auto-appends to `scripts-linux/.gitignore`:
  ```
  63-remote-runner/config.json
  63-remote-runner/.sessions/
  ```
- First-run yellow banner: "config.json contains plain-text passwords. chmod 600 + .gitignore applied. Prefer per-host keyFile for production."
- Session logs redact passwords (replaced with `***`).

---

## 8. Registry additions (`scripts-linux/registry.json`)

```json
{ "id": "60", "folder": "60-install-zsh",                "phase": "10", "title": "ZSH + Oh-My-Zsh (apt|curl)" },
{ "id": "61", "folder": "61-install-zsh-theme-switcher", "phase": "10", "title": "ZSH theme switcher (interactive|flag)" },
{ "id": "62", "folder": "62-install-zsh-clear",          "phase": "10", "title": "ZSH reset/uninstall" },
{ "id": "63", "folder": "63-remote-runner",              "phase": "10", "title": "Remote runner (sshpass, multi-host)" }
```

Version bump: `0.114.0` -> `0.115.0` (minor).

---

## 9. Profile additions (`12-install-all-dev-tools/profiles.json`)

- `shell` (NEW): `[60, 61]`
- `fullstack` (existing): append `60`
- `ops` (NEW): `[45, 46, 63]` (Docker + k8s + remote runner)
- `all` (existing wildcard): auto-includes 60-63 via registry expansion

---

## 10. Memory updates

After implementation, add:
- `features/zsh-stack.md` -- describes 60/61/62 trio, payload pattern
- `features/remote-runner.md` -- describes 63 host/group/all targets + credential model
- Update `index.md` Memories section with two new references

CODE RED rule already applies: every SSH failure in 63 logs host name, IP, and reason.

---

## 11. Out of scope

- macOS port (Phase 13 -- separate spec)
- User provisioning scripts (`02-create-root-user.sh` etc.) -- follow-up if requested
- Kubernetes networking helpers -- already in `kubernetes/` tree
- Replacing `kubernetes/07-remote-commands/run-cmd.sh` -- additive only

---

## 12. Implementation plan (4 stages)

| Stage | Deliverable | Files |
|---|---|---|
| **S1** | Cache verbatim source files in `scripts-linux/.imports-cache/` | 5 files |
| **S2** | Build `60-install-zsh` (with payload) + `62-install-zsh-clear` | 2 folders |
| **S3** | Build `61-install-zsh-theme-switcher` | 1 folder |
| **S4** | Build `63-remote-runner` + registry/profiles/dispatcher/version updates | 1 folder + 4 edits |

After S4: run `scripts-linux/run.sh health` + write 2 memory files.

---

## 13. Open items

None -- all 4 user decisions captured in section 2. Ready on user's `go`.
