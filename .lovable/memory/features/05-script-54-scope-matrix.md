---
name: Script 54 scope-matrix harness
description: scripts/54-vscode-menu-installer/tests/run-scope-matrix.ps1 -- mutating install/uninstall test matrix per -Scope (CurrentUser + AllUsers), with cross-hive bleed detection and granular exit codes
type: feature
---
## scripts/54-vscode-menu-installer/tests/run-scope-matrix.ps1

Mutating sibling of `run-tests.ps1`. Walks the full
`install -> verify -> uninstall -> verify` cycle once per `-Scope`
(`CurrentUser` + `AllUsers`) and asserts the registry ends up exactly
where each scope is supposed to write.

### Why it exists
`run-tests.ps1` is read-only and inspects whatever's already in the
registry. It cannot catch scope-routing regressions on its own because
HKCR is a merged read view -- a per-user install will appear to "pass"
via HKCR even if the production code accidentally wrote to HKLM. The
matrix harness fixes that by doing real writes and probing the EXACT
hive each scope is supposed to target, plus the OPPOSITE hive (bleed
detection) on a strict allow-list (never enumerates the registry).

### Per-scope contract
| Scope         | Expected hive (writes)                         | Bleed watchlist (must NOT exist) |
|---------------|------------------------------------------------|----------------------------------|
| `CurrentUser` | `HKCU\Software\Classes\…`                      | `HKEY_CLASSES_ROOT\…` (i.e. HKLM)|
| `AllUsers`    | `HKEY_CLASSES_ROOT\…` (HKLM\Software\Classes)  | `HKCU\Software\Classes\…`        |

The harness sources `helpers\vscode-install.ps1` so it rewrites paths
via the production `Convert-EditionPathsForScope` -- a divergent
re-implementation here would silently mask real bugs.

### Admin gate
- Default (`-OnlyScope Both`) auto-skips AllUsers when not elevated and
  prints `[SKIP]` so CI can still pass on a non-admin runner.
- `-OnlyScope AllUsers` without admin = hard fail, exit 3 (operator
  explicitly asked for the elevated case).

### Granular exit codes (CI can act on the specific failure mode)
| Exit | Meaning                                                          |
|------|------------------------------------------------------------------|
| 0    | all green                                                        |
| 2    | pre-flight failed (config / install.ps1 / uninstall.ps1 missing) |
| 3    | `-OnlyScope AllUsers` without admin                              |
| 10   | CurrentUser: post-install verification failed                    |
| 11   | CurrentUser: post-uninstall residue                              |
| 12   | CurrentUser: cross-hive bleed (HKLM key created)                 |
| 20   | AllUsers:    post-install verification failed                    |
| 21   | AllUsers:    post-uninstall residue                              |
| 22   | AllUsers:    cross-hive bleed (HKCU key created)                 |
| 30   | both scopes had failures                                         |

### Useful flags
- `-OnlyScope CurrentUser|AllUsers|Both`  -- restrict the matrix
- `-Edition stable|insiders`              -- restrict editions
- `-WhatIf`                               -- dry-run, prints expected paths only
- `-KeepGoing`                            -- don't bail on first install failure
- `-NoColor`                              -- CI-friendly output

### CODE RED compliance
Every missing prerequisite (config.json, install.ps1, uninstall.ps1,
helpers module) is reported with the exact path + a failure reason
before exit, matching the toolkit-wide rule.

Built: v0.128.0
Cannot be syntax-checked in the Lovable sandbox (no pwsh); intended to
run on real Windows. Exit-code contract is the test contract.