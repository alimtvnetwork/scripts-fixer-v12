---
name: install-paths-trio
description: CODE RED — every install/extract/repair/sync logs Source + Temp + Target via Write-InstallPaths
type: feature
---

# Install-paths trio

`scripts/shared/install-paths.ps1` exposes `Write-InstallPaths -Source -Temp -Target [-Tool] [-Action]`.

Every install / extract / repair / sync action MUST call it after the banner
and before the first download/install step. Missing values render as
`(unknown)` in yellow but the call is still mandatory.

Spec: `spec/shared/install-paths.md`.

Helper also exposes `Resolve-DefaultTempDir -ToolSlug <slug>` which returns
`$env:TEMP\scripts-fixer\<slug>` (created on demand).

JSON log event shape: `installPaths tool=… action=… source=… temp=… target=…`

Adoption batches:
- A: 02 choco, 07 git, 03 node, 04 pnpm, 05 python, 06 go, 14 winget, 17 powershell, 44 rust
- B: 01 vscode, 33 npp, 36 obs, 37 wt, 32 dbeaver, 47 ubuntu-font, 48 conemu, 49 whatsapp
- C: 18-29 databases
- D: 16 php, 38 flutter, 39 dotnet, 40 java, 41 python-libs
- E: 42 ollama, 43 llama-cpp, 45 docker, 46 k8s, 50 onenote
- F: 12, 31, 34, 35, 51, 52, profile, databases, models dispatchers
