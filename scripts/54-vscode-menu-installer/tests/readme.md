<!-- spec-header:v1 -->
<div align="center">

<img src="../../../assets/icon-v1-rocket-stack.svg" alt="Script 54 — Test Harness" width="128" height="128"/>

# Script 54 — Test Harness

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-54%20tests-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.72.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../../../spec/00-spec-writing-guide/readme.md).*

</div>

---

## Overview

Plain-PowerShell test runner for the VS Code menu installer. **Read-only**:
inspects the live registry against the path allow-list in `config.json` and
prints a colored pass/fail summary. Zero dependencies, no Pester.

This is the **subset** mirror of script 53's harness -- it verifies leaf
existence and the command template only. Script 54 does not emit
Shift-bypass twins, so cases 6 - 13 from script 53's spec do not apply
here.

## Prerequisites

- Windows 10 / 11
- Script 54 already installed:

  ```powershell
  .\run.ps1 -I 54 install                 # all enabled editions
  .\run.ps1 -I 54 install -Edition stable # one edition only
  ```

- Admin shell is **not** required for verify (read-only).

## Usage

From the repo root:

```powershell
# All enabled editions, all targets (file / directory / background)
.\scripts\54-vscode-menu-installer\tests\run-tests.ps1

# Same thing via the dispatcher
.\run.ps1 -I 54 verify

# One edition only
.\run.ps1 -I 54 verify -Edition stable

# Subset of targets
.\run.ps1 -I 54 verify -OnlyTargets file,directory

# Subset of cases
.\run.ps1 -I 54 verify -OnlyCases 1,4

# CI / log-friendly
.\run.ps1 -I 54 verify -NoColor

# Verbose (print every PASS line, not just FAIL)
.\run.ps1 -I 54 verify -Verbose
```

## Parameters

| Parameter      | Default                        | Notes                                                    |
|----------------|--------------------------------|----------------------------------------------------------|
| `Edition`      | `config.enabledEditions`       | Restrict to one edition (e.g. `stable` or `insiders`).   |
| `OnlyTargets`  | `file,directory,background`    | Subset of registry targets to test.                      |
| `OnlyCases`    | (all)                          | Array of case numbers, e.g. `-OnlyCases 1,4`.            |
| `NoColor`      | off                            | Disable ANSI colors (for log capture / CI).              |

## Exit codes

| Code | Meaning                                                              |
|------|----------------------------------------------------------------------|
| 0    | All cases passed                                                     |
| 1    | At least one assertion failed                                        |
| 2    | Pre-flight failed (config missing, no enabled editions to test)      |

## What each case verifies (per edition x per target)

| Case | Verifies                                                                                       |
|------|------------------------------------------------------------------------------------------------|
| 1    | The leaf key exists at the configured `registryPaths.<target>` path.                           |
| 2    | The leaf's `(Default)` REG_SZ value matches the configured `editions.<edition>.label`.         |
| 3    | A `command` subkey exists with a non-empty `(Default)` value.                                  |
| 4    | The `(Default)` command matches the expected template (direct dispatch OR confirm-launch wrapper, depending on `confirmBeforeLaunch.enabled`). For direct mode, also asserts the `%1` / `%V` placeholder tail. |
| 5    | Idempotency sanity -- no doubled-up siblings (e.g. `VSCodeVSCode`, `VSCode_1`) under the parent. |

## Mode auto-detection

The harness reads `config.confirmBeforeLaunch.enabled`:

- `false` (default) -> expects direct command lines like `"C:\...\Code.exe" "%1"`.
- `true` -> expects the wrapper:
  `pwsh ... confirm-launch.ps1 ... Invoke-ConfirmedCommand -CommandLine '<inner>' -Label '...' -CountdownSeconds N`.

You don't pass the mode to the harness -- it picks the right assertions automatically.

## Companion: `run-scope-matrix.ps1` (mutating)

`run-tests.ps1` is read-only. `run-scope-matrix.ps1` is the **mutating**
sibling that exercises the per-user vs per-machine scope plumbing
end-to-end. It runs the full `install -> verify -> uninstall -> verify`
cycle once per scope:

