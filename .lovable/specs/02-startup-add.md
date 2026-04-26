# Spec 02 — Cross-OS `startup-add` (apps + env vars)

let's start now 2026-04-26 22:30 MYT

## 1. Goal
Add a single conceptual command — `startup-add` — that lets the user register
either an **application** (executable / script) or an **environment variable**
to run/exist at user login. Available on **Windows, Linux, macOS** with a
method picker so the user can choose *how* the entry is persisted.

Decisions locked in (this conversation):
- Scope: **apps + env vars (both)**
- Windows methods: **all 4** (Startup folder, HKCU Run, HKLM Run, Task Scheduler)
- Unix methods: **auto-detect per OS** (systemd-user / .desktop / shell rc on Linux;
  LaunchAgent / login items / shell rc on macOS)
- Default mode: **safest per OS** (no admin, no surprises)

## 2. Surface

### Windows (PowerShell, lives in `scripts/os/`)
```
.\run.ps1 os startup-add app   <path>   [--method auto|startup-folder|hkcu-run|hklm-run|task] [--name N] [--args "..."] [--interactive]
.\run.ps1 os startup-add env   KEY=VAL  [--scope user|machine] [--method registry|setx]
.\run.ps1 os startup-list                [--scope user|machine|all]
.\run.ps1 os startup-remove    <name>    [--method ...]
```
Safest defaults:
- `app` → **startup-folder** (`.lnk` in `shell:Startup`, no admin, easy to undo)
- `env` → **HKCU Environment** key + WM_SETTINGCHANGE broadcast (no admin)

### Linux/macOS (bash, new script id `64-startup-add` in `scripts-linux/`)
```
./run.sh -I 64 -- app  <path> [--method auto|systemd|autostart|shell-rc|launchagent] [--name N]
./run.sh -I 64 -- env  KEY=VAL [--scope user|machine] [--method shell-rc|systemd-env|launchctl]
./run.sh -I 64 -- list
./run.sh -I 64 -- remove <name> [--method ...]
```
Safest defaults per OS:
- Linux GUI session present → `~/.config/autostart/<name>.desktop`
- Linux headless → `~/.config/systemd/user/<name>.service` + `loginctl enable-linger`
- macOS → `~/Library/LaunchAgents/com.lovable.<name>.plist`
- env → append to `~/.zshrc` (or `~/.bashrc`) inside marker block:
  ```
  # >>> lovable-startup-env (managed) >>>
  export FOO="bar"
  # <<< lovable-startup-env <<<
  ```

## 3. Method matrix

| OS      | app method        | needs admin? | persistence layer |
|---------|-------------------|--------------|-------------------|
| Windows | startup-folder    | no           | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\<name>.lnk` |
| Windows | hkcu-run          | no           | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` |
| Windows | hklm-run          | YES          | `HKLM:\Software\Microsoft\Windows\CurrentVersion\Run` |
| Windows | task              | yes for HIGHEST | `schtasks /Create /TN ... /SC ONLOGON` |
| Linux   | autostart         | no           | `~/.config/autostart/<name>.desktop` |
| Linux   | systemd-user      | no           | `systemctl --user enable <name>.service` |
| Linux   | shell-rc          | no           | append to `~/.bashrc` / `~/.zshrc` (marker block) |
| macOS   | launchagent       | no           | `~/Library/LaunchAgents/com.lovable.<name>.plist` + `launchctl load` |
| macOS   | login-item        | no           | AppleScript `osascript -e 'tell application "System Events"...'` |
| macOS   | shell-rc          | no           | same as Linux |

## 4. Idempotency rules
- Each entry gets a `--name` (auto-derived from path basename if omitted).
- All managed entries are tagged `lovable-startup` (registry value name prefix,
  filename prefix, .desktop comment, plist label) so `list`/`remove` can filter
  them without touching unrelated user entries.
- `add` is **upsert**: same name + same method → replace.
  Same name + different method → warn, require `--force-replace`.

## 5. Logging
- Windows: `scripts/logs/startup-add.json` (uses `Initialize-Logging` /
  `Save-LogFile` from `scripts/shared/logging.ps1`).
- Unix: per-run dir `.logs/64/<TIMESTAMP>/` with `command.txt`, `manifest.json`,
  `session.log` (mirrors the `63-remote-runner` layout).
- Every error MUST log exact path + reason (CODE RED rule).

## 6. Build plan (multi-step — confirm "next" between phases)

1. **Phase A — Windows skeleton**
   - `scripts/os/helpers/startup-add.ps1` + `startup-list.ps1` + `startup-remove.ps1`
   - Wire dispatcher cases in `scripts/os/run.ps1`
   - Update `log-messages.json` with `startup.*` keys
   - Update `config.json` with `startup` block (paths, registry keys, defaults)

2. **Phase B — Windows methods**
   - Implement startup-folder (.lnk via WScript.Shell)
   - HKCU Run + HKLM Run (admin guard via `Assert-Admin`)
   - Task Scheduler (`schtasks /Create /SC ONLOGON`)
   - Interactive picker (`--interactive` or default when ambiguous)

3. **Phase C — Unix script `64-startup-add`**
   - Folder skeleton matching `63-remote-runner`
   - OS detect (`uname -s`), session detect (`$XDG_CURRENT_DESKTOP`, `$DISPLAY`)
   - Implement autostart, systemd-user, shell-rc
   - macOS: LaunchAgent + login-item + shell-rc
   - Register in `scripts-linux/registry.json` (id 64, phase 12)
   - Bump root toolkit version to **0.123.0**

4. **Phase D — list / remove / tests / docs**
   - `list` enumerates all methods, filters by `lovable-startup` tag
   - `remove <name>` deletes from whichever method holds it
   - Regression tests under `tests/` (bash side; PS side gets manual smoke checklist)
   - readme.txt + memory file `mem://features/startup-add`
   - Update `mem://index.md`

## 7. Non-goals (explicit)
- No system-wide (HKLM / `/etc/profile.d`) defaults unless the user explicitly
  picks a machine-scope method.
- No GUI. Picker is TTY only.
- No Windows Services. Task Scheduler covers the "needs trigger" case.
