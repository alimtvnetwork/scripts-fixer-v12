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

_Append new rows here as ambiguities are logged._