<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Script 54 — Vscode Menu Installer" width="128" height="128"/>

# Script 54 — Vscode Menu Installer

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-54-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.70.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

## Overview

Implementation folder for **Script 54 — Vscode Menu Installer**. The full design contract lives in the spec.

## Quick start

```powershell
# From repo root
.\run.ps1 -I 54 install

# Install for the current user only (no admin needed)
.\run.ps1 -I 54 install -Scope CurrentUser

# Install machine-wide (requires elevated PowerShell)
.\run.ps1 -I 54 install -Scope AllUsers

# Default is -Scope Auto: AllUsers when elevated, else CurrentUser.
# Same flag applies to uninstall and repair so the right hive is targeted.
.\run.ps1 -I 54 uninstall -Scope CurrentUser
.\run.ps1 -I 54 repair    -Scope AllUsers
```

### Scope reference

| `-Scope`      | Hive written                                 | Admin? |
|---------------|----------------------------------------------|--------|
| `Auto` (default) | AllUsers if elevated, else CurrentUser    | as needed |
| `CurrentUser` | `HKCU\Software\Classes\...`                  | no     |
| `AllUsers`    | `HKEY_CLASSES_ROOT\...` (HKLM under the hood)| **yes** |

If `-Scope AllUsers` is requested without admin rights the script
**fails fast** with a clear "re-run elevated, or pass -Scope CurrentUser"
message — it never silently downgrades.

## Layout

| File | Purpose |
|------|---------|
| `run.ps1` | Entry point dispatched by the root `run.ps1`. |
| `config.json` | External config (paths, toggles, edition list). |
| `log-messages.json` | All user-facing messages (kept out of code). |
| `helpers/` | Internal PowerShell helper modules. |
| `.audit/` | Auto-created at runtime. One JSONL file per install/uninstall run, recording every registry key added or removed (timestamped, gitignored). |

## Rollback & pre-install snapshot

Every `install` run automatically exports the current state of every
target registry key BEFORE writing anything new:

```
.audit/snapshots/snapshot-20260424-101523.reg
```

The snapshot is a single `reg.exe export`-format file containing one
block per target key (file / folder / background) per enabled edition.
Keys that did not exist at snapshot time are recorded as ASCII comment
placeholders so you can see exactly what was new vs. overwritten.

Two cleanup paths:

| Verb | What it does |
|---|---|
| `.\\run.ps1 -I 54 uninstall` | Surgical delete. Removes ONLY the keys listed in `config.json::registryPaths`. Never touches siblings. |
| `.\\run.ps1 -I 54 rollback` | Same surgical delete, plus prints the path of the latest snapshot so you can manually `reg.exe import` it to restore any third-party "Open with Code" entries that pre-existed. |

Manual full restore (brings back exactly what was there before the most recent install):

```powershell
reg.exe import .audit\snapshots\snapshot-<yyyyMMdd-HHmmss>.reg
```

## Repair (folders YES, files NO)

If the menu shows up in the wrong places (e.g. on individual files) or
is hidden by suppression hints a previous tool wrote, run repair:

```powershell
.\run.ps1 -I 54 repair                  # both editions
.\run.ps1 -I 54 repair -Edition stable  # just stable
```

Repair, per edition, performs four passes:

| # | Pass | Effect |
|---|------|--------|
| 1 | Ensure | (Re)writes `HKCR\Directory\shell\<Name>` and `HKCR\Directory\Background\shell\<Name>` so the entry shows on folder right-click + folder-background right-click. |
| 2 | Drop | Deletes `HKCR\*\shell\<Name>` so the entry no longer appears when right-clicking individual files. |
| 3 | Strip | Removes suppression values from the surviving keys: `ProgrammaticAccessOnly`, `AppliesTo`, `NoWorkingDirectory`, `LegacyDisable`, `CommandFlags`. |
| 4 | Sweep | Deletes legacy duplicate keys (e.g. `VSCode2`, `OpenWithCode`) under each shell parent. **Allow-list only** -- names live in `config.json::repair.legacyNames`; nothing outside that list is touched. |

Every change is captured in the `.audit/` JSONL log AND in a pre-repair
`.reg` snapshot under `.audit/snapshots/`, so you can manually
`reg.exe import` to restore the prior state if needed.

### Verifying the repair stuck (CI-friendly)

The `check` command and the `verify` test harness both enforce the four
repair invariants. Use them as a CI gate:

```powershell
.\run.ps1 -I 54 check               # quick read-only registry check
.\run.ps1 -I 54 verify              # full test harness (Cases 1-8)
```

Invariants (each becomes one or more `[MISS]` line + non-zero exit if
violated):

| Case | Invariant |
|---|---|
| 6 | `HKCR\*\shell\<Name>` (file-target) is **absent** |
| 7 | `directory` + `background` keys carry **no suppression values** (`ProgrammaticAccessOnly`, `AppliesTo`, `NoWorkingDirectory`, `LegacyDisable`, `CommandFlags`) |
| 8 | No legacy duplicate child keys (allow-list in `config.repair.legacyNames`) under any of the three shell parents |

Set `config.repair.enforceInvariants = false` to opt out (or pass
`-SkipRepairInvariants` to the harness). Default is enforced.

#### Opt-out matrix: `config.repair.enforceInvariants` × `-SkipRepairInvariants`

The two switches operate at different layers and **do not** override each
other. Read them as: the config flag controls what `check` does, the
harness flag controls what `verify` does.

