# scripts/shared/admin-check.ps1

Reusable Windows admin-elevation helpers for scripts that write to
`HKEY_CLASSES_ROOT` / `HKLM` and therefore must run elevated.

## Public API

### `Test-IsElevated`

Returns `[bool]`. `$true` when the current process is a member of the local
Administrators role. On non-Windows hosts (macOS / Linux dev shells) it
returns `$true` so cross-platform sourcing does not break.

### `Assert-Elevated`

Fail-fast gate. If the current shell is not elevated:

1. Logs a CODE RED style error that includes the **exact script path** and
   the **reason** (uses `Write-FileError` from `logging.ps1` when present,
   otherwise prints an inline banner).
2. Prints a **copy-paste retry command** for both Windows PowerShell 5.1
   and PowerShell 7+, plus a `Start-Process -Verb RunAs` one-liner for
   launching an elevated shell from a non-elevated one.
3. Calls `exit $ExitCode` (default `87`, the Win32
   `ERROR_INVALID_PARAMETER` analogue for "wrong privilege").

Parameters:

| Name          | Required | Default | Purpose                                                              |
| ------------- | -------- | ------- | -------------------------------------------------------------------- |
| `ScriptPath`  | yes      | --      | Absolute path of the script that needs elevation. Logged + retried.  |
| `ScriptArgs`  | no       | `''`    | Original args, appended to the retry command verbatim.               |
| `Reason`      | no       | HKCR msg| One-line explanation of why elevation is needed.                     |
| `ExitCode`    | no       | `87`    | Process exit code on failure.                                        |

## Design choices

- **Fail-fast, non-interactive by default.** No automatic UAC re-launch.
  Callers that want auto-elevation must add their own `--elevate` opt-in
  flag (per the agreed convention).
- **Zero hard dependencies.** Works whether or not `logging.ps1` has been
  dot-sourced; falls back to inline `Write-Host`.
- **CODE RED compliant.** Every failure path includes the exact script
  path + a concrete reason, matching the repo-wide error convention.

## Usage

```powershell
. (Join-Path $sharedDir 'admin-check.ps1')

Assert-Elevated `
    -ScriptPath  $PSCommandPath `
    -ScriptArgs  ($args -join ' ') `
    -Reason      'Writes HKCR\Directory\shell\VSCode entries.'
```

## Adopters

- `scripts/52-vscode-folder-repair/run.ps1` -- gate runs before the
  subcommand dispatcher; skipped for read-only subcommands
  (`help`, `dry-run`, `whatif`, `verify`, `verify-handlers`).

Future candidates (also write to HKCR / HKLM): scripts 10, 53, 54, 56, 57.
