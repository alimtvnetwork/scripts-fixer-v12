# 14 - Script 65 (Windows): plan-confirm-apply-verify dispatcher

**Spec:** "Implement a script 65 os-clean that dispatches to the existing
Windows cleanup flow and supports plan-then-confirm with --dry-run."

## What the existing Windows cleanup flow turned out to be

`scripts/os/` already ships a 59-category cleanup engine
(`scripts/os/run.ps1 clean ...`) with `--dry-run`, `--yes`, `--only`,
`--skip`, `--bucket`, `--days`. The Linux 65 readme even says it
"Pairs with Windows scripts/os/ clean subverbs".

So script 65 (Windows side) is a **thin dispatcher** over that engine,
adding the same plan/confirm/verify lifecycle that scripts-linux/65
ships (from task 9), nothing more.

## Layout

```
scripts/65-os-clean/
  run.ps1            # 358-line dispatcher
  config.json        # delegate metadata + verify config
  log-messages.json  # synopsis + usage examples
  readme.md          # full lifecycle + exit codes table
  helpers/           # (reserved; empty for now)
```

Plus `scripts/registry.json` mapping `"65" -> "65-os-clean"`.

## Lifecycle

1. **PLAN**     -- `os clean --dry-run` + forwarded flags. Parse per-category counts.
2. **CONFIRM**  -- prompt operator (typed `yes`); auto-confirm on `--yes`; abort on non-interactive without `--yes`.
3. **APPLY**    -- `os clean --yes` for real. Capture rc.
4. **VERIFY**   -- re-run `os clean --dry-run`. Categories that drop to 0 = `PASS`; rows remaining = `FAIL(n)`.
5. **SUMMARY**  -- table mirroring Linux 65 (STATUS / CATEGORY / BEFORE / AFTER / VERIFIED) + manifest.json.

`--dry-run` short-circuits after stage 1 (no prompt, no apply, no verify) -- matches Linux 65.

## PowerShell quirk that bit twice

`Tee-Object` and `Write-Host` both emit `HostInformation` records onto
the success stream when used inside a function. The first cut used
`& $delegate *>&1 | Tee-Object -LiteralPath $f` and got an array
`[<HostInfo>..., 0]` back as the "rc". Manifest then serialised the
full HostInfo objects.

**Fix:** `& $delegate *>&1 > $OutFile` (no Tee), then read the file back
and stream to console with `Get-Content | ForEach-Object Write-Host`.
Function returns `[int]$rc`. Documented inline in `Invoke-OsClean`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | All stages succeeded; verify shows zero residue |
| 1    | Operator aborted at confirm prompt (or non-interactive without `--yes`) |
| 2    | Pre-flight failure (delegate missing, log dir un-creatable) |
| 11   | Apply succeeded but verify detected residue (mirrors Linux 65 style) |
| 30   | Delegate threw an unhandled exception |
| other| Propagated rc from `scripts/os/run.ps1 clean` |

## Verification (this loop)

| Check | Result |
|---|---|
| `[Parser]::ParseFile` on run.ps1 | PARSE OK |
| `--help` rendering | full help printed |
| `--dry-run` lifecycle (stub delegate, 3 cats x 23 items) | PLAN table + manifest with `mode=dry-run`, `verification=null` |
| Full apply -> verify (2 cats fully cleaned, 1 has residue) | summary shows `PASS chrome`, `FAIL edge (1)`, `PASS recycle`; `TOTAL PASS=2 FAIL=1` |
| Apply finished log line | `rc=0` (scalar int, no HostInfo contamination) |
| Manifest `apply.exitCode` | scalar `0` |
| Manifest `verification.totals` | `{pass:2, fail:1, categories:3}` |
| Process exit on residue | `11` as designed |

## How to revert

`rm -rf scripts/65-os-clean/`, remove `"65": "65-os-clean"` from
`scripts/registry.json`.
