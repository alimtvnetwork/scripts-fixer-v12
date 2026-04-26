# Cleanup Overview — what gets installed, what gets removed

> **Audience.** Operators running this toolkit on Windows, macOS, and/or
> Linux who want a single page that tells them, per OS:
> 1. Which scripts touch the system (and where),
> 2. Which scripts undo those changes (and exactly what they remove),
> 3. The exact path/registry-key allow-list each cleanup uses,
> 4. The safety nets (dry-run, plan-then-confirm, post-cleanup verification).
>
> **Self-contained.** Everything below is sourced from the live `config.json`
> files in this repo. If a path is not on this page, the cleanup scripts
> will not touch it. No enumeration. No "rm everything that looks like
> VS Code." Pure allow-list.

---

## 1. Quick reference matrix

| OS      | Install script(s)                                                      | Cleanup script                                                                  | Safety mode                            |
|---------|------------------------------------------------------------------------|---------------------------------------------------------------------------------|----------------------------------------|
| Windows | `scripts/01-install-vscode`, `scripts/54-vscode-menu-installer install` | `scripts/54-vscode-menu-installer uninstall` (+ `repair`, `check`)              | Allow-listed registry keys only        |
| macOS   | (manual VS Code install) + `scripts-linux/11-install-vscode-settings-sync` | `scripts-linux/66-vscode-menu-cleanup-mac`                                      | Apply by default · `--dry-run` opt-in · plan-then-confirm · post-verify |
| Linux   | `scripts-linux/01-install-vscode` (apt or snap) + `11-install-vscode-settings-sync` | `scripts-linux/67-vscode-cleanup-linux` (detect → remove only matching method)  | Apply by default · `--dry-run` opt-in · plan-then-confirm · post-verify |
| Any     | n/a (host-wide hygiene)                                                | `scripts-linux/65-os-clean` (caches, trash, package caches)                     | Apply by default · `--dry-run` opt-in  |

Every cleanup script writes a timestamped run directory under
`.logs/<NN>/<YYYYMMDD-HHMMSS>/` containing:

- `command.txt` — exact CLI invocation,
- `rows.tsv` — one row per action attempted (`status\tmethod\tkind\ttarget\tdetail`),
- `plan.tsv` (66/67) — the dry-run preview shown to the operator,
- `verify.tsv` (66/67) — the independent post-cleanup re-probe results,
- `manifest.json` — the audit-quality summary (rows + verification block).

---

## 2. Windows

### 2.1 What gets installed

#### `scripts/01-install-vscode`
Installs Visual Studio Code via the official user-scope installer (downloaded
to `%TEMP%`). It does **not** add registry context-menu entries on its own —
that is Script 54's job.

| Surface              | Path                                                              |
|----------------------|-------------------------------------------------------------------|
| VS Code binary       | `%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe`              |
| VS Code Insiders     | `%LOCALAPPDATA%\Programs\Microsoft VS Code Insiders\Code - Insiders.exe` |
| Per-user uninstaller | `%LOCALAPPDATA%\Programs\Microsoft VS Code\unins000.exe`          |

> The toolkit does **not** ship a cleanup for the Code.exe binary itself —
> use the bundled `unins000.exe` (Add/Remove Programs) for that. The
> cleanup scripts below remove only the registry/menu/script *attachments*.

#### `scripts/54-vscode-menu-installer install`
Adds the "Open with Code" / "Open with Code - Insiders" entries to the
Windows shell context menu. Scope is `Auto` (HKLM via HKCR when elevated,
else HKCU). Scope is honored end-to-end across **install / uninstall /
repair / sync / check** — every verb resolves `-Scope` (Auto / CurrentUser
/ AllUsers) and rewrites the config paths via `Convert-EditionPathsForScope`
so reads and writes hit the EXACT hive that matches the requested mode:

| Resolved scope | Hive written / probed                                     | Admin? |
|----------------|-----------------------------------------------------------|--------|
| `AllUsers`     | `HKEY_CLASSES_ROOT\…` (physically `HKLM\Software\Classes`) | yes    |
| `CurrentUser`  | `HKEY_CURRENT_USER\Software\Classes\…`                    | no     |

