# Spec: End-of-Run Ensure-Tool Summary

## Purpose

After a batch of `Ensure-Tool` calls (advanced profile, script 12, future
fan-out playbooks) the operator should see a single colored table that
answers the only question that actually matters:

> "What did this run change, and what versions did it leave behind?"

Without this, users have to scroll back through hundreds of log lines to
reconstruct that picture.

## Location

`scripts/shared/ensure-summary.ps1` -- auto-sourced by
`scripts/shared/ensure-tool.ps1`.

## How it captures data

`Ensure-Tool` was updated to route every return path through a tiny
internal helper (`Complete-EnsureToolResult`). That helper calls
`Add-EnsureSummary` so the operator never has to remember to wire it up.

Existing callers (e.g. `scripts/07-install-git/helpers/git.ps1`) keep
working unchanged -- they will simply contribute one row to the table if
a summary is being collected.

## Public API

| Function | Purpose |
|---|---|
| `Start-EnsureSummary` | Reset the in-memory collector at the start of a run. |
| `Add-EnsureSummary -Name <n> -Result <hash>` | Manually record a result (auto-called by `Ensure-Tool`). |
| `Get-EnsureSummary` | Return the captured entries (array of pscustomobject). |
| `Get-EnsureSummaryTotals` | Hashtable: `installed / upgraded / skipped / failed / unknown / total`. |
| `Write-EnsureSummary [-Title] [-NoBanner] [-JsonPath]` | Print the table + totals; optionally persist as JSON. |
| `Reset-EnsureSummary` | Drop all entries (re-runs / tests). |

## Color contract

ASCII only -- no em-dashes or wide Unicode (matches the terminal-banner
constraint).

| Action      | Color  | Meaning |
|-------------|--------|---------|
| `installed` | Green  | Was missing, freshly installed. |
| `upgraded`  | Cyan   | Already present, moved to latest. |
| `skipped`   | Gray   | Already installed and tracked. |
| `failed`    | Red    | Result carries `.Error`. |
| `unknown`   | Yellow | `Ensure-Tool` returned `$null` or no `Action`. |

The footer line is colored Red on any failure, Green when at least one
install/upgrade happened, otherwise Gray.

## Table layout

```
============================================================
  Tool install summary
============================================================
ACTION     TOOL                 VERSION                  NOTES
------------------------------------------------------------------------------
SKIPPED    Git                  2.43.0.windows.1         tracked
INSTALLED  Node.js              20.11.0
UPGRADED   Python               3.12.1
FAILED     dotnet               (unknown)                install failed: ...
------------------------------------------------------------------------------
Total: 4  installed: 1  upgraded: 1  skipped: 1  failed: 1
```

## Recommended call shape

```powershell
. "$PSScriptRoot/../shared/ensure-tool.ps1"   # also pulls in summary helpers

Start-EnsureSummary
foreach ($t in $tools) {
    Ensure-Tool -Name $t.Name -Command $t.Cmd -ChocoPackage $t.Pkg | Out-Null
}
Write-EnsureSummary -Title "Advanced profile install" `
                    -JsonPath ".installed/.summary-$(Get-Date -Format yyyyMMdd-HHmmss).json"
```

## CI / exit-code contract

```powershell
$totals = Get-EnsureSummaryTotals
if ($totals.failed -gt 0) { exit 1 }
```

## Error handling

- The collector is best-effort: if `Add-EnsureSummary` throws, the calling
  `Ensure-Tool` invocation still returns its result normally.
- File writes for `-JsonPath` use the CODE RED rule -- failures are
  logged with the exact path and reason via `Write-FileError` (or a
  fallback `Write-Log` line when the helper isn't loaded).
- A missing `ensure-summary.ps1` next to `ensure-tool.ps1` logs a warning
  and degrades to plain logging behaviour.
