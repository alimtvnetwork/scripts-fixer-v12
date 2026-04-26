# Spec 02 — Cross-OS `startup-add` (apps + env vars)

let's start now 2026-04-26 22:45 MYT

## Goal
A single conceptual command `startup-add` that registers either an
**application** (executable / script) or an **environment variable** to be
present at user login. Available on **Windows, Linux, macOS** with a method
picker so the user can choose *how* the entry is persisted.

Decisions locked in:
- Scope: **apps + env vars (both)**
- Windows methods: **all 4** (Startup folder, HKCU Run, HKLM Run, Task Scheduler)
- Unix methods: **auto-detect per OS** (autostart / systemd-user / shell-rc on Linux;
  LaunchAgent / login items / shell-rc on macOS)
- Default mode: **safest per OS** (no admin, no surprises)

## Command surface

### Windows (`scripts/os/`)
```
.\run.ps1 os startup-add app  <path>    [--method auto|startup-folder|hkcu-run|hklm-run|task] [--name N] [--args "..."] [--interactive]
.\run.ps1 os startup-add env  KEY=VAL   [--scope user|machine] [--method registry|setx]
.\run.ps1 os startup-list                [--scope user|machine|all]
.\run.ps1 os startup-remove   <name>     [--method ...]
```
Safest defaults: `app` → startup-folder (.lnk), `env` → HKCU Environment + WM_SETTINGCHANGE.

### Unix (`scripts-linux/64-startup-add/`)
```
./run.sh -I 64 -- app  <path> [--method auto|systemd|autostart|shell-rc|launchagent|login-item] [--name N]
./run.sh -I 64 -- env  KEY=VAL [--scope user] [--method shell-rc|systemd-env|launchctl]
./run.sh -I 64 -- list
./run.sh -I 64 -- remove <name> [--method ...]
```
Safest defaults: Linux GUI → autostart; Linux headless → systemd-user;
macOS → LaunchAgent; env → shell-rc marker block.

## Method matrix
| OS | method | admin | persistence |
|----|--------|-------|-------------|
| Win | startup-folder | no | `%APPDATA%\...\Startup\<name>.lnk` |
| Win | hkcu-run | no | `HKCU:\...\Run\lovable-startup-<name>` |
| Win | hklm-run | YES | `HKLM:\...\Run\lovable-startup-<name>` |
| Win | task | yes for HIGHEST | `schtasks /Create /SC ONLOGON /TN lovable-startup\<name>` |
| Linux | autostart | no | `~/.config/autostart/lovable-startup-<name>.desktop` |
| Linux | systemd-user | no | `~/.config/systemd/user/lovable-startup-<name>.service` |
| Linux | shell-rc | no | marker block in `~/.bashrc` / `~/.zshrc` |
| macOS | launchagent | no | `~/Library/LaunchAgents/com.lovable.startup.<name>.plist` |
| macOS | login-item | no | osascript → System Events login items |
| macOS | shell-rc | no | same as Linux |

## Idempotency
- Auto `--name` from path basename.
- Tag prefix `lovable-startup` on every artefact → safe enumerate/remove.
- `add` is upsert: same name + same method → replace; same name + different method → warn unless `--force-replace`.

## Logging
- Win: `scripts/logs/startup-add.json` via existing `Initialize-Logging` / `Save-LogFile`.
- Unix: `.logs/64/<TS>/{command.txt,manifest.json,session.log}` mirroring 63-remote-runner.
- CODE RED: every file/path error must include exact path + reason.

## 12-Step Build Plan

| # | Title | Surface |
|---|-------|---------|
| 1 | Spec + 12-step plan | this file |
| 2 | Win config + log-messages | `scripts/os/config.json`, `log-messages.json` |
| 3 | Win shared startup helper | `helpers/_startup-common.ps1` |
| 4 | Win startup-add app methods | `helpers/startup-add.ps1` (4 methods + picker) |
| 5 | Win startup-add env | env subcommand + WM_SETTINGCHANGE |
| 6 | Win list + remove + dispatch | `startup-list.ps1`, `startup-remove.ps1`, `run.ps1` cases |
| 7 | Unix script skeleton (id 64) | `scripts-linux/64-startup-add/*`, `registry.json`, root `run.sh` v0.123.0 |
| 8 | Unix OS + session detect | `helpers/detect.sh` |
| 9 | Linux app methods | autostart .desktop, systemd-user, shell-rc |
| 10 | macOS app methods + env | LaunchAgent, login-item, shell-rc env writer |
| 11 | Unix list + remove | enumerate by tag, confirm-prompt remove |
| 12 | Tests + docs + memory | `tests/test-startup.sh`, readme, mem file, index update |

## Non-goals
- No HKLM/system-wide defaults unless user explicitly opts in.
- No GUI; picker is TTY only.
- No Windows Services (Task Scheduler covers triggered-start case).
