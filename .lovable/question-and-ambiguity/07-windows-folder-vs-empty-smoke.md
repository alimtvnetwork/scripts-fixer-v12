# 07 — Windows smoke test: folder vs empty-folder context menu

**Spec reference:** "Create a small Windows smoke-test script that
installs or repairs the VS Code folder context menu and verifies the
registry entries for folder vs empty-folder behavior."

## Point of confusion

Script 10 already ships `tests/smoke-install-check.ps1`, which drives
`install` then `check` and asserts the existing `check` verb returns
the right exit-code buckets. That covers many invariants but it does
**not** explicitly differentiate the two distinct shell hives that
power "right-click on a folder" vs "right-click in an empty folder
window":

| User gesture                                  | Hive                                           | %V means          |
|-----------------------------------------------|------------------------------------------------|-------------------|
| Right-click ON a folder in Explorer           | `HKCR\Directory\shell\<Name>`                  | clicked folder    |
| Right-click in the empty area of an open dir  | `HKCR\Directory\Background\shell\<Name>`       | current folder    |

If only one of the two is wired the menu silently misbehaves
(folder-on-folder works but empty-area doesn't, or vice versa). The
spec's emphasis on **"folder vs empty-folder behavior"** is what
distinguishes this request from the existing `smoke-install-check.ps1`.

Two reasonable interpretations:

- **Option A — extend the existing smoke script** with extra cases
  per hive. _Pro:_ no new file. _Con:_ that script is already long,
  and the new assertions are conceptually distinct (per-hive value
  comparison vs whole-script exit-code bucket).
- **Option B — new focused smoke script (chosen).** A short, single-
  purpose `smoke-folder-vs-empty.ps1` that does only what the spec
  asked: install (or `-RepairOnly`), then read the two registry keys
  and assert key-presence + label + Icon + `\command` for **each
  hive separately** per enabled edition, plus the file-target-absent
  invariant. Easy to invoke standalone for triage.

## Recommendation / inference used

**Option B.** Created
`scripts/10-vscode-context-menu-fix/tests/smoke-folder-vs-empty.ps1`:

- Pre-flight: requires Admin (waivable with `-DryRun` or `-SkipMutate`),
  validates `run.ps1` + `config.json`, honours `enabledEditions` and
  the optional `-Edition` filter.
- Step 1: drives `run.ps1 install` (or `repair` if `-RepairOnly`).
- Step 2: per edition, asserts for **both** `Directory\shell\<Name>`
  (FOLDER) and `Directory\Background\shell\<Name>` (EMPTY) that:
  key exists, `(Default)` == `contextMenuLabel`, `Icon` is set and
  resolves to a real file, `\command` `(Default)` matches
  `"<exe>" "%V"` using the resolved per-installationType exe.
- Final invariant: `HKCR\*\shell\<Name>` (file-target) is **absent**.
- Every FAIL line includes the exact registry path + actionable fix
  hint, per the project's CODE RED rule.
- Exit codes: 0 all-pass · 1 any-fail · 2 pre-flight failure.
- Renamed `$args` → `$verbArgs` to avoid colliding with PowerShell's
  automatic `$args` under `Set-StrictMode -Version Latest`.

## How to revert

Delete `scripts/10-vscode-context-menu-fix/tests/smoke-folder-vs-empty.ps1`.
The existing `smoke-install-check.ps1` is untouched.