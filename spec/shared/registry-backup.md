# scripts/shared/registry-backup.ps1

Reusable helpers for any script that mutates the Windows registry. Two
responsibilities:

1. **Snapshot keys** to a single timestamped `.reg` file BEFORE any write
   so the user can roll back with one `reg import` command.
2. Maintain an in-memory **change ledger** (one row per write/delete) and
   persist it as JSON + render a colored end-of-run table.

## Public API

| Function                   | Purpose                                                      |
| -------------------------- | ------------------------------------------------------------ |
| `New-RegistryBackup`       | Snapshot N keys to one `.reg` file via `reg.exe export`.     |
| `Start-RegistryChangeLog`  | Reset the in-memory ledger for a new run.                    |
| `Add-RegistryChange`       | Record one row: `BACKUP` / `WRITE` / `DELETE` / `SKIP` / `FAIL`. |
| `Get-RegistryChangeLog`    | Return all recorded rows.                                    |
| `Save-RegistryChangeLog`   | Persist the ledger to JSON. Returns the file path.           |
| `Write-RegistryChangeLog`  | Print colored table + rollback hint.                         |

## Backup file format

```
Windows Registry Editor Version 5.00

; ============================================================
; Registry backup
;   tag       : script52-stable
;   created   : 2026-04-28T14:32:11.123Z
;   key count : 3
; To roll back: reg import "C:\...\registry-backup-script52-stable-*.reg"
; ============================================================

; ----- HKEY_CLASSES_ROOT\Directory\shell\VSCode -----
[HKEY_CLASSES_ROOT\Directory\shell\VSCode]
@="Open with Code"
"Icon"="\"C:\\...\\Code.exe\""
...

; ----- HKEY_CLASSES_ROOT\*\shell\VSCode ----- (absent at backup time, nothing to roll back)
```

Absent keys are documented as comments so the file is self-describing.

## Change-log row schema

```jsonc
{
  "Timestamp": "2026-04-28T14:32:11.456Z",
  "Operation": "WRITE",          // BACKUP|WRITE|DELETE|SKIP|FAIL
  "Edition":   "stable",
  "Target":    "directory",
  "Path":      "HKEY_CLASSES_ROOT\\Directory\\shell\\VSCode",
  "Detail":    "ensured 'Open with Code' -> C:\\...\\Code.exe",
  "Success":   true
}
```

## CODE RED compliance

Every failure path goes through `Write-FileError` (when `logging.ps1` is
dot-sourced) or an inline banner that includes the **exact path** and the
**reason**.

## Adopters

- `scripts/52-vscode-folder-repair/run.ps1` (legacy in-file flow):
  - One backup `.reg` per detected edition into
    `scripts/52-vscode-folder-repair/.logs/registry-backups/`.
  - Aborts writes for that edition if the backup step fails.
  - Persists `registry-changes-script52-*.json` and prints the colored
    table with the `reg import "<file>"` hint.
- `scripts/52-vscode-folder-repair/manual-repair.ps1` already has its own
  `Save-MenuSnapshot` (BEFORE/AFTER + diff) and is **not** changed by
  this helper -- they coexist.

## Future candidates

Other HKCR / HKLM writers: scripts 10, 53, 54, 56, 57.
