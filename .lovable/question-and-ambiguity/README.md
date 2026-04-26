# Question & Ambiguity Index

Tracks every point of unclear requirement or inference made during the
**No-Questions Mode** window (next 40 tasks starting 2026-04-26).

## Rules in effect

1. AI does NOT ask the user clarifying questions.
2. AI proceeds with the best-suited inference and continues working.
3. Every ambiguity is recorded as a separate file:
   `.lovable/question-and-ambiguity/xx-brief-title.md`
   - `xx` = zero-padded sequence starting at `01`.
   - Each file contains: original spec reference, task details, the
     specific point of confusion, every reasonable option with pros/cons,
     the AI's recommendation, and the inference actually used.
4. This README is the master index — every new ambiguity file MUST be
   appended below.
5. Mode resumes (questions allowed again) when the user says
   **"ask question if any understanding issues"** or equivalent.

## Index

| #  | File | Task / Topic | Inference used | Status |
|----|------|--------------|----------------|--------|
| 01 | [01-add-group-shell-scripts.md](./01-add-group-shell-scripts.md) | Add separate shell scripts for Unix group creation (JSON + CLI) and wire into root | **Option B** — kept the existing `68-user-mgmt/add-group*.sh` pair; added `add-group` / `add-groups-from-json` shortcuts (+ aliases) to `scripts-linux/run.sh`; no new script slot or registry entry. | open |
| 02 | [02-user-from-json-ssh-keys.md](./02-user-from-json-ssh-keys.md) | Root Unix script: create user from JSON spec with home dir + password/SSH key handling | **Option C** — extended `68-user-mgmt/add-user{,-from-json}.sh` with `--ssh-key` / `--ssh-key-file` (repeatable) + JSON `sshKeys[]` / `sshKeyFiles[]`; wrote keys to `<home>/.ssh/authorized_keys` (700/600, owned, deduped, fingerprinted, key bodies never logged); added `add-user` / `add-users-from-json` root shortcuts. | open |
| 06 | [06-e2e-matrix-65-66-67.md](./06-e2e-matrix-65-66-67.md) | Add and run an E2E test matrix for scripts 65/66/67 on real Ubuntu and macOS, including dry-run + root-requirement checks | **Option B** — single host-aware matrix at `scripts-linux/_shared/tests/e2e/run-matrix.sh`. Detects `uname`/`id -u`; runs per-folder smoke + sandboxed production dry-runs + OS-guard + root-contract cells; honestly reports `SKIP` (not `PASS`) for cells the current host can't cover. Wired as `run.sh e2e-matrix`. Local verdict on Linux+root: PASS=11 FAIL=0 SKIP=4. | open |
| 07 | [07-windows-folder-vs-empty-smoke.md](./07-windows-folder-vs-empty-smoke.md) | Small Windows smoke-test script that installs/repairs the VS Code folder context menu and verifies registry entries for folder vs empty-folder | **Option B** — new focused `scripts/10-vscode-context-menu-fix/tests/smoke-folder-vs-empty.ps1` that drives `install` (or `-RepairOnly`) then asserts key/label/Icon/\command for both `Directory\shell` (FOLDER, %V=clicked dir) and `Directory\Background\shell` (EMPTY, %V=current dir) per edition, plus file-target-absent invariant. Exit 0/1/2; CODE-RED actionable failure messages with full reg paths. | open |
| 08 | [08-script68-examples-and-readme-parity.md](./08-script68-examples-and-readme-parity.md) | Create missing script-68 example files (users/groups JSON variants) and ensure README examples match exact CLI flags + JSON field names | **Option B** — added 4 missing examples (`group-single.json`, `groups-wrapped.json`, `users-with-keyfiles.json`, `full-bootstrap.json`); added a **Bundled example files** table to readme.md plus a documented section for the unified `--spec` shape consumed by `useradm-bootstrap`. Audited README CLI flags + JSON fields against the leaves: no drift. | open |
| 09 | [09-script65-plan-confirm-verify.md](./09-script65-plan-confirm-verify.md) | Wire plan-then-confirm + final verify into script 65 with per-action summary | **Option B** — reused `_shared/confirm.sh` + `_shared/verify.sh` (same pattern as 66/67). Added opt-in `SW_TARGETS_TSV` per-target emission to sweep helpers; apply mode now does forced-dry-run plan → confirm prompt → apply → verify; summary gained a VERIFIED column + global verify line; manifest gained a `verification` block. Smoke 21/21 PASS. | open |
| 10 | [10-install-bootstrap-version-flag.md](./10-install-bootstrap-version-flag.md) | Verify + implement working `--version` across `install.ps1` / `install.sh` with consistent reporting | **Option B** — pre-existing `--version` only reported bootstrap vN; extended both sides to also fetch + report payload semver from `scripts/version.json`, added matching `--help` / `-Help`, harmonised `[VERSION]` / `[FOUND]` / `[RESOLVED]` labels & order. Verified live against scripts-fixer-v8/v10 under bash and pwsh 7.5.4. | open |

_Append new rows here as ambiguities are logged._