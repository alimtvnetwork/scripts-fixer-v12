---
name: Script 54 -Verbosity switch (Quiet|Normal|Debug)
description: helpers/verbosity.ps1 + -Verbosity param on install/uninstall/repair/sync/check/router controls how loud the verification + audit-report logging is; failures are NEVER suppressed
type: feature
---
## Verbosity switch for verification + audit reports

New helper module `scripts/54-vscode-menu-installer/helpers/verbosity.ps1`
exports:
- `Set-VerbosityLevel  -Level <Quiet|Normal|Debug>`
- `Get-VerbosityLevel`                                  -> string
- `Test-VerbosityAtLeast -Level <Quiet|Normal|Debug>`   -> [bool]
- `Write-VLog -Message <s> -Level <log-level> -MinVerbosity <Q|N|D>` --
  pass-through to `Write-Log` only when current >= MinVerbosity.
  WARN / ERROR levels ALWAYS pass through (never suppressed).

### Three levels
| Level  | Numeric | What it shows |
|--------|--------:|---------------|
| Quiet  | 0 | Only summary totals + failures + warnings/errors. No banner. No per-row PASS lines. No "Skipped/already absent" rows. No "Added (N): ..." per-key dump. Best for CI / scripted runs. |
| Normal | 1 | Default. Full human-readable report: banner separators + per-row PASS/FAIL + scope label + audit JSONL pointer. |
| Debug  | 2 | Everything Normal shows PLUS raw record counts header + per-target `Test-RegistryKeyExists` probes echoed + missing-children spelled out. |

### Wired into
| Entry point  | -Verbosity param? | Calls Set-VerbosityLevel |
|--------------|:-----------------:|:------------------------:|
| install.ps1  | yes               | yes (after disabled-check) |
| uninstall.ps1| yes               | yes (top of try)           |
| repair.ps1   | yes               | yes (top of try)           |
| sync.ps1     | yes               | yes (after disabled-check) |
| run.ps1      | yes (router)      | yes (in `check` branch); forwards `-Verbosity` to every other verb |

### Gated functions in helpers/vscode-check.ps1
- `Write-RegistryAuditReport` -- banner, per-row added/removed/skipped, JSONL pointer gated. Failures + 0-add anomaly always print.
- `Invoke-PostOpVerification` -- banner + per-row PASS gated; FAIL rows + totals always print. Debug adds `[debug] probe: ...` line per target.
- `Invoke-VsCodeMenuCheck`    -- banner + per-row PASS + per-edition summary gated. Misses always print. Debug adds `[debug] hive=...` line per row.

### Contract
- `Set-VerbosityLevel` echoes the resolved mode to the audit log so the
  run record captures which verbosity was used.
- Invalid values fall back to `Normal` with a loud WARN that includes
  the bad value (CODE RED file/path-error rule).
- All three helpers use `Get-Command Test-VerbosityAtLeast -ErrorAction
  SilentlyContinue` guards so they degrade safely to "Normal" behavior
  if the verbosity helper isn't dot-sourced (e.g. unit tests).

Built: v0.132.0.