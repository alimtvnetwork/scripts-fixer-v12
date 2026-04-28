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

# Manual rollback: restore the most recent snapshot per edition (or one
# explicit .reg file). Snapshots are created automatically before every
# apply under .logs\registry-backups\.
.\run.ps1 -Rollback
.\run.ps1 rollback                                 # alias command
.\run.ps1 -Rollback -Edition stable
.\run.ps1 -Rollback -BackupFile ".logs\registry-backups\script53-stable-2026-04-28T12-00-00Z.reg"
```

## Automatic backups + manual rollback

Every write-mode run (`repair`, `repair-vscode`) snapshots the affected
registry keys to a single timestamped `.reg` file under
`.logs\registry-backups\` BEFORE any write. Files are named
`script53-<edition>-<timestamp>.reg` so they can be picked per edition.

`-Rollback` (or the `rollback` command) restores the prior state without
running an apply:

1. Picks `-BackupFile` if provided, otherwise the newest
   `script53-<edition>*.reg` under `.logs\registry-backups\`.
2. Deletes any keys the apply phase might have created so `reg import`
   merges cleanly.
3. Runs `reg import <snapshot>` to restore the exact prior state.
4. Verifies each key and prints a colored RESTORED / FAILED summary.
5. Restarts Explorer (unless `restartExplorer=false` in config) so the
   restored entries appear immediately.

Per edition: `-Edition stable` rolls back only that edition. With no
filter, every detected edition is restored from its own latest snapshot.

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

## Required permissions

| Command(s)                                          | Admin? | Why                                                                 |
| --------------------------------------------------- | :----: | ------------------------------------------------------------------- |
| `repair`, `repair-vscode`, `rollback`, `no-restart` |   yes  | Writes machine-wide keys under `HKEY_CLASSES_ROOT\Directory\shell`. |
| `dry-run`, `precheck`, `plan`, `whatif`, `verify`   |   no   | Read-only registry queries + console output.                        |
| `--Help`                                            |   no   | Prints help and exits.                                              |

Non-elevated runs of write commands fail fast and print a copy-paste
`Start-Process pwsh -Verb RunAs ...` retry hint -- the script never
auto-triggers UAC.

## Expected behavior -- empty vs non-empty folders

After a successful run, **Open with Code** (or **Open with Code - Insiders**)
must appear in **both** right-click scenarios:

| Scenario                                          | Registry target                                  | Click action                                |
| ------------------------------------------------- | ------------------------------------------------ | ------------------------------------------- |
| Right-click ON a folder icon (empty or non-empty) | `HKCR\Directory\shell\VSCode`                    | Opens that folder in VS Code (`%V`).        |
| Right-click on EMPTY space inside a folder window | `HKCR\Directory\Background\shell\VSCode`         | Opens the **current** folder you're in.     |
| Right-click on a FILE                             | `HKCR\*\shell\VSCode` -- removed by this script  | Entry must NOT appear.                      |

Notes:

- The **background** entry only fires when you click background pixels --
  if a folder is so packed that no whitespace is visible, scroll or
  resize the window so empty space is exposed.
- Both `directory` and `background` work identically whether the target
  folder is empty or contains files; the entry's visibility is decided
  by the registry leaf, not by folder contents.

## How to verify the fix

1. **Automated** -- the script prints a colored PASS/FAIL summary table after
   every run that maps each registry target to its real right-click scenario.
   Re-run standalone any time:

   ```powershell
   .\run.ps1 verify
   ```

2. **Manual smoke test in Windows Explorer:**

   1. Open any folder. Right-click a sub-folder icon  ->  `Open with Code` MUST be visible.
   2. Open that sub-folder. Right-click on empty whitespace  ->  `Open with Code` MUST be visible.
   3. Right-click any file in the folder  ->  `Open with Code` MUST NOT be visible.

3. **Direct registry queries** (elevated PowerShell):

   ```powershell
   reg query "HKCR\Directory\shell\VSCode\command" /ve
   reg query "HKCR\Directory\Background\shell\VSCode\command" /ve
   reg query "HKCR\*\shell\VSCode"                # MUST report 'unable to find'
   ```

   The two `present` commands should each end with `"<path-to-Code.exe>" "%V"`.

4. **Inspect logs / change ledger:**

   - `.logs\registry-backups\script53-*.reg`  --  pre-apply snapshot per edition
   - `.logs\registry-backups\script53-*.json`  --  per-key change rows (audit trail)
   - `.logs\vs-code-folder-+-background-context-menu-repair.json`  --  full run log
