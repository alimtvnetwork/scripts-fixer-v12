<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Script 10 — Vscode Context Menu Fix" width="128" height="128"/>

# Script 10 — Vscode Context Menu Fix

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-10-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.70.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

## Overview

Restores the **"Open with Code"** entry to the Windows right-click menu on three targets:

| Target | Where it appears |
|--------|------------------|
| `*` (file) | Right-click any file |
| `Directory` | Right-click any folder |
| `Directory\Background` | Right-click empty space inside a folder |

Works for both **VS Code Stable** and **VS Code Insiders**, in either user-install (`%LOCALAPPDATA%`) or system-install (`C:\Program Files`) layouts. The path, label, and edition list are all driven by [`config.json`](./config.json) — no code edits required.

> **Requires Administrator.** Writes to `HKEY_CLASSES_ROOT`. The script aborts with a clear message if launched without elevation.

## Copy-paste usage

Run from the repo root in an **elevated PowerShell** session:

```powershell
# Install: register all three context-menu entries (file + folder + background)
.\run.ps1 -I 10 install

# Uninstall: remove every entry the script created (both Stable and Insiders)
.\run.ps1 -I 10 uninstall

# Show built-in help
.\run.ps1 -I 10 -- -Help
```

After install, right-click a file/folder/empty space — you should see **"Open with Code"** (and **"Open with Code - Insiders"** if Insiders is installed).

## Expected registry keys

The script writes to `HKEY_CLASSES_ROOT` (`HKCR`) under each target. For **VS Code Stable** the keys are:

| Target | Registry path |
|--------|---------------|
| File | `HKCR\*\shell\VSCode` |
| Folder | `HKCR\Directory\shell\VSCode` |
| Background | `HKCR\Directory\Background\shell\VSCode` |

For **VS Code Insiders** the suffix becomes `VSCodeInsiders`, e.g. `HKCR\Directory\shell\VSCodeInsiders`.

Each key contains:

| Value | Type | Example |
|-------|------|---------|
| `(Default)` | `REG_SZ` | `Open with Code` |
| `Icon` | `REG_SZ` | `"C:\Users\<you>\AppData\Local\Programs\Microsoft VS Code\Code.exe"` |

And a `\command` subkey:

| Value | Type | Example |
|-------|------|---------|
| `(Default)` | `REG_SZ` | `"...\Code.exe" "%1"` (file) or `"...\Code.exe" "%V"` (folder/background) |

You can verify a single key from PowerShell:

```powershell
reg query "HKCR\Directory\shell\VSCode" /s
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `This script must be run as Administrator.` | Re-launch PowerShell with **"Run as administrator"**, then re-run the command. |
| `No valid VS Code executable found` | Edit [`config.json`](./config.json) → `editions.stable.vscodePath.user` (or `.system`) to point at your actual `Code.exe`. The script tries the configured `installationType` first, then falls back to the other. |
| Menu entry missing on Windows 11 | Win11 hides classic entries behind **"Show more options"** (or `Shift + F10`). To force the classic menu permanently, see Script 52 (`vscode-folder-repair`) or the `{86ca1aa0-…}` workaround. |
| Entry appears but does nothing | The cached `Code.exe` path is stale. Delete `.resolved/10-vscode-context-menu-fix/` at the repo root and re-run install. |
| `Unknown edition '<name>'` warning | `config.json` → `enabledEditions` lists an edition that isn't defined under `editions`. Remove the bad entry or add a matching definition. |
| Want to undo everything | `.\run.ps1 -I 10 uninstall` — removes all six keys (file/folder/background × Stable/Insiders) that the script created. |
| Need a folder-only repair (keep file/background untouched) | Use **Script 52** (`vscode-folder-repair`) instead — it has a dedicated `rollback.ps1` for the inverse operation. |

Logs for every run are written under `logs/10-vscode-context-menu-fix/` with a timestamped filename and a `ok`/`fail` status suffix — attach the latest one when reporting issues.

## Repair invariants & opt-out behavior

The `check` verb verifies three repair invariants in addition to the
install-state check:

| # | Invariant |
|---|---|
| 1 | `HKCR\*\shell\<Name>` (file-target) is **absent** |
| 2 | `directory` + `background` keys carry **no suppression values** (`ProgrammaticAccessOnly`, `AppliesTo`, `NoWorkingDirectory`, `LegacyDisable`, `CommandFlags`) |
| 3 | No legacy duplicate child keys (allow-list in `config.repair.legacyNames`) under any of the three shell parents |

#### Opt-out: `config.repair.enforceInvariants` (Script 10 has no `verify` harness)

Script 10 exposes **only the config flag** — there is no `-SkipRepairInvariants` switch
because there is no `verify` test harness here (that lives in Script 54). Behavior is:

| `enforceInvariants` | What `.\run.ps1 -I 10 check` does on an invariant failure |
|---|---|
| `true` (default)   | Prints `[MISS]` with `Path` / `Items` / `Why` / `Fix` lines, includes the miss in the action summary, and exits **1**. |
| `false`            | Prints the same diagnostic but **downgrades the miss to a warning**: it is added to the PASS total, no entry is added to the action summary for that invariant, and the run still exits **0**. The install-state check (Cases 1–3 of "is the entry registered?") is **always** enforced regardless of this flag. |

| Verb | Reads `enforceInvariants`? | Notes |
|---|---|---|
| `check`                                | **Yes** | Only verb that consults the flag. |
| `install` (default) / `uninstall` / `repair` / `rollback` | No | These verbs only *write* state; run `check` afterwards to verify. |

When to flip the flag to `false`: a machine where you *intentionally* keep
`HKCR\*\shell\<Name>` (i.e. you want the menu on individual files too).
The install-state portion of `check` will still catch missing/broken entries,
so you don't lose the rest of the safety net.

The semantics match Script 54's `check`. The only difference is that
Script 54 *also* has `-SkipRepairInvariants` for its `verify` test harness;
see [Script 54's readme](../54-vscode-menu-installer/readme.md#opt-out-matrix-configrepairenforceinvariants---skiprepairinvariants)
for the full two-flag interaction matrix.

#### CI-friendly granular exit codes (`-ExitCodeMap`)

`check` accepts an opt-in `-ExitCodeMap` switch that maps specific failure
types to distinct exit codes so CI can branch on the cause without parsing
logs. **Default behavior is unchanged** (0 = green, 1 = any miss) so
existing pipelines do not break.

| Code | Meaning |
|---|---|
| **0**  | All green |
| **10** | Only **install-state** failures (missing leaf, wrong `(Default)` label, missing `Icon`, broken `\command`, exe not on disk) |
| **20** | Only invariant **#1**: file-target key (`HKCR\*\shell\<Name>`) is **STILL PRESENT** |
| **21** | Only invariant **#2**: **suppression values** present on `directory` / `background` |
| **22** | Only invariant **#3**: **legacy duplicate** child keys present |
| **30** | **Multiple invariant categories** failed (any 2+ of 20/21/22) |
| **40** | **Mixed**: install-state failures **and** invariant failures |
| **1**  | Catch-all fallback (should not occur in practice) |

Same code map as Script 54 — pipelines that gate both scripts can share one
`case $?` block. Script 10 has no `verify` harness, so `-ExitCodeMap`
applies only to the `check` verb here.

Usage:

```powershell
.\run.ps1 -I 10 check -ExitCodeMap
```

Sample CI branching (Bash on a Windows runner):

```bash
pwsh -File ./run.ps1 -I 10 check -ExitCodeMap
case $? in
  0)              echo "OK" ;;
  10)             echo "Install state broken -> run: .\run.ps1 -I 10 install"  ; exit 1 ;;
  20|21|22|30)    echo "Repair invariant violated -> run: .\run.ps1 -I 10 repair" ; exit 1 ;;
  40)             echo "Both install + invariants broken -> install then repair" ; exit 1 ;;
  *)              echo "Unexpected: $?"                                          ; exit 1 ;;
esac
```

Grouping rules are the same as Script 54: any install-state miss combined
with any invariant miss collapses to **40**; otherwise two-or-more invariant
categories collapse to **30**; otherwise the single offending invariant code
(20/21/22) is returned.

## File layout

| File | Purpose |
|------|---------|
| `run.ps1` | Entry point dispatched by the root `run.ps1`. Handles `install` (default) and `uninstall`. |
| `config.json` | External config: VS Code paths, registry targets, label, edition list, install-type preference. |
| `log-messages.json` | All user-facing strings (kept out of code so they can be localized/edited without touching logic). |
| `helpers/registry.ps1` | Registry write/verify/uninstall helpers + `Invoke-Edition` dispatcher. |
| `issues.md` | Known issues / open questions for this script. |

## See also

- [Full spec](../../spec/10-vscode-context-menu-fix/readme.md)
- [Script 52 — folder-only repair + rollback](../52-vscode-folder-repair/readme.md)
- [Script 54 — modern menu installer](../54-vscode-menu-installer/readme.md)
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
