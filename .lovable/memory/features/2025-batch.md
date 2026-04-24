---
name: 2025 batch spec
description: Master spec for 2025 batch -- 5 new tool installers (47-51), 4 OS subcommands, gsa, 5 install profiles
type: feature
---

## 2025 Batch -- Groups A+B+D SHIPPED, Groups C and E pending

**Spec location**: `spec/2025-batch/readme.md` + 12 numbered subdocs (`01-*.md` ... `12-*.md`)
**Status**: Group A done in v0.39.1. Group B done in v0.39.2. Group D done in v0.39.4. Groups C and E pending.
**Final target version**: v0.40.0 (minor bump per project rule, accumulated through patches v0.39.1+)

## Decisions locked

| Topic | Decision |
|-------|----------|
| Spec layout | Master + per-feature subdocs |
| Profile invocation | Both -- keywords (`profile-base`) AND subcommand (`run profile base`) |
| OS-dir installs | Skip dev-dir prompt, use Chocolatey defaults |
| ConEmu XML | `settings/06 - conemu/ConEmu.xml` -- copied from user upload |
| `add-user` password | Plain CLI args (user accepted risk) |
| WhatsApp + OneNote | Chocolatey only -- no Microsoft Store |
| `gsa` | Both wildcard (default) and `--scan <path>` per-repo modes |

## New scripts (47-51)

| ID | Folder | Subdoc |
|----|--------|--------|
| 47 | `47-install-ubuntu-font` | `01-ubuntu-font.md` |
| 48 | `48-install-conemu` | `02-conemu.md` (3-mode pattern like NPP) |
| 49 | `49-install-whatsapp` | `03-whatsapp.md` |
| 50 | `50-install-onenote` | `06-onenote.md` (+ tray remove + OneDrive disable) |
| 51 | `51-install-lightshot` | `09-lightshot.md` (+ registry tweaks) |

## New subcommand dispatchers

- `scripts/os/run.ps1` -- handles `os clean`, `os hib-off`, `os flp`, `os add-user`
- `scripts/git-tools/run.ps1` -- handles `gsa` / `git-safe-all`
- `scripts/profile/run.ps1` -- handles `profile <name>` for 5 profiles

## 8 profiles

minimal | base | git-compact | advance (= base + git-compact + extras, **no langs**) | cpp-dx | small-dev (= advance + Go only) | dev (= small-dev + Python+Node+pnpm+Rust+PHP) | dev-advance (= dev + .NET + cpp-dx)

Profiles defined declaratively in `scripts/profile/config.json` -- step kinds: `script`, `choco`, `subcommand`, `inline`, `profile` (recursive expansion with cycle detection).

## Implementation order

1. Spec sign-off (current)
2. Group A: single-tool installers (47, 48, 49, 50, 51)
3. Group B: `os` dispatcher + `clean`, `flp`, `add-user`, `hib-off`
4. Group C: `git-tools` dispatcher + `gsa`
5. Group D: `profile` dispatcher + 5 recipes
6. Group E: polish + default git config update + version bump to v0.40.0

## Files already created

- `settings/06 - conemu/ConEmu.xml` (copied from user upload `07. Alim Desktop workstation 11 - 10 dec 2024.xml`)
- `settings/06 - conemu/readme.txt`
- `spec/2025-batch/` (master + 12 subdocs)
