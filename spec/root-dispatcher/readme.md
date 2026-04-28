<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Spec — Root Dispatcher" width="128" height="128"/>

# Spec — Root Dispatcher

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Spec](https://img.shields.io/badge/Spec-Toolkit-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.70.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

# Spec: Root Dispatcher (run.ps1)

## Overview

The root-level `run.ps1` is the single entry point for running any numbered
script in the project. It handles git pull, log cleanup, environment flags,
and cache management before delegating to the target script.

When run with no parameters, it performs a git pull, displays the project
version from `scripts/version.json`, and shows help (available scripts and usage).

The `update` command self-updates the scripts (git pull) before upgrading
Chocolatey packages.

---

## One-Liner Install

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex
```

### Unix / macOS (Bash)

```bash
curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash
```

### What it does

1. Checks that `git` is available
2. Clones the repo to `~/scripts-fixer` (or `git pull` if it already exists)
3. **Windows:** Launches the interactive menu (`.\run.ps1 -d`)
4. **Unix:** Prints next-step instructions (`cd ~/scripts-fixer && pwsh ./run.ps1 -d`)

### Behaviour

| Condition | Action |
|-----------|--------|
| Git not installed | Prints error with install hint, exits |
| Folder doesn't exist | `git clone` into `~/scripts-fixer` |
| Folder already exists (`.git` present) | `git pull --ff-only` to update |
| Clone fails (network error) | Prints error, exits |
| Success (Windows) | `cd` into folder, runs `.\run.ps1 -d` |
| Success (Unix) | Prints `cd` + `pwsh` instructions |

The bootstrap scripts live at `install.ps1` (Windows) and `install.sh` (Unix) in the repo root.

---

## Usage

```powershell
.\run.ps1                              # Git pull + version header + show help
.\run.ps1 install vscode              # Install VS Code by bare command
.\run.ps1 install alldev,mysql        # Bare install command with comma-separated keywords
.\run.ps1 -Install vscode             # Install VS Code by keyword
.\run.ps1 -Install nodejs,pnpm        # Install Node.js + pnpm (combo)
.\run.ps1 -Install python             # Install Python + pip
.\run.ps1 -Install go,git,cpp         # Install Go, Git, and C++
.\run.ps1 -Install all-dev            # Interactive dev tools menu
.\run.ps1 update                      # Upgrade all Chocolatey packages
.\run.ps1 path D:\devtools            # Set default dev directory
.\run.ps1 path                        # Show current dev directory
.\run.ps1 path --reset                # Clear saved path, use smart detection
.\run.ps1 -d                          # Shortcut for -I 12 (interactive menu)
.\run.ps1 -I <number>                 # Run a script by ID
.\run.ps1 -I <number> -Merge          # Run with -Merge passed through
.\run.ps1 -I <number> -Clean          # Wipe .resolved/ cache, then run
.\run.ps1 -CleanOnly                  # Wipe .resolved/ cache and exit
.\run.ps1 -List                       # Show keyword table only
.\run.ps1 -Help                       # Show help (same as no params)
```

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `install` (positional command) | string | No | Bare command mode. When the first token is `install`, remaining positional values are treated as install keywords. |
| `-Install` | string[] | No | Keyword install mode. Supports comma-separated and space-separated values (e.g. `vscode`, `nodejs,pnpm`, `alldev mysql`). |
| `-d` | switch | No | Shortcut for `-I 12` -- launches the interactive dev tools menu |
| `-a` | switch | No | Shortcut for `-I 13` -- runs the audit scanner |
| `-v` | switch | No | Shortcut for `-I 1` -- installs VS Code |
| `-w` | switch | No | Shortcut for `-I 14` -- installs Winget |
| `-t` | switch | No | Shortcut for `-I 15` -- launches Windows tweaks utility |
| `-I` | int | No | Script number to run (resolved via `scripts/registry.json`) |
| `-Merge` | switch | No | Passed through to child script (used by script 02 for deep-merge) |
| `-Clean` | switch | No | Wipes all `.resolved/` data before running, forcing fresh detection |
| `-CleanOnly` | switch | No | Wipes all `.resolved/` data and exits without running any script |
| `-List` | switch | No | Prints the keyword-to-script-ID table and exits (compact reference) |
| `-Help` | switch | No | Show help (also shown when no params given) |

## Keyword Install System

The install system accepts human-friendly keywords that map to script IDs via
`scripts/shared/install-keywords.json`. Keywords are case-insensitive and can
be passed as comma-separated values, space-separated values, or a mix of both.

### Supported input styles

```powershell
.\run.ps1 install alldev,mysql
.\run.ps1 install alldev mysql
.\run.ps1 -Install alldev,mysql
.\run.ps1 -Install alldev mysql
```

### Keyword Mapping

| Keyword | Maps to | Script ID(s) |
|---------|---------|-------------|
| `vscode`, `vs-code`, `code` | VS Code | 01 |
| `choco`, `chocolatey` | Chocolatey | 02 |
| `nodejs`, `node`, `node.js` | Node.js + Yarn + Bun | 03 |
| `pnpm` | Node.js + pnpm | 03, 04 |
| `python`, `pip` | Python + pip | 05 |
| `go`, `golang` | Go | 06 |
| `git`, `gh`, `github-cli` | Git + LFS + GitHub CLI | 07 |
| `github-desktop` | GitHub Desktop | 08 |
| `cpp`, `c++`, `gcc`, `mingw` | C++ (MinGW-w64) | 09 |
| `context-menu` | VSCode context menu fix | 10 |
| `settings-sync` | VSCode settings sync | 11 |
| `all-dev`, `all` | Interactive dev tools menu | 12 |
| `audit` | Audit mode | 13 |
| `winget` | Winget | 14 |
| `tweaks`, `windows-tweaks` | Windows tweaks | 15 |
| `php` | PHP | 16 |
| `powershell`, `pwsh` | PowerShell (latest) | 17 |
| `mysql` | MySQL | 18 |
| `mariadb` | MariaDB | 19 |
| `postgresql`, `postgres`, `psql` | PostgreSQL | 20 |
| `sqlite` | SQLite + DB Browser for SQLite | 21 |
| `mongodb`, `mongo` | MongoDB | 22 |
| `couchdb` | CouchDB | 23 |
| `redis` | Redis | 24 |
| `cassandra` | Apache Cassandra | 25 |
| `neo4j` | Neo4j | 26 |
| `elasticsearch` | Elasticsearch | 27 |
| `duckdb` | DuckDB | 28 |
| `litedb` | LiteDB | 29 |
| `databases`, `db` | Interactive database installer menu | 30 |
| `pwsh-menu` | PowerShell context menu | 31 |
| `notepad++`, `npp` | NPP + Settings (install + sync) | 33 |
| `npp+settings` | NPP + Settings (explicit) | 33 |
| `npp-settings` | NPP Settings only | 33 |
| `install-npp` | Install NPP only | 33 |
| `sticky-notes`, `sticky` | Simple Sticky Notes | 34 |
| `gitmap`, `git-map` | GitMap CLI | 35 |
| `obs`, `obs+settings` | OBS + Settings (install + sync) | 36 |
| `obs-settings` | OBS Settings only | 36 |
| `install-obs` | Install OBS only | 36 |
| `wt`, `windows-terminal` | WT + Settings (install + sync) | 37 |
| `wt+settings` | WT + Settings (explicit) | 37 |
| `wt-settings` | WT Settings only | 37 |
| `install-wt` | Install WT only | 37 |

### Combo Examples

```powershell
.\run.ps1 -Install nodejs,pnpm           # Installs scripts 03, 04 in order
.\run.ps1 -Install go,git,cpp            # Installs scripts 06, 07, 09 in order
.\run.ps1 -Install python,php            # Installs scripts 05, 16 in order
.\run.ps1 -Install vscode,nodejs,git     # Installs scripts 01, 03, 07 in order
.\run.ps1 install alldev,mysql           # Runs script 12, then 18
```

Duplicate IDs are automatically de-duplicated and sorted by ID for logical execution order.

## Examples

```powershell
.\run.ps1                   # Pull, show help
.\run.ps1 install vscode    # Pull, then install VS Code
.\run.ps1 -Install vscode   # Pull, then install VS Code
.\run.ps1 -d                # Pull, then run interactive dev tools menu (script 12)
.\run.ps1 -I 1              # Pull, then run scripts/01-install-vscode/run.ps1
.\run.ps1 -I 2 -Merge       # Pull, then run scripts/02-install-package-managers/run.ps1 with merge
.\run.ps1 -I 12             # Same as -d (interactive menu)
.\run.ps1 -I 1 -Clean       # Wipe cache, pull, then run scripts/01-install-vscode/run.ps1
.\run.ps1 -CleanOnly        # Wipe all cached resolved data
```

## Execution Flow

### No parameters
1. Clear stale `$env:SCRIPTS_ROOT_RUN`
2. Git pull (update scripts)
3. Display version header (`Scripts Fixer vX.Y.Z`)
4. Show help menu
5. Exit

### Standard mode (-I)
1. If `-List`: print keyword table and exit
2. If `-Help`: show help (with version header) and exit
3. If `-CleanOnly`: wipe `.resolved/` contents and exit immediately
4. If `-Clean`: wipe `.resolved/` contents, then continue
5. Dot-source `scripts/shared/git-pull.ps1`
6. Run `Invoke-GitPull` from repo root
7. Set `$env:SCRIPTS_ROOT_RUN = "1"`
8. Expand shortcuts (`-d` -> 12, `-v` -> 1, etc.)
9. Resolve script via `Invoke-ScriptById` (registry lookup + logs cleanup)
10. Delegate to the child script
11. Clean up `$env:SCRIPTS_ROOT_RUN`

### Update mode (`update`)
1. Display version header (`Scripts Fixer vX.Y.Z`)
2. Git pull (self-update scripts to latest)
3. Run `Invoke-ChocoUpdate` (list packages, confirm, `choco upgrade all -y`)
4. Exit

### Path mode (`path`)
1. Display version header (`Scripts Fixer vX.Y.Z`)
2. If no argument: show current saved path (or "smart detection" message)
3. If `--reset`: remove `scripts/dev-path.json`, confirm reset
4. If path provided: validate format (`X:\...`), save to `scripts/dev-path.json`, confirm
5. Exit

**Storage:** The saved path is persisted in `scripts/dev-path.json` as `{"path": "D:\\devtools"}`.

**Priority chain** for dev directory resolution (in `Resolve-DevDir`):
1. `-Path` parameter (per-run override)
2. `$env:DEV_DIR` (set by orchestrator)
3. **Saved path** from `scripts/dev-path.json` (set via `.\run.ps1 path`)
4. Config override value
5. Smart drive detection (E: > D: > best drive > prompt)
6. Config default value (legacy fallback)

### Keyword mode (`install` or `-Install`)
1. Steps 1-7 same as standard mode
2. Normalize input from either bare `install` or named `-Install`
3. Parse comma-separated and/or space-separated keywords via `Resolve-InstallKeywords`
4. Look up each keyword in `scripts/shared/install-keywords.json`
5. De-duplicate and sort script IDs
6. Run each script in sequence via `Invoke-ScriptById`
7. Show summary (success/fail counts)
8. Clean up `$env:SCRIPTS_ROOT_RUN`

## Version Header

The version is read from `scripts/version.json` (single source of truth) by
`Get-ScriptVersion` and displayed via `Show-VersionHeader`. It prints:

```
  Scripts Fixer v0.8.1
```

Shown automatically on:
- No-params run (before help menu)
- `update` command (before git pull + choco upgrade)
- `-Help` flag

## Script Resolution

The dispatcher resolves script IDs to folders using `Invoke-ScriptById`:

### Primary: Registry lookup (`scripts/registry.json`)

A flat JSON file maps zero-padded IDs to exact folder names:

```json
{
  "scripts": {
    "01": "01-install-vscode",
    "04": "04-install-pnpm"
  }
}
```

### Fallback: Glob matching

If `registry.json` is missing, the dispatcher falls back to globbing
`scripts/<NN>-*` and filtering to directories that contain a `run.ps1`.

### Resolution errors

| Condition | Behaviour |
|-----------|-----------|
| Registry entry exists but folder is missing on disk | `[ FAIL ]` with "No script folder found for ID NN" |
| Registry missing + no glob match | `[ FAIL ]` with "No script folder found for ID NN" |
| Folder found but no `run.ps1` inside | `[ FAIL ]` with "run.ps1 not found in <folder>" |

## Environment Variables

| Variable | Set by | Purpose |
|----------|--------|---------|
| `$env:SCRIPTS_ROOT_RUN` | Root dispatcher | Set to `"1"` before delegating; child scripts check this to skip redundant git pull |

## .resolved/ Cache Management

| Flag | Requires -I | Effect |
|------|-------------|--------|
| `-Clean` | Yes | Wipe cache, then run script (forces fresh detection) |
| `-CleanOnly` | No | Wipe cache and exit |
| Neither | Yes | Run script using existing cache |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Version header from `version.json` | Single source of truth; user sees current version immediately |
| Self-update on `update` command | Scripts are always up to date before upgrading Chocolatey packages |
| Keyword install system | Human-friendly names avoid needing to memorize script IDs |
| Bare `install` support | Matches the user's natural CLI usage |
| External keyword JSON | Easy to add new keywords without editing run.ps1 |
| Auto-chaining (e.g. pnpm -> 03,04) | Dependencies are resolved automatically |
| De-duplication + sorting | Prevents running the same script twice; ensures logical order |
| Registry-based resolution | Exact folder names avoid glob collisions |
| Glob fallback | Backwards-compatible for repos without `registry.json` |
| No params = git pull + help | User discovers available scripts on first run |
| Refactored into `Invoke-ScriptById` | Shared by both `-I` and install modes, reduces duplication |


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
