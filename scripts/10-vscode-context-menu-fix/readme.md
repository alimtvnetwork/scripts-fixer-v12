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

##### Where the flag is evaluated (code path)

Trace from CLI to the boolean read, so it is unambiguous which line in `run.ps1`
triggers the evaluation:

1. `run.ps1` (~L84) — `if ($cmdLower -eq 'check') { ... }` enters the check branch.
2. `run.ps1` (~L90) — calls `Invoke-Script10RepairInvariantCheck -Config $config -EditionFilter $Edition`.
3. `helpers/check.ps1` (~L352) — `Invoke-Script10RepairInvariantCheck` opens with
   `$enforced = Test-Check10RepairEnforced -Config $Config` (~L359).
4. `helpers/check.ps1` (~L323-330) — `Test-Check10RepairEnforced` reads
   `$Config.repair.enforceInvariants` (returns `$true` if the property is absent).
5. `helpers/check.ps1` (~L369-373) — branches on `$enforced`: enforced path keeps
   `[MISS]` rows that drive exit 1; non-enforced path emits the
   `"Repair invariants: NOT enforced ..."` warning and reclassifies misses as PASS.

The flag is **never** read from `run.ps1` directly; `run.ps1` only forwards
`$config` to the helper. Every other verb skips this code path entirely.

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

## Targeted repair (`repair -Only <selectors>`)

By default `repair` runs all four phases (ensure folder+background, drop
file-target, strip suppression values, sweep legacy duplicates). When
`check` reports a miss in only one bucket, you can re-run a narrower
repair with `-Only` and skip the rest:

| Selector | Phases run |
|---|---|
| `install` | Ensure folder + background entries (re-asserts `(Default)` / `Icon` / `\command`). Targets every INSTALL-STATE miss reported by `check`. |
| `invariant` | Drop file-target + strip suppression + sweep legacy duplicates. Targets every I1/I2/I3 miss. |
| `file-target` (alias `i1`) | Phase 2 only. Deletes `HKCR\*\shell\<Name>`. |
| `suppression` (alias `i2`) | Phase 3 only. Strips `ProgrammaticAccessOnly` / `AppliesTo` / `NoWorkingDirectory` / `LegacyDisable` / `CommandFlags` from directory + background. |
| `legacy` (alias `i3`) | Phase 4 only. Sweeps allow-listed `legacyNames` under each shell parent. |
| `folder` (alias `directory`) | Phases 1 + 3 limited to the **directory** target. |
| `background` | Phases 1 + 3 limited to the **background** target. |
| `all` *(default)* | Every phase, every target. |

Selectors are case-insensitive. Pass multiple either as repeated values
or comma-separated, and they are unioned:

```powershell
# Only fix invariant misses (don't re-write the folder/background entries):
.\run.ps1 -I 10 repair -Only invariant

# Strip suppression values AND sweep legacy duplicates, nothing else:
.\run.ps1 -I 10 repair -Only suppression,legacy

# Re-write only the FOLDER target for one edition (skips background entirely):
.\run.ps1 -I 10 repair -Only folder -Edition stable

# Drop the file-target only (use after `check` reported [I1-FILE-TARGET]):
.\run.ps1 -I 10 repair -Only i1
```

Unknown selectors abort the run BEFORE any registry write and log the
exact bad token, the file path that rejected it, and the full list of
valid selectors -- so you never get a partial repair from a typo.

Selector-to-`check`-bucket mapping for quick triage from a CI exit code
(`check -ExitCodeMap`):

| Exit code | Run this `repair -Only ...` |
|---|---|
| `10` (install-state) | `install` |
| `20` (file-target)   | `i1` (or `file-target`) |
| `21` (suppression)   | `i2` (or `suppression`) |
| `22` (legacy)        | `i3` (or `legacy`) |
| `30` (multi-invariant) | `invariant` |
| `40` (mixed)         | `install,invariant` (or just omit `-Only` for full repair) |

## Smoke test (`smoke` verb)

End-to-end smoke harness that runs `install` then `check` back-to-back and
asserts the registry ends up green for **both** the folder and file context
menu cases. Lives at [`tests/smoke-install-check.ps1`](./tests/smoke-install-check.ps1)
and is dispatched by the `smoke` verb on `run.ps1`.

| Step | What it does | Pass criterion |
|---|---|---|
| 1 | `run.ps1 install` (one or all enabled editions) | `$LASTEXITCODE -eq 0` |
| 2 | `run.ps1 check -ExitCodeMap`                    | `$LASTEXITCODE -eq 0` (folder+background present, file-target absent, no suppression, no legacy) |
| 3 *(opt-in)* | `reg.exe add HKCR\*\shell\<Name>` then `check -ExitCodeMap`  | `$LASTEXITCODE -eq 20` (file-target present bucket) |
| 4 *(opt-in)* | `run.ps1 repair -Edition <name>`                 | `$LASTEXITCODE -eq 0` |
| 5 *(opt-in)* | `run.ps1 check -ExitCodeMap -Edition <name>`     | `$LASTEXITCODE -eq 0` (state restored) |

Steps 3–5 only run when you pass `-IncludeFileTargetNegativeCase`. They
verify the **negative path**: that `check` actually distinguishes between a
green install and a deliberately-broken file-target invariant, which proves
the `-ExitCodeMap` bucket scheme works against a real registry write rather
than a mock.

```powershell
# Quick smoke (install + check, all editions):
.\run.ps1 -I 10 smoke

# Single edition + negative case (writes HKCR\*\shell\<Name> then cleans up):
.\run.ps1 -I 10 smoke -Edition stable -IncludeFileTargetNegativeCase

# CI / log-friendly:
.\run.ps1 -I 10 smoke -NoColor

# Preview the plan without touching the registry (no admin needed):
.\run.ps1 -I 10 smoke -DryRun

# Skip the install step (assume a previous run already installed):
.\run.ps1 -I 10 smoke -SkipInstall
```