| Layer | Reads `config.repair.enforceInvariants`? | Reads `-SkipRepairInvariants`? | Behavior when invariant fails |
|---|---|---|---|
| `.\run.ps1 -I 54 check`  | **Yes** | No (switch is ignored)   | `true` → `[MISS]` + exit 1. `false` → `[MISS]` is downgraded to a warning, included in the PASS total, and the run still exits 0. |
| `.\run.ps1 -I 54 verify` | **Yes** (Cases 6/7/8 read it internally) | **Yes** | If `-SkipRepairInvariants` is passed, Cases 6/7/8 are **not run at all** (skipped before the config flag is consulted). Otherwise the config flag decides PASS/FAIL exactly as `check` does. |
| `repair` / `install` / `uninstall` / `rollback` | No | No | These verbs only *write* state; they never enforce invariants on themselves. Run `check` afterwards to verify. |

Concrete combinations:

| `enforceInvariants` | `-SkipRepairInvariants` | `check` exit | `verify` Cases 6/7/8 |
|---|---|---|---|
| `true`  (default)   | not passed (default)    | 1 if any invariant fails, 0 otherwise | run, fail the suite if any invariant fails |
| `true`              | passed                  | 1 if any invariant fails, 0 otherwise | **not run**; suite pass/fail driven by Cases 1–5 only |
| `false`             | not passed              | 0 always (invariant misses become warnings) | run, but each invariant miss is a **warning** that does not fail the case |
| `false`             | passed                  | 0 always (invariant misses become warnings) | **not run** |

When to flip the config flag to `false`: a machine where you *intentionally*
keep the file-target entry (e.g. you actually want "Open with Code" on
individual files). When to pass `-SkipRepairInvariants`: short-circuit a CI
run after a known-clean install while the underlying registry hasn't been
repaired yet.

#### CI-friendly granular exit codes (`-ExitCodeMap`)

Both `check` and `verify` accept an opt-in `-ExitCodeMap` switch that maps
specific failure types to distinct exit codes so CI can branch on the cause
without parsing logs. **Default behavior is unchanged** (0 = green, 1 = any
miss, 2 = pre-flight) so existing pipelines do not break.

| Code | Meaning |
|---|---|
| **0**  | All green |
| **2**  | Pre-flight failed (config missing, no enabled editions, etc.) — `verify` only |
| **10** | Only **install-state** failures (Cases 1–5: missing leaf, wrong label, broken `\command`, exe not on disk, etc.) |
| **20** | Only invariant **#1**: file-target key (`HKCR\*\shell\<Name>`) is **STILL PRESENT** |
| **21** | Only invariant **#2**: **suppression values** present on `directory` / `background` (`ProgrammaticAccessOnly`, `AppliesTo`, `NoWorkingDirectory`, `LegacyDisable`, `CommandFlags`) |
| **22** | Only invariant **#3**: **legacy duplicate** child keys present (allow-list in `config.repair.legacyNames`) |
| **30** | **Multiple invariant categories** failed (any 2+ of 20/21/22) — registry needs broader cleanup |
| **40** | **Mixed**: install-state failures **and** invariant failures — re-install then repair |
| **1**  | Catch-all fallback (only if the failure can't be classified — should not occur in practice) |

Usage:

```powershell
.\run.ps1 -I 54 check  -ExitCodeMap   # opt-in for the check verb
.\run.ps1 -I 54 verify -ExitCodeMap   # opt-in for the test harness
```

Sample CI branching (Bash on a Windows runner):

```bash
pwsh -File ./run.ps1 -I 54 check -ExitCodeMap
case $? in
  0)              echo "OK" ;;
  10)             echo "Install state broken -> run: .\run.ps1 -I 54 install"  ; exit 1 ;;
  20|21|22|30)    echo "Repair invariant violated -> run: .\run.ps1 -I 54 repair" ; exit 1 ;;
  40)             echo "Both install + invariants broken -> install then repair"  ; exit 1 ;;
  *)              echo "Unexpected: $?"                                         ; exit 1 ;;
esac
```

The grouping rules: if there is at least one install-state failure **and**
any invariant failure, the code is **40** (mixed) — not the most-specific
invariant code. If there are **no** install-state failures but **two or
more** invariant categories fail, the code is **30** (multi-invariant). A
single invariant category failing in isolation collapses to its own code
(20/21/22), which is what CI usually wants to grep on.

## Audit log

Every install and uninstall run writes a timestamped audit file to
`scripts/54-vscode-menu-installer/.audit/`:

```
.audit/audit-install-20260424-101523.jsonl
.audit/audit-uninstall-20260424-101742.jsonl
```

Each line is one JSON record. Operations recorded:

| `operation` | When |
|---|---|
| `session-start` | First line of every file -- captures host / user / pid. |
| `add` | A registry key + values were just written. Includes `(Default)`, `Icon`, and `command`. |
| `remove` | A key that existed was deleted. |
| `skip-absent` | Uninstall asked to remove a key that was already gone. |
| `fail` | Write or delete attempt failed; `reason` field has the error. |

Useful queries:

```powershell
# What did the last install touch?
Get-Content (Get-ChildItem .audit\audit-install-*.jsonl | Sort LastWriteTime | Select -Last 1) |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object operation -eq 'add' |
    Select-Object ts, edition, target, regPath

# Diff two runs
code --diff .audit\audit-install-<old>.jsonl .audit\audit-install-<new>.jsonl
```

## See also

- [Full spec](../../spec/54-vscode-menu-installer/readme.md)
- [Spec writing guide](../../spec/00-spec-writing-guide/readme.md)
- [Changelog](../../changelog.md)


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

*Part of the Dev Tools Setup Scripts toolkit — see the [spec writing guide](../../spec/00-spec-writing-guide/readme.md) for the full readme contract.*

</div>
