# Verification Summary (script 52)

After the registry repair runs, script 52 prints a structured PASS/FAIL
table that explicitly maps each registry target to the **real-world
right-click scenario** the user sees in Windows Explorer.

## Mapping

| Registry target | Scenario                                     | Expected after repair |
| --------------- | -------------------------------------------- | --------------------- |
| `directory`     | Right-click ON a folder                      | **PRESENT**           |
| `background`    | Right-click on EMPTY space inside a folder   | **ABSENT**            |
| `file`          | Right-click on a FILE                        | **ABSENT**            |

The mapping lives in `_TargetScenarioMap` inside
`scripts/52-vscode-folder-repair/helpers/repair.ps1` -- update it there
if `config.removeFromTargets` / `config.ensureOnTargets` ever gain new
target keys.

## Output shape

```
============================================================
  Context Menu Verification Summary
============================================================
  EDITION    TARGET       SCENARIO                                      EXPECT    RESULT
  ------------------------------------------------------------------------------------------------
  stable     directory    Right-click ON a folder                       PRESENT   PASS
  stable     background   Right-click on EMPTY space inside a folder    ABSENT    PASS
  stable     file         Right-click on a FILE                         ABSENT    PASS
  ------------------------------------------------------------------------------------------------
  OVERALL: PASS   pass=3   fail=0   total=3
============================================================
```

On any FAIL row, an extra indented line shows the actual state and the
exact registry path so the user can copy-paste it into `reg query`.

## Implementation

- **Helper**: `Write-VerificationSummary -Results <hashtable[]>` in
  `helpers/repair.ps1`. Pure presentation; returns `$true` iff every row
  passed.
- **Collection**: `run.ps1` builds `$verificationResults` inside the
  per-edition verify loop (one row per `Test-TargetState` call) and
  invokes the renderer once after the loop.
- A failed summary flips `$isAllSuccessful` so the existing
  "completedWithWarnings" branch and the log file's `fail` status both
  reflect a verification failure.