The `check` verb in particular probes the resolved hive directly instead of
the merged HKCR view, so per-user installs are diagnosed independently of
anything that may also exist in HKLM.

The exact registry keys `install` writes — and the **only** keys
`uninstall` will ever delete (after the same scope rewrite) — are:

| Edition           | Surface       | Registry key (deleted by `uninstall`)                                                  |
|-------------------|---------------|-----------------------------------------------------------------------------------------|
| Stable            | File context  | `HKEY_CLASSES_ROOT\*\shell\VSCode`                                                      |
| Stable            | Folder        | `HKEY_CLASSES_ROOT\Directory\shell\VSCode`                                              |
| Stable            | Folder bg     | `HKEY_CLASSES_ROOT\Directory\Background\shell\VSCode`                                   |
| Insiders          | File context  | `HKEY_CLASSES_ROOT\*\shell\VSCodeInsiders`                                              |
| Insiders          | Folder        | `HKEY_CLASSES_ROOT\Directory\shell\VSCodeInsiders`                                      |
| Insiders          | Folder bg     | `HKEY_CLASSES_ROOT\Directory\Background\shell\VSCodeInsiders`                           |

These six keys (after the per-scope rewrite) are the entire allow-list.
Sibling keys are never enumerated.

### 2.2 What gets cleaned

#### `scripts/54-vscode-menu-installer uninstall`
Surgical removal of the six registry keys above (filtered to the requested
`-Scope` and `-Edition`). Process:

1. Resolve scope (`Auto`/`CurrentUser`/`AllUsers`) and gate on Administrator
   for `AllUsers`.
2. Iterate the **explicit** `registryPaths` allow-list from `config.json`
   for each requested edition. Nothing else is touched.
3. Per key: status reported as `removed`, `absent`, or `failed`.
4. Audit log written to the script's audit JSONL.
5. Post-uninstall verification re-probes every (scope-rewritten) key and
   confirms it is now absent. Any leftover key fails the run loudly.
6. On clean success, removes tracking entries from `.installed/` and
   `.resolved/`.

#### `scripts/54-vscode-menu-installer repair`
Removes legacy duplicate child keys (defined in `config.legacyNames`)
under `HKCR\*\shell`, `HKCR\Directory\shell`, and
`HKCR\Directory\Background\shell`. Allow-listed names only:

```
VSCode2 · VSCode3 · VSCodeOld · VSCode_old · OpenWithCode · OpenWithVSCode
Open with Code · OpenCode · VSCodeInsiders2 · VSCodeInsidersOld · OpenWithInsiders
```

#### `scripts/54-vscode-menu-installer check`
Read-only invariant check. Reports (and fails when
`enforceInvariants: true`) if:
- a file-target key is still present after a repair run,
- suppression values are present on directory/background keys,
- any legacy duplicate name from the list above is present.

#### Related Windows scripts (context-menu adjacent)

| Script                                  | What it adds                              | How to remove                          |
|-----------------------------------------|-------------------------------------------|----------------------------------------|
| `scripts/52-vscode-folder-repair`       | (read-only) Repairs broken folder keys    | n/a (no install side-effect)           |
| `scripts/56-vscode-folder-reregister`   | Re-writes folder context entries          | Run Script 54 `uninstall`              |
| `scripts/31-pwsh-context-menu`          | "Open PowerShell here" entries            | Companion uninstall verb in same script|
| `scripts/53-script-fixer-context-menu`  | "Run Script Fixer" right-click entry      | Companion uninstall verb in same script|

---

## 3. macOS

### 3.1 What gets installed

VS Code itself is installed manually on macOS (drag `Visual Studio Code.app`
into `/Applications`). The toolkit does **not** auto-install Code on macOS.
However, several "registry-equivalent" launch surfaces accumulate over time:

| Surface                        | Typical install location                                              |
|--------------------------------|-----------------------------------------------------------------------|
| Finder Quick Actions / Services| `~/Library/Services/*Code*.workflow`                                  |
| User LaunchAgents              | `~/Library/LaunchAgents/*.plist` (referencing `Code.app`)             |
| System LaunchAgents            | `/Library/LaunchAgents/*.plist`                                       |
| System LaunchDaemons           | `/Library/LaunchDaemons/*.plist`                                      |
| Login Items                    | System Events → "open at login" pointing at `Visual Studio Code`      |
| User shell shims               | `~/.local/bin/code`, `~/bin/code`, `…/code-insiders`                  |
| System shell shims             | `/usr/local/bin/code`, `/opt/homebrew/bin/code`, `…/code-insiders`    |
| `vscode://` URL handlers       | LaunchServices DB (`lsregister -dump`) bound to `com.microsoft.VSCode` / `…VSCodeInsiders` |

