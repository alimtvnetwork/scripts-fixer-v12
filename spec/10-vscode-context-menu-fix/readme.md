<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Spec 10 — Vscode Context Menu Fix" width="128" height="128"/>

# Spec 10 — Vscode Context Menu Fix

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-10-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.112.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

# Spec: VS Code Context Menu Fix

## Overview

A PowerShell utility that restores the **"Open with Code"** entry to the Windows
Explorer right-click context menu for files, folders, and folder backgrounds.

---

## Problem

After certain Windows updates or VS Code installations/reinstallations, the
context-menu entries for VS Code disappear. Users lose the ability to:

1. Right-click a **file** → "Open with Code"
2. Right-click a **folder** → "Open with Code"
3. Right-click the **background** of a folder (empty space) → "Open with Code"

## Solution

A structured PowerShell script that:

- Reads configuration (paths, labels) from an external **`config.json`**
- Reads all log/display messages from a separate **`log-messages.json`**
- Creates the required Windows Registry entries under `HKEY_CLASSES_ROOT`
- Provides colorful, structured terminal output with status badges

---

## File Structure

```
run.ps1                              # Root dispatcher (git pull + delegate)
scripts/
├── shared/
│   ├── git-pull.ps1                 # Shared git-pull helper (dot-sourced)
│   ├── logging.ps1                  # Write-Log, Write-Banner, Initialize-Logging, Import-JsonConfig
│   ├── json-utils.ps1               # Backup-File, Merge-JsonDeep, ConvertTo-OrderedHashtable
│   └── resolved.ps1                 # Save-ResolvedData, Get-ResolvedDir
└── 01-vscode-context-menu-fix/
    ├── config.json                  # Paths & settings (user-editable, never mutated at runtime)
    ├── log-messages.json            # All display strings & banners
    ├── run.ps1                      # Main script
    ├── helpers/
    │   ├── logging.ps1              # Script-specific logging (dot-sources shared)
    │   └── registry.ps1             # Registry & VS Code resolution helpers
    └── logs/                        # Auto-created runtime log folder (gitignored)
        └── run-<timestamp>.log      # Timestamped execution log

.resolved/                           # Runtime-resolved data (gitignored)
└── 01-vscode-context-menu-fix/
    └── resolved.json                # Cached exe paths, timestamps, username

spec/
├── shared/
│   └── readme.md                    # Shared helpers specification
└── 01-vscode-context-menu-fix/
    └── readme.md                    # This specification
```

## config.json Schema

`config.json` is **read-only at runtime**. Scripts never write back to it.
Runtime-discovered state goes to `.resolved/` instead.

| Key                  | Type   | Description                                        |
|----------------------|--------|----------------------------------------------------|
| `vscodePath.user`    | string | Path for per-user VS Code install (with env vars)  |
| `vscodePath.system`  | string | Path for system-wide VS Code install               |
| `registryPaths.file` | string | Registry key for file context menu                 |
| `registryPaths.directory` | string | Registry key for folder context menu          |
| `registryPaths.background` | string | Registry key for folder background menu     |
| `contextMenuLabel`   | string | Label shown in the context menu                    |
| `installationType`   | string | `"user"` or `"system"` — which path to try first   |

## .resolved/ Schema

Written automatically by the script to `.resolved/01-vscode-context-menu-fix/resolved.json`:

```json
{
  "stable": {
    "resolvedExe": "C:\\Program Files\\Microsoft VS Code\\Code.exe",
    "resolvedAt": "2026-04-03T18:10:02+08:00",
    "resolvedBy": "alim"
  },
  "insiders": {
    "resolvedExe": "C:\\Program Files\\Microsoft VS Code Insiders\\Code - Insiders.exe",
    "resolvedAt": "2026-04-03T18:10:05+08:00",
    "resolvedBy": "alim"
  }
}
```

On subsequent runs, `Resolve-VsCodePath` checks the cache first and skips
detection if the cached exe path still exists on disk.

## log-messages.json Schema

| Key       | Type     | Description                              |
|-----------|----------|------------------------------------------|
| `banner`  | string[] | ASCII art banner lines                   |
| `steps.*` | string   | Message for each step of the process     |
| `status.*`| string   | Badge labels: `[  OK  ]`, `[ FAIL ]` etc |
| `errors.*`| string   | Error message templates                  |
| `footer`  | string[] | Closing banner lines                     |

## Script Architecture