Smoke exit codes: `0` = all assertions passed, `1` = at least one failed,
`2` = pre-flight failed (no admin, missing `run.ps1`, edition filter
matched nothing, etc.). The harness prints a per-step `[PASS]`/`[FAIL]`
line plus a `Failures:` block with the exact reg path of any miss so a
CI log alone is enough to diagnose.

## Interactive check prompts

`check` is read-only by default. Add one of the following flags and the
verb will pause AFTER printing the action summary and offer to run the
repair commands directly. CI behaviour is preserved: prompts are
suppressed when `-ExitCodeMap` is on, and when stdin is redirected the
harness logs a one-line warning and skips the prompt loop instead of
silently blocking.

| Flag | Meaning |
|------|---------|
| `-Interactive`   | Single one-shot prompt for the consolidated repair (default mode). |
| `-PromptEach`    | Prompt **per MISS block** with the smallest `repair -Only ...` command that fixes that one finding. |
| `-PromptOneShot` | Force the one-shot prompt; combine with `-PromptEach` for both (per-MISS first, then a final one-shot for whatever was declined). |
| `-AssumeYes`     | Skip every prompt and auto-confirm. The only safe way to combine prompts with `-ExitCodeMap` (CI). |
| `-DryRun`        | Print every command that **would** run; never invoke `repair`. Pairs with any of the above. |

Answer keys at each prompt:

- `y` -- run this fix
- `n` -- skip this one (default on bare ENTER)
- `a` -- yes-to-all-remaining (acts as `-AssumeYes` from this point on)
- `q` -- quit prompts (skip every remaining MISS without exiting `check`)

Per-MISS commands are derived from the invariant code, so each `y`
invokes the smallest possible repair:

| MISS invariant code | Command offered |
|---------------------|-----------------|
| `INSTALL-STATE` (target=`directory`)  | `repair -Edition X -Only folder` |
| `INSTALL-STATE` (target=`background`) | `repair -Edition X -Only background` |
| `INSTALL-STATE` (target=`file`)       | `repair -Edition X -Only install` |
| `I1-FILE-TARGET`                      | `repair -Edition X -Only i1` |
| `I2-SUPPRESSION`                      | `repair -Edition X -Only i2` |
| `I3-LEGACY-DUP`                       | `repair -Edition X -Only i3` |

```powershell
# Single confirm for the full one-shot repair:
.\run.ps1 -I 10 check -Interactive

# Walk through every MISS, choose surgically:
.\run.ps1 -I 10 check -PromptEach

# Per-MISS prompts AND a final fallback one-shot for whatever you skipped:
.\run.ps1 -I 10 check -PromptEach -PromptOneShot

# See what would run without writing anything:
.\run.ps1 -I 10 check -PromptEach -DryRun

# CI auto-fix (only honoured because -AssumeYes accompanies -ExitCodeMap):
.\run.ps1 -I 10 check -ExitCodeMap -Interactive -AssumeYes
```

The interactive block runs **after** the action summary and **before**
the exit-code dispatch, so the same exit-code semantics apply on the way
out: `0` if every miss was resolved (or there were none), `1`/granular
code otherwise -- the prompts only change what happens between the two.

## Verified rollback (`rollback` verb)

`rollback` no longer prints a hint and shells out to `uninstall`. It now
wraps the surgical removal with a five-phase verification that proves the
context-menu state was actually restored:

| Phase | What it does | Mutates registry? |
|-------|--------------|-------------------|
| 1. Pre-rollback snapshot | Calls `New-PreRollbackSnapshot` -- runs the same `reg.exe export` as a pre-install snapshot, then renames the file with a `pre-rollback-` prefix under `.audit/snapshots/`. | No (read-only export) |
| 2. Invariant baseline | Runs both check passes (`Invoke-Script10MenuCheck` + `Invoke-Script10RepairInvariantCheck`) and freezes the MISS action collector keyed by `(invariantCode, regPath)`. | No |
| 3. Surgical uninstall | The pre-existing `Uninstall-VsCodeContextMenu` removes only the keys we created. | Yes |
| 4. Post-rollback re-check | Re-runs the same two check passes against the now-mutated registry and freezes the action collector again. | No |
| 5. Verification report | Diffs the BEFORE and AFTER frozen snapshots and prints a `RESOLVED` / `PERSISTED` / `REGRESSED` block, then exits `0` (verified) or `1` (not verified). | No |

Verdict definitions:

- **RESOLVED**  -- invariants present BEFORE that are now gone. Expected outcome.
- **PERSISTED** -- invariants present BEFORE that are STILL present after rollback. The rollback failed to fix these; each line shows `[invariantCode] regPath` plus a `reg.exe query "<path>"` command for direct inspection.
- **REGRESSED** -- invariants NOT present before that appeared AFTER rollback. Should never happen for a clean rollback; indicates the surgical uninstall introduced state.

Exit codes:

- `0` -- VERIFIED (PERSISTED and REGRESSED are both empty).
- `1` -- NOT VERIFIED (one or both lists are non-empty).

Opt-out:

```powershell
.\run.ps1 rollback                       # full verified rollback (default)
.\run.ps1 rollback -SkipRollbackVerify   # legacy behaviour: surgical uninstall only, no snapshot/baseline/recheck
```

The pre-rollback snapshot is your undo button: if the verification surfaces
something unexpected, restore the captured state with
`reg.exe import "<path-printed-in-report>"` (the path is printed both at
capture time and again in the verification block).

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