| Scope         | Hive written / probed                                      | Admin? |
|---------------|------------------------------------------------------------|--------|
| `CurrentUser` | `HKEY_CURRENT_USER\Software\Classes\…`                     | no     |
| `AllUsers`    | `HKEY_CLASSES_ROOT\…` (physically `HKLM\Software\Classes`) | yes    |

For each scope it asserts:

1. After install, every expected key for **this** scope exists.
2. After install, **no** key was created in the OPPOSITE hive (cross-hive
   bleed catches scope-routing bugs that the merged HKCR view would hide).
3. After uninstall, every expected key is gone.
4. After uninstall, the opposite hive is still untouched (no late bleed).

The harness sources `helpers\vscode-install.ps1` so it rewrites paths via
the same `Convert-EditionPathsForScope` the production code uses --
a divergent re-implementation here would silently mask real bugs.

### Usage

```powershell
# Both scopes; AllUsers is auto-skipped if not elevated
.\run-scope-matrix.ps1

# CurrentUser only (no admin needed)
.\run-scope-matrix.ps1 -OnlyScope CurrentUser

# AllUsers only (must run elevated -- exits 3 otherwise)
.\run-scope-matrix.ps1 -OnlyScope AllUsers

# Single edition
.\run-scope-matrix.ps1 -Edition stable

# Dry-run: print plan + expected paths, change nothing
.\run-scope-matrix.ps1 -WhatIf

# Don't bail on first install failure (collect everything)
.\run-scope-matrix.ps1 -KeepGoing

# CI-friendly
.\run-scope-matrix.ps1 -NoColor

# Dump a machine-readable residue report for CI consumption
.\run-scope-matrix.ps1 -ReportPath .\matrix-residue.json
```

### Detailed residue report

After every run -- pass or fail -- the harness prints a **Residue report**
table listing every expected key that ended up in the wrong state, with
columns `SCOPE | EDITION | TARGET | CLASS | HIVE | PATH` and a one-line
`Detail` follow-up per row. Classes:

| Class                   | Meaning                                                              |
|-------------------------|----------------------------------------------------------------------|
| `RESIDUE`               | uninstall left the key behind in the scope under test                |
| `MISSING-AFTER-INSTALL` | install ran but the expected key never appeared                      |
| `BLEED-INSTALL`         | install created a key in the OPPOSITE scope's hive (routing leak)    |
| `BLEED-UNINSTALL`       | a key appeared in the OPPOSITE hive after uninstall (routing leak)   |

An empty report is itself a useful signal -- it confirms every targeted
path landed and was removed in the correct hive for every `(scope,
edition)` combination that ran.

When `-ReportPath <file>` is supplied, the same data is also written as a
JSON document with schema `scripts/54/scope-matrix-residue-report.v1`,
containing `editions`, `scopes`, `admin`, `scopeStatus`, per-row
`residueRows`, and a `totals` summary. CI jobs should consume this file
rather than screen-scraping the table.

### Granular exit codes

| Exit | Meaning                                                          |
|------|------------------------------------------------------------------|
| 0    | all green                                                        |
| 2    | pre-flight failed (config / install.ps1 / uninstall.ps1 missing) |
| 3    | `-OnlyScope AllUsers` requested but harness not elevated         |
| 10   | CurrentUser: post-install verification failed                    |
| 11   | CurrentUser: post-uninstall verification failed (residue)        |
| 12   | CurrentUser: cross-hive bleed (HKLM key created)                 |
| 20   | AllUsers:    post-install verification failed                    |
| 21   | AllUsers:    post-uninstall verification failed (residue)        |
| 22   | AllUsers:    cross-hive bleed (HKCU key created)                 |
| 30   | both scopes had failures                                         |

### Safety notes

- This harness performs **real registry writes** in HKCU and (when elevated)
  HKLM\Software\Classes. Run it on a sandbox / VM, not a production machine.
- Strict allow-list: the bleed check probes only the exact opposite-scope
  paths derived from `config.json`. It never enumerates the registry.
- CODE RED: every missing prerequisite (config.json, install.ps1, helpers
  module) is reported with the exact path + failure reason before exit.