The script is organized into **small, focused functions** that are defined first,
then invoked from a single `Main` entry point at the bottom of the file.

### Function Breakdown

| Function | Purpose |
|----------|---------|
| `Write-Log` | Prints a status-badged message and writes to transcript |
| `Write-Banner` | Displays ASCII banner blocks |
| `Assert-Admin` | Returns `$true` if running as Administrator |
| `Initialize-Logging` | Cleans and recreates `logs/`, starts transcript |
| `Import-JsonConfig` | Loads and returns a JSON file with verbose logging |
| `Mount-RegistryDrive` | Maps `HKCR:` PSDrive if not already mapped |
| `Resolve-VsCodePath` | Resolves exe path with fallback, logs every step |
| `Register-ContextMenu` | Creates one registry entry (key + command subkey) |
| `Test-RegistryEntry` | Verifies a registry path exists after creation |
| `Invoke-Edition` | Processes a single edition (resolve, register, verify) |
| `Main` | Orchestrates the full flow -- called at the end of the file |

### Verbose Logging Rules

Every function MUST log:
- **What it is about to do** (the intent)
- **The values it is working with** (paths, keys, labels)
- **The outcome** (success, failure, skip, fallback)

Example: path resolution must log the raw config value, the expanded value,
whether the file exists, and which fallback (if any) was tried.

## Execution Flow

1. `Main` is called at the bottom of the script
2. Dot-source shared helpers (`git-pull.ps1`, `resolved.ps1`) and call `Invoke-GitPull`
   - If `$env:SCRIPTS_ROOT_RUN` is `"1"` (set by root dispatcher), git pull is skipped
   - If run standalone, git pull executes normally
3. `Initialize-Logging` -- clean `logs/`, start transcript
4. `Import-JsonConfig` -- load `log-messages.json`, display banner
5. `Assert-Admin` -- verify Administrator privileges
6. `Import-JsonConfig` -- load `config.json`
7. `Mount-RegistryDrive` -- map `HKCR:` PSDrive (with `-Scope Global`)
8. For each enabled edition -> `Invoke-Edition`:
   a. `Resolve-VsCodePath` -- **check `.resolved/` cache first**, then detect with fallback
   b. `Save-ResolvedData` -- persist discovered path to `.resolved/`
   c. `Register-ContextMenu` -- create 3 registry entries
   d. `Test-RegistryEntry` -- verify each entry
9. Display summary footer

## Logging

- Each run creates a `logs/` subfolder inside the script directory
- The `logs/` folder is **deleted and recreated** at the start of every run
- A timestamped log file (`run-YYYYMMDD-HHmmss.log`) captures all terminal output
- The `logs` folder is already gitignored by the project-level `.gitignore`
- All `New-Item` and `Set-ItemProperty` calls use `-Confirm:$false` to prevent hangs
- **Every decision point** logs its inputs and outputs for easy debugging

## Prerequisites

- **Windows 10/11**
- **PowerShell 5.1+**
- **Administrator privileges**
- **VS Code installed** (user or system)

## How to Run

```powershell
# Open PowerShell as Administrator, then:
cd scripts\01-vscode-context-menu-fix
.\run.ps1
```

## Check, Repair, and Invariants

### Invariant checks

The `check` verb verifies three repair invariants in addition to the install-state checks:

| # | Invariant |
|---|-----------|
| 1 | No `file-target` child key under `HKCR\*\shell` |
| 2 | No suppression values (`LegacyDisable`, `Extended`, `HideBasedOnVelocityId`) on any of the three shell parents |
| 3 | No legacy duplicate child keys (allow-list in `config.repair.legacyNames`) under any of the three shell parents |

### Opt-out: `config.repair.enforceInvariants`

`config.json` contains `repair.enforceInvariants` (default `true`). When `true`, the `check` verb **fails** on invariant violations (exit code 1). When `false`, violations are **downgraded to warnings** and the run exits 0.

The install-state checks ("is the entry registered?") are **always** enforced regardless of this flag.

#### Where it is evaluated (code path)

The flag is consulted **only** during the `check` verb. The exact call chain is:

| Step | File | Line(s) | What happens |
|------|------|---------|--------------|
| 1 | `scripts/10-vscode-context-menu-fix/run.ps1` | `if ($cmdLower -eq 'check')` block (~L84) | Dispatcher enters the `check` branch. |
| 2 | `scripts/10-vscode-context-menu-fix/run.ps1` | `Invoke-Script10RepairInvariantCheck -Config $config ...` (~L90) | Hands `$config` (parsed `config.json`) to the invariant pass. |
| 3 | `scripts/10-vscode-context-menu-fix/helpers/check.ps1` | `Invoke-Script10RepairInvariantCheck` (~L352) calls `Test-Check10RepairEnforced -Config $Config` (~L359) | Reads `$Config.repair.enforceInvariants`. |
| 4 | `scripts/10-vscode-context-menu-fix/helpers/check.ps1` | `Test-Check10RepairEnforced` (~L323-330) | Returns `$true` if the property is missing (default-on) or its boolean value otherwise. |
| 5 | `scripts/10-vscode-context-menu-fix/helpers/check.ps1` | Branch at ~L369-373 | If `$enforced` → log normal banner and let MISS bubble up to exit 1. If not → log `"Repair invariants: NOT enforced ..."` warning and downgrade misses to PASS. |

No other verb (`install`, `repair`, `rollback`, `verify`, `smoke`) reads this flag — they always act on the registry and rely on a follow-up `check` to interpret state.

### Decision tree: are invariants enforced or skipped?

```
         Start: .\run.ps1 -I 10 check
                    │
                    ▼
    ┌───────────────────────────────┐
    │ config.repair.enforceInvariants │
    │           exists?               │
    └───────────────┬───────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼ No                   ▼ Yes
   ┌─────────┐         ┌─────────────┐
   │ Default │         │ Read value  │
   │  true   │         └──────┬──────┘
   └────┬────┘                │
        │           ┌─────────┴─────────┐
        │           │                   │
        └──────────►▼ true            ▼ false
              ┌─────────────┐    ┌─────────────┐
              │  ENFORCED   │    │   SKIPPED   │
              │  [MISS] → 1 │    │ [WARN] → 0  │
              │  Repair     │    │ Report only │
              │  suggested  │    │ No repair   │
              │  in summary │    │  suggested  │
              └─────────────┘    └─────────────┘
```

