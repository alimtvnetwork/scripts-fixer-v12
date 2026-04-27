---
name: Windows schema validator
description: scripts/os/helpers/_schema.ps1 mirrors bash _schema.sh rule DSL + TSV contract for cross-OS JSON loaders
type: feature
---
PowerShell sibling of `scripts-linux/68-user-mgmt/helpers/_schema.sh`. Adopt this in every Windows `*-from-json.ps1` loader instead of ad-hoc validation.

**Rule DSL (identical on both OSes):**
- `nestr` non-empty string
- `str` string (may be empty)
- `bool` boolean
- `uid` non-negative integer or numeric string
- `nestrarr` array of non-empty strings
- mutex `a,b` space-separated pairs

**Public API (PS-cased; semantics match bash):**
- `Initialize-UmSchemaArray <file> <wrapperKey> [-AllowStrings]` -> sets `$script:UmNormalizedJson` (PSObject[]) and `$script:UmNormalizedCount`. Returns `$false` on parse fail.
- `Test-UmSchemaRecord <rec> <allowed> <required> <specs> [<mutex>]` -> string[] of TSV rows (`ERROR\tfield\treason` / `WARN\tfield\treason`).
- `Write-UmSchemaReport -Index -File -Rows [-Mode rich|plain]` -> Write-Log lines, sets `$script:UmSchemaErrCount`.
- `Get-UmSchemaRecordName <rec>` -> `.name` / `<missing>` / `<not-an-object>`.

No `jq` dependency; uses native `PSCustomObject` introspection. Loaders pass the **same allowed/required/specs/mutex strings** the bash counterpart uses, so a single schema definition can be authored once per record type and shared.

**Not yet wired into:** add-user-from-json.ps1, add-group-from-json.ps1, edit-user-from-json.ps1, remove-user-from-json.ps1 (still ad-hoc). Adopting them is a follow-up that needs its own review.
