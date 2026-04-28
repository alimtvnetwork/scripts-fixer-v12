# Spec: Per-Tool Version Parser Registry

## Purpose

Different CLIs print versions in wildly different shapes. Without a
per-tool parser the `.installed/<name>.json` ledger ends up storing the
raw output (e.g. `"git version 2.43.0.windows.1"`), which breaks
version-drift checks in `Ensure-Tool` and confuses `run.ps1 status`.

This registry centralises one parser per tool so every caller of
`Ensure-Tool` (and any future helper) gets an accurate version string
for free.

## Location

`scripts/shared/tool-version-parsers.ps1` -- auto-sourced by
`scripts/shared/ensure-tool.ps1`.

## Public API

| Function | Purpose |
|---|---|
| `Get-ToolVersionParser -Name <tool>` | Return the registered scriptblock or `$null`. |
| `Invoke-ToolVersionParser -Name <tool> -Raw <string>` | Apply parser, fall back to generic semver extraction, return trimmed string. |
| `Register-ToolVersionParser -Name <tool> -Parser <scriptblock>` | Add or override a parser at runtime. |

## Built-in parsers

| Tool name(s) | Raw output example | Stored value |
|---|---|---|
| `git` | `git version 2.43.0.windows.1` | `2.43.0.windows.1` |
| `node` / `nodejs` | `v20.11.0` | `20.11.0` |
| `python` | `Python 3.12.1` | `3.12.1` |
| `go` | `go version go1.22.0 windows/amd64` | `1.22.0` |
| `java` | `openjdk version "21.0.2" 2024-...` | `21.0.2` |
| `dotnet` | `8.0.101` | `8.0.101` |
| `rustc` | `rustc 1.76.0 (07dca489a 2024-02-04)` | `1.76.0` |
| `pnpm` | `9.4.0` | `9.4.0` |
| `choco` | `Chocolatey v2.2.2` | `2.2.2` |

Unknown tools fall back to the first dotted version-looking token in the
output, then finally to the trimmed raw text.

## Integration with Ensure-Tool

When `Ensure-Tool` is called without an explicit `-ParseScript`, it
consults the registry by `-Name`. Any explicitly supplied `-ParseScript`
still takes priority.

```powershell
# Before: stored "git version 2.43.0.windows.1"
Ensure-Tool -Name "git" -Command "git" -ChocoPackage "git"

# After: stored "2.43.0.windows.1" (no caller change required)
Ensure-Tool -Name "git" -Command "git" -ChocoPackage "git"
```

## Adding a new tool

```powershell
Register-ToolVersionParser -Name "kubectl" -Parser {
    param($raw)
    if ("$raw" -match 'GitVersion:"v([\d\.]+)') { return $Matches[1] }
    return $null   # registry will fall back to generic semver extraction
}
```

## Error handling

- A parser that throws is caught; the helper falls back to generic
  semver extraction so a buggy parser cannot break installs.
- A missing registry file logs a CODE RED warning with the exact path
  but lets `Ensure-Tool` continue with raw output (degraded but safe).