**Key rule:** Script 10 has **only** `config.repair.enforceInvariants`. There is no `-SkipRepairInvariants` switch (that lives in Script 54's `verify` harness). The tree above is the complete picture for Script 10.

For comparison, Script 54's `verify` harness uses **both** flags. Here is the two-flag interaction matrix:

| `enforceInvariants` | `-SkipRepairInvariants` | Result |
|---|---|---|
| `true`  | **Not present** (default) | Invariants **enforced** — `[MISS]` → exit 1 |
| `true`  | **Present** (`-SkipRepairInvariants`) | Invariants **skipped** — warning only → exit 0 |
| `false` | **Not present** (default) | Invariants **skipped** — warning only → exit 0 |
| `false` | **Present** (`-SkipRepairInvariants`) | Invariants **skipped** — warning only → exit 0 |

**Script 10 simplified rule:** Since `-SkipRepairInvariants` does not exist here, only the first column matters. Set `enforceInvariants` to `false` if you want invariant violations to be warnings rather than failures.

| Verb | Reads `enforceInvariants`? | Notes |
|---|---|---|
| `check`                                | **Yes** | Only verb that consults the flag. |
| `install`, `repair`, `rollback`, `verify` | **No**  | These verbs always act; they do not read the flag. |

### Repair verb and `-Only` selectors

The `repair` verb supports targeted fixes via the `-Only` parameter:

```powershell
# Fix only invariant I2 (suppression values)
.\run.ps1 -I 10 repair -Only i2

# Fix only folder-target and background-target install issues
.\run.ps1 -I 10 repair -Only folder,background

# Fix only legacy duplicate keys
.\run.ps1 -I 10 repair -Only legacy
```

See `log-messages.json` for the full selector mapping.

## Naming Conventions

| Rule | Example |
|------|---------|
| All file names use **lowercase-hyphenated** (kebab-case) | `run.ps1`, `log-messages.json`, `config.json` |
| Never use PascalCase or camelCase for file names | ~~`Fix-VSCodeContextMenu.ps1`~~ → `run.ps1` |
| Folder names also use lowercase-hyphenated | `01-vscode-context-menu-fix`, `logs` |
| PowerShell functions inside scripts may use Verb-Noun PascalCase per PS convention | `Write-Log`, `Assert-Admin` |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Small focused functions | Each function does one thing; easy to test and debug |
| Main entry point at bottom | All functions defined first, single orchestration call |
| Verbose logging at every step | Every path, value, and decision is logged for debugging |
| External JSON configs | Easy to edit without touching script logic |
| Config is read-only at runtime | Scripts never mutate config.json -- keeps it declarative and git-friendly |
| .resolved/ for runtime state | Discovered paths, timestamps belong outside version control |
| Cache-first path detection | Checks .resolved/ before probing filesystem, skips if cached path is still valid |
| Env-var expansion at runtime | Supports both user & system installs portably |
| Auto-fallback path detection | Reduces user friction if wrong type is selected |
| Colored status badges | Clear visual feedback in the terminal |
| Plain ASCII banners | Avoids Unicode alignment bugs in terminals |
| Per-run log files | Debugging aid; cleaned each run to avoid clutter |
| -Confirm:$false on all registry ops | Prevents interactive prompts that hang the script |

## Install Keywords

| Keyword |
|---------|
| `vs-context-menu` |
| `vscontextmenu` |
| `context-menu` |
| `contextmenu` |

**Group shortcuts** (installs multiple scripts):

| Keyword | Scripts |
|---------|---------|
| `vscode+menu+settings` | 1, 10, 11 |
| `vms` | 1, 10, 11 |

```powershell
.\run.ps1 install vs-context-menu
.\run.ps1 install vscode+menu+settings
```


---

<!-- spec-footer:v1 -->

## Author

<div align="center">

### [Md. Alim Ul Karim](https://www.google.com/search?q=alim+ul+karim)

**[Creator & Lead Architect](https://alimkarim.com)** | [Chief Software Engineer](https://www.google.com/search?q=alim+ul+karim), [Riseup Asia LLC](https://riseup-asia.com)

</div>

A system architect with **20+ years** of professional software engineering experience across enterprise, fintech, and distributed systems. His technology stack spans **.NET/C# (18+ years)**, **JavaScript (10+ years)**, **TypeScript (6+ years)**, and **Golang (4+ years)**.

Recognized as a **top 1% talent at Crossover** and one of the top software architects globally. He is also the **Chief Software Engineer of [Riseup Asia LLC](https://riseup-asia.com/)** and maintains an active presence on **[Stack Overflow](https://stackoverflow.com/users/513511/md-alim-ul-karim)** (2,452+ reputation, 961K+ reached, member since 2010) and **LinkedIn** (12,500+ followers).

| | |
|---|---|
| **Website** | [alimkarim.com](https://alimkarim.com/) · [my.alimkarim.com](https://my.alimkarim.com/) |
| **LinkedIn** | [linkedin.com/in/alimkarim](https://linkedin.com/in/alimkarim) |
| **Stack Overflow** | [stackoverflow.com/users/513511/md-alim-ul-karim](https://stackoverflow.com/users/513511/md-alim-ul-karim) |
| **Google** | [Alim Ul Karim](https://www.google.com/search?q=Alim+Ul+Karim) |
| **Role** | Chief Software Engineer, [Riseup Asia LLC](https://riseup-asia.com) |

### Riseup Asia LLC — Top Software Company in Wyoming, USA

[Riseup Asia LLC](https://riseup-asia.com) is a **top-leading software company headquartered in Wyoming, USA**, specializing in building **enterprise-grade frameworks**, **research-based AI models**, and **distributed systems architecture**. The company follows a **"think before doing"** engineering philosophy — every solution is researched, validated, and architected before implementation begins.

**Core expertise includes:**

- 🏗️ **Framework Development** — Designing and shipping production-grade frameworks used across enterprise and fintech platforms
- 🧠 **Research-Based AI** — Inventing and deploying AI models grounded in rigorous research methodologies
- 🔬 **Think Before Doing** — A disciplined engineering culture where architecture, planning, and validation precede every line of code
- 🌐 **Distributed Systems** — Building scalable, resilient systems for global-scale applications

| | |
|---|---|
| **Website** | [riseup-asia.com](https://riseup-asia.com) |
| **Facebook** | [riseupasia.talent](https://www.facebook.com/riseupasia.talent/) |
| **LinkedIn** | [Riseup Asia](https://www.linkedin.com/company/105304484/) |
| **YouTube** | [@riseup-asia](https://www.youtube.com/@riseup-asia) |

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](../../LICENSE) file for the full text.

```
Copyright (c) 2026 Alim Ul Karim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

---

<div align="center">

*Part of the Dev Tools Setup Scripts toolkit — see the [spec writing guide](../00-spec-writing-guide/readme.md) for the full readme contract.*

</div>
