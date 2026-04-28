# 53 — VS Code Folder + Background Context Menu Repair

Re-registers VS Code right-click entries for **both** scenarios:

| Scenario                                  | Registry target                                 | After this script |
| ----------------------------------------- | ----------------------------------------------- | ----------------- |
| Right-click ON a folder                   | `HKCR\Directory\shell\VSCode`                   | **PRESENT**       |
| Right-click in EMPTY space inside folder  | `HKCR\Directory\Background\shell\VSCode`        | **PRESENT**       |
| Right-click on a FILE                     | `HKCR\*\shell\VSCode`                           | **ABSENT**        |

## Difference vs script 52

- **52**: ensures `directory`, removes `file` + `background`.
- **53**: ensures `directory` + `background`, removes only `file`.

Use 53 when you want VS Code to be available both when right-clicking a
folder AND when right-clicking inside an open folder window.

## Usage

```powershell
# Default: repair both editions (auto-detected) and restart explorer
.\run.ps1

# Single edition
.\run.ps1 repair -Edition stable

# Skip explorer restart (changes still apply, may need re-login)
.\run.ps1 no-restart

# Pre-check / dry-run: report what WOULD change, no writes (no admin needed)
.\run.ps1 dry-run
.\run.ps1 precheck    # alias
.\run.ps1 plan        # alias

# Transactional all-in-one: pre-check -> backup -> apply -> verify ->
# auto-rollback (reg import) if any apply OR verify step fails for an edition.
.\run.ps1 repair-vscode
.\run.ps1 repair-vscode -Edition stable
.\run.ps1 repair-vscode -NoRollback     # apply without auto-rollback safety net
```

## Transactional repair (`repair-vscode`)

Runs the full pipeline as an atomic operation per edition:

1. **Pre-check** -- prints the planned changes table.
2. **Backup** -- snapshots every key it might touch into a `.reg` file.
3. **Capture pre-state** -- records present/absent for each key.
4. **Apply** -- removes file-target leaf, ensures directory + background.
5. **Verify** -- runs the PASS/FAIL summary against the desired state.
6. **Rollback (on failure)** -- if step 4 or 5 reports any failure for
   that edition, the script:
   - deletes any keys it just touched (so `reg import` is clean),
   - runs `reg import <backup.reg>` to restore the snapshot,
   - re-checks each key matches its pre-apply state,
   - prints a colored ROLLBACK ledger (RESTORED / INCOMPLETE).

The rollback is per-edition: a failure on `insiders` will not roll back
a successful `stable` apply. Pass `-NoRollback` to disable the safety
net (apply still runs; failures just leave the partial state in place).

## Pre-check / dry-run

Before any write, the script inspects every (edition, target) pair and
prints a colored plan table with one of these actions:

| Plan      | Meaning                                                                 |
| --------- | ----------------------------------------------------------------------- |
| `ENSURE`  | Key is missing -- will be created.                                       |
| `REMOVE`  | File-target leaf is present -- will be deleted.                          |
| `REPAIR`  | Key exists but `(Default)` label or `\command` doesn't match -- will be rewritten. |
| `NOOP`    | Already in the desired state -- nothing to do.                           |
| `SKIP`    | Cannot apply (e.g. VS Code exe not found for that edition).             |

Running `dry-run` / `precheck` / `plan` STOPS after this table -- no
registry writes, no Explorer restart, no admin required. Run without the
flag to apply.

## What it does (per edition)

1. Snapshots every key it might touch into a `.reg` file under
   `.logs\registry-backups\` so you can roll back with `reg import <file>`.
2. Removes the `file` leaf (`HKCR\*\shell\VSCode`) if present.
3. Ensures the `directory` and `background` leaves exist with:
   - `(Default)` = `Open with Code` (or `Open with Code - Insiders`)
   - `Icon`      = path to `Code.exe`
   - `\command (Default)` = `"<Code.exe>" "%V"`
4. Verifies every target and prints a PASS/FAIL summary table.
5. Restarts `explorer.exe` so the change is visible immediately.

## Reused helpers

`run.ps1` dot-sources `..\52-vscode-folder-repair\helpers\repair.ps1`
to reuse `Set-FolderContextMenuEntry`, `Remove-ContextMenuTarget`,
`Test-TargetState`, `Write-VerificationSummary`, and `Restart-Explorer`.
The only behavioral difference vs 52 is the config — 53 puts
`background` in `ensureOnTargets` instead of `removeFromTargets`.