### 3.2 What gets cleaned — `scripts-linux/66-vscode-menu-cleanup-mac`

Surgical removal of the surfaces above, filtered to the resolved scope
(`user` = `~/Library` only; `system` = + `/Library`, `/usr/local`,
`/opt/homebrew`, requires sudo). The full allow-list (from `config.json`):

#### User scope (no sudo)

| Category id          | Mode        | Allow-listed root / pattern                                          |
|----------------------|-------------|----------------------------------------------------------------------|
| `services`           | glob        | `~/Library/Services/{*Code*.workflow, *VSCode*.workflow, *Visual Studio Code*.workflow}` |
| `launchagents-user`  | launchctl   | `~/Library/LaunchAgents/*.plist` whose ProgramArguments contain `Code.app`, `Code - Insiders.app`, `/code`, or `/code-insiders` |
| `loginitems`         | osascript   | Login Items named `Visual Studio Code` or `Visual Studio Code - Insiders` |
| `shims-user`         | shim        | `{~/.local/bin, ~/bin}/{code, code-insiders}` (provenance check: file/symlink must reference `Code.app`) |
| `url-handlers-user`  | lsregister  | `vscode://`, `vscode-insiders://` handlers bound to `com.microsoft.VSCode*` |

#### System scope (sudo required)

| Category id            | Mode      | Allow-listed root / pattern                                       |
|------------------------|-----------|-------------------------------------------------------------------|
| `launchagents-system`  | launchctl | `/Library/LaunchAgents/*.plist` (same provenance match)           |
| `launchdaemons-system` | launchctl | `/Library/LaunchDaemons/*.plist` (same provenance match)          |
| `shims-system`         | shim      | `{/usr/local/bin, /opt/homebrew/bin}/{code, code-insiders}` (provenance) |

**Provenance check.** Shim files are removed only when they (a) live in the
configured root *and* (b) the file content or symlink target references
`Code.app`, `Code - Insiders.app`, or `Visual Studio Code`. A shell script
called `code` that does not reference VS Code is **kept**.

### 3.3 Workflow (mac)

1. **Plan phase.** Forced dry-run pass writes `plan.tsv`.
2. **Confirm.** Tree + flat-table view of every targeted item; operator
   types `yes`. `--yes` / `-y` skips the prompt for CI.
3. **Apply.** `rows.tsv` reset; real run executes deletions.
4. **Verify.** Independent re-probe of every removed/would target. The
   verdict is rendered as `✅ PASS` or `❌ FAIL` and embedded in
   `manifest.json` under `verification.{rows,totals}`.
5. **Exit codes.** `0` clean · `1` apply failure · `2` aborted at confirm
   · `3` apply succeeded but verification found leftovers.

---

## 4. Linux

### 4.1 What gets installed

#### `scripts-linux/01-install-vscode`
Installs VS Code via **either** (a) the Microsoft apt repo or (b) the
`code` snap (classic). Surfaces created:

| Method   | Surfaces created                                                                                       |
|----------|--------------------------------------------------------------------------------------------------------|
| apt      | `/usr/bin/code`, `/usr/share/code/`, `/usr/share/applications/code.desktop`, `/etc/apt/sources.list.d/vscode.list`, `/usr/share/keyrings/packages.microsoft.gpg` |
| snap     | `/snap/code/`, `/var/snap/code/`, snap-managed `code` shim                                             |
| deb (manual `dpkg -i`) | same files as apt **without** the `vscode.list` source                                       |
| tarball  | `/opt/VSCode-linux-*` (or `~/VSCode-linux-*` / `~/.local/share/code`), per-user shim under `~/.local/bin/code` |
| user-config (always) | `~/.config/Code`, `~/.vscode`, `~/.vscode-server` (created on first launch / first remote SSH) |

#### `scripts-linux/11-install-vscode-settings-sync`
Drops a curated `settings.json`/`keybindings.json` into `~/.config/Code/User/`.
No system-wide files. Removed by Script 67's `user-config` method.

### 4.2 What gets cleaned — `scripts-linux/67-vscode-cleanup-linux`

Two-phase. **Detect** first (read-only probes), then **remove** only the
methods that probed positive. The detect-only verb is `67 detect`.

#### Detection probes (read-only)

| Method id     | Probes (any hit ⇒ method considered present)                                              |
|---------------|--------------------------------------------------------------------------------------------|
| `apt`         | `dpkg -s code` · `dpkg -s code-insiders` · `[ -f /etc/apt/sources.list.d/vscode.list ]` · `[ -f /usr/share/keyrings/packages.microsoft.gpg ]` |
| `snap`        | `snap list code` · `snap list code-insiders`                                               |
| `deb`         | `dpkg -s code{,-insiders}` **AND** `vscode.list` is **not** present (manual `dpkg -i`)     |
| `tarball`     | any of `/opt/VSCode-linux-x64`, `/opt/VSCode-linux-arm64`, `/opt/visual-studio-code`, `~/VSCode-linux-x64`, `~/.local/share/code` exists |
| `user-config` | any of `~/.config/Code`, `~/.config/Code - Insiders`, `~/.vscode`, `~/.vscode-insiders`, `~/.vscode-server`, `~/.vscode-server-insiders` exists |

#### Removal allow-list (per method)

##### `apt` (system-scope, sudo)
1. `apt-get purge -y code code-insiders`
2. `rm -f /etc/apt/sources.list.d/vscode.list`
3. `rm -f /usr/share/keyrings/packages.microsoft.gpg`
4. `apt-get update -y` (refresh after repo removal)

##### `snap` (system-scope, sudo)
1. `snap remove code` · `snap remove code-insiders`

##### `deb` (system-scope, sudo)
1. `dpkg -r code` · `dpkg -r code-insiders`

##### `tarball` (mixed scope)
| Step | Path | Sudo? |
|------|------|-------|
| `rm-dir`  | `/opt/VSCode-linux-x64`                          | yes |
| `rm-dir`  | `/opt/VSCode-linux-arm64`                        | yes |
| `rm-dir`  | `/opt/visual-studio-code`                        | yes |
| `rm-dir`  | `~/VSCode-linux-x64`                             | no  |
| `rm-dir`  | `~/.local/share/code`                            | no  |
| `rm-shim` | `/usr/local/bin/code`                            | yes |
| `rm-shim` | `/usr/local/bin/code-insiders`                   | yes |
| `rm-shim` | `~/.local/bin/code`                              | no  |
| `rm-shim` | `~/.local/bin/code-insiders`                     | no  |
| `rm-file` | `/usr/share/applications/code.desktop`           | yes |
| `rm-file` | `/usr/share/applications/code-insiders.desktop`  | yes |
| `rm-file` | `~/.local/share/applications/code.desktop`       | no  |
| `rm-file` | `~/.local/share/applications/code-insiders.desktop` | no |

##### `user-config` (user-scope, no sudo)
1. `rm -rf ~/.config/Code`
2. `rm -rf ~/.config/Code - Insiders`
3. `rm -rf ~/.vscode`
4. `rm -rf ~/.vscode-insiders`
5. `rm -rf ~/.vscode-server`
6. `rm -rf ~/.vscode-server-insiders`

### 4.3 Workflow (linux) — same as macOS

Plan → confirm → apply → verify (re-probes packages via `dpkg -s` /
`snap list` and paths via filesystem stat). Exit codes `0/1/2/3` identical
to macOS.

### 4.4 Host-wide hygiene — `scripts-linux/65-os-clean`

Cross-OS user/system cache cleanup (Linux + macOS). **Not VS Code-specific.**
Useful as a follow-up after Script 67/66 to reclaim disk:

| Category id        | OS    | Action                                                              |
|--------------------|-------|---------------------------------------------------------------------|
| `temp-user`        | both  | Glob delete in `${TMPDIR:-/tmp}/${USER}-*`                          |
| `caches-user`      | both  | Empty contents of `~/.cache` (Linux) / `~/Library/Caches` (macOS), preserving `lovable`, `ssh`, `gnupg` subdirs |
| `trash`            | both  | Empty contents of `~/.local/share/Trash/{files,info}` (Linux) or `~/.Trash` (macOS) — requires `--yes` |
| `pkg-apt`          | linux | `sudo apt-get clean` (or `-s` for dry-run)                          |
| `pkg-dnf`          | linux | `sudo dnf clean all`                                                |
| `pkg-pacman`       | linux | `sudo pacman -Sc`                                                   |
| `logs-system`      | linux | `journalctl --vacuum-time=…` — requires `--yes`                     |

Script 65 is the only cleanup script that **does not yet** ship the
plan-then-confirm + post-verification workflow — that wiring is on the
remaining-tasks list.

---

## 5. Safety guarantees (CODE RED)

1. **Allow-list only.** Every cleanup script reads its target list from
   `config.json`. There is no `find / -name code -delete`-style code path
   anywhere in this repo.
2. **File-path errors include exact path + reason.** Every `rm` failure is
   logged via `Write-FileError` (PowerShell) or `log_file_error` (bash) with
   the literal failing path and the reason (permission, missing tool, etc.).
3. **Plan-then-confirm** (66, 67). Apply mode runs a dry-run first, prints
   a tree + flat-table preview, then prompts for `yes`. Skipped only with
   `--yes` / `-y` (CI) or when no TTY exists (in which case the run aborts).
4. **Post-cleanup verification** (66, 67). Independent re-probe of every
   removed/would target. Verdict (`✅ PASS` / `❌ FAIL`) printed and
   embedded in `manifest.json`. Exit code `3` if leftovers found.
5. **Audit trail.** Every run produces `.logs/<NN>/<TS>/manifest.json` plus
   `rows.tsv`, `plan.tsv`, `verify.tsv`, `command.txt`. Aborted runs still
   write a manifest with `mode: "aborted"` so you have a record of what
   *would* have happened.

---

## 6. Quick command reference

```bash
# Windows (PowerShell, elevated for AllUsers)
.\scripts\54-vscode-menu-installer\install.ps1   -Scope Auto
.\scripts\54-vscode-menu-installer\uninstall.ps1 -Scope Auto
.\scripts\54-vscode-menu-installer\check.ps1
.\scripts\54-vscode-menu-installer\repair.ps1

# macOS — preview, then apply
bash scripts-linux/66-vscode-menu-cleanup-mac/run.sh --dry-run --scope user
bash scripts-linux/66-vscode-menu-cleanup-mac/run.sh           --scope user
sudo bash scripts-linux/66-vscode-menu-cleanup-mac/run.sh      --scope system

# Linux — detect, then preview, then apply
bash scripts-linux/67-vscode-cleanup-linux/run.sh detect
bash scripts-linux/67-vscode-cleanup-linux/run.sh --dry-run --scope user
bash scripts-linux/67-vscode-cleanup-linux/run.sh           --scope user
sudo bash scripts-linux/67-vscode-cleanup-linux/run.sh      --scope system

# Limit Linux cleanup to a single detected method
bash scripts-linux/67-vscode-cleanup-linux/run.sh --only user-config

# CI / scripted use (skip the confirm prompt)
bash scripts-linux/66-vscode-menu-cleanup-mac/run.sh --yes
bash scripts-linux/67-vscode-cleanup-linux/run.sh    --yes

# Host-wide cache hygiene (any OS)
bash scripts-linux/65-os-clean/run.sh --dry-run
bash scripts-linux/65-os-clean/run.sh
```

---

## 7. Where this doc lives in the repo

- This file: `docs/01-cleanup-overview.md`
- Sibling per-script READMEs: `scripts/<NN>-*/readme.md`,
  `scripts-linux/<NN>-*/readme.{md,txt}`
- Live allow-lists this doc summarises (single source of truth):
  - `scripts/54-vscode-menu-installer/config.json`
  - `scripts-linux/66-vscode-menu-cleanup-mac/config.json`
  - `scripts-linux/67-vscode-cleanup-linux/config.json`
  - `scripts-linux/65-os-clean/config.json`

If a config changes, update this page in the same commit so the operator-
facing summary never drifts from the executable allow-list.
