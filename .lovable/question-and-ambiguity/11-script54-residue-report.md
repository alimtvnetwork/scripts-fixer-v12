# 11 - Script 54 scope-matrix: detailed residue report

**Spec reference:** "Add a detailed residue report output to my Script 54
scope matrix that lists exactly which expected keys are missing after
uninstall for each scope."

## Inference used (Option B)

Extended `tests/run-scope-matrix.ps1` rather than creating a separate
report script -- the matrix is the only place that already knows the
expected paths per (scope, edition, target), so co-locating the report
keeps the truth source single.

### What was added

1. A `$script:residueRows` ledger collecting one structured row per
   anomaly with: `Scope`, `Edition`, `Target` (file/directory/background),
   `Class`, `Hive` (this/opposite), `PsPath`, `Detail`. The four classes
   reported are:
   - `RESIDUE`              -- uninstall left the key behind in the scope under test
   - `MISSING-AFTER-INSTALL` -- install ran but the expected key never appeared
   - `BLEED-INSTALL`        -- install created a key in the OPPOSITE scope hive
   - `BLEED-UNINSTALL`      -- a key appeared in the OPPOSITE hive after uninstall
2. `Add-ResidueRow` is invoked from each existing `[FAIL]` branch in
   `Invoke-ScopeCase`. The legacy concatenated-reasons strings on
   `$scopeStatus` are kept untouched so the granular exit codes (10/11/
   12/20/21/22/30) stay bit-for-bit compatible.
3. `Write-ResidueReport` renders a fixed-width table after the
   per-scope summary, even on full PASS (an empty report is itself a
   signal). Color per class; class legend printed below the table.
4. New `-ReportPath <file>` parameter writes the same data as JSON with
   schema `scripts/54/scope-matrix-residue-report.v1`. CI-friendly.
   CODE-RED file-error message names the exact failing path on write
   failure.

### PowerShell quirks worked around

While verifying with PowerShell 7.5.4 (via nix) two non-obvious runtime
errors surfaced and were fixed in the same patch:

- Nesting `[ordered]@{}` (or `[pscustomobject]@{}`) values inside an
  outer `[ordered]@{}` literal triggers `Argument types do not match`.
  Fix: use plain `@{}` for the outer doc -- JSON property order is
  irrelevant since consumers parse by name.
- `@($genericList)` over a `System.Collections.Generic.List[object]`
  containing `[pscustomobject]` items also throws `Argument types do
  not match` in 7.5+. Fix: use `.ToArray()` to materialise a plain
  `object[]` first.

Both quirks are documented inline in the script so the next maintainer
doesn't re-introduce them.

## Verification

- `[Parser]::ParseFile(...)` reports zero parse errors against the
  modified `run-scope-matrix.ps1`.
- End-to-end JSON dump exercised with synthetic residue rows under
  pwsh 7.5.4: `report6.json` produced with all four classes, totals,
  scopeStatus, and per-row detail. Output sample in this loop's logs.
- Existing exit codes (0/2/3/10/11/12/20/21/22/30) untouched.

## How to revert

Delete the `$script:residueRows` ledger, `Add-ResidueRow`,
`Write-ResidueReport`, the `-ReportPath` parameter, and the four
`Add-ResidueRow` calls in `Invoke-ScopeCase`. Remove the new "Detailed
residue report" section in `tests/readme.md`.
