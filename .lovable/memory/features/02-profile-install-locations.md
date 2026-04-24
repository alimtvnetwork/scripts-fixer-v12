---
name: profile-install-locations
description: Per-profile install location matrix (C:\ system vs E:\dev-tool) -- must stay in sync between README, spec, and config.json
type: feature
---
# Profile install locations

Every profile in `scripts/profile/config.json` installs a mix of tools.
The root README and `spec/2025-batch/12-profiles.md` MUST present a
**per-profile install location table** with three columns:

| Tool | Where it lands | Why |

They should also include a short **profile total summary** that states:
- total step count
- what lands on `C:\`
- what lands on `E:\dev-tool\` (if anything)
- whether registry / system tweaks are included

## Conventions

- **C:\Program Files / C:\Program Files (x86)** -> all `choco` steps
  (vlc, 7zip, winrar, xmind, googlechrome, wordweb-free, beyondcompare,
  vcredist-all, directx, directx-sdk, whatsapp). Choco does NOT relocate
  to E:\ -- documented as "system drive, no override".
- **E:\dev-tool\\<tool>** -> dev-runtimes installed by numbered scripts
  03/04/05/06/16/44 (nodejs+yarn+bun, pnpm, python, golang, php, rust)
  via `$env:DEV_DIR`. These respect `path` subcommand override.
- **%LOCALAPPDATA%** -> WhatsApp, GitHub Desktop, VS Code (per-user
  installs that do not honor a custom dir).
- **%USERPROFILE%\.ssh, \.gitconfig, \GitHub** -> git-compact inline
  helpers (`Setup-SshKey`, `Apply-DefaultGitConfig`, `Setup-GitHubDir`).
- **System registry (HKLM/HKCU)** -> `os hib-off`, Win11 classic
  context-menu restore (HKCU CLSID).

## Profile chain (v0.94.0)

`small-dev` is **advance + Go only** (24 steps). Polyglot runtimes
moved into two new profiles:

- `dev` = small-dev + Python + Node(+Yarn+Bun) + pnpm + Rust + PHP (29 steps)
- `dev-advance` = dev + .NET SDK (#39) + cpp-dx (33 steps)

Total profile count is now **8**: minimal, base, git-compact, advance,
cpp-dx, small-dev, dev, dev-advance.

## Rule

When adding/removing a profile step, update **all three** in the same
commit:
1. `scripts/profile/config.json`
2. `spec/2025-batch/12-profiles.md` install-location table
3. `readme.md` per-profile H3 section table

If a step's location is non-obvious (e.g. choco flag override, env var),
note it in the table's "Why" column.
