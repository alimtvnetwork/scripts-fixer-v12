# 01 — "Add separate shell scripts to create Unix groups from JSON and CLI"

- **Logged on:** 2026-04-26 (UTC+8)
- **Triggering task:** *"Add separate shell scripts to create Unix groups from both JSON and direct CLI arguments, and wire them into the root orchestrator."*
- **Original spec reference:** chat message immediately preceding this entry; project context = `scripts-linux/68-user-mgmt/`.
- **Mode:** No-Questions (task **1 of 40**)

## The point of confusion

`scripts-linux/68-user-mgmt/` ALREADY ships:
- `add-group.sh`           — direct CLI flags (`--gid`, `--system`, `--dry-run`)
- `add-group-from-json.sh` — bulk JSON (single object / array / `{groups:[...]}`)

So "add separate shell scripts" is already physically true. The unclear
part is whether the user wants:

1. **A brand-new standalone script (e.g. 69-group-mgmt)** with its own
   `run.sh`, `config.json`, `log-messages.json`, registry entry — i.e. a
   parallel codepath living outside script 68.
2. **Reuse the existing pair inside script 68** and only add the missing
   piece: top-level shortcuts in the root `scripts-linux/run.sh` so the
   user can call them directly (e.g. `./run.sh add-group devs --gid 2000`,
   `./run.sh add-groups-from-json file.json`). The two `.sh` files already
   exist — only the wiring is missing.
3. **Both** — keep the helpers inside 68 AND expose root shortcuts.

## Options considered

### Option A — New script slot (e.g. 69-group-mgmt)
- **What it means:** Create `scripts-linux/69-group-mgmt/` with its own
  `add-group.sh`, `add-group-from-json.sh`, `run.sh`, `config.json`,
  `log-messages.json`; register in `registry.json`; add root shortcuts.
- **Pros:** Clean separation; matches the "every numbered folder is one
  feature" registry pattern.
- **Cons:** Duplicates ~95% of the helper code already in
  `68-user-mgmt/helpers/_common.sh` (`um_detect_os`, `um_require_root`,
  `um_group_exists`, `um_run`, `um_summary_*`, `um_msg`). Splits user
  and group management across two scripts even though they share state.
  Drift risk: future fixes to the user side won't reach the group side.

### Option B — Wire existing 68 scripts into root only
- **What it means:** Leave `68-user-mgmt/add-group*.sh` exactly where they
  are (they already exist as separate files). Add top-level shortcuts in
  `scripts-linux/run.sh`:
    - `./run.sh add-group <name> [--gid N] [--system] [--dry-run]`
    - `./run.sh add-groups-from-json <file.json> [--dry-run]`
    - aliases: `group-add`, `groups-from-json`
  Update root `--help`. No new script slot, no registry change.
- **Pros:** Zero duplication. Honors the existing 68 architecture and
  the shared `_common.sh` helpers. Smallest, safest diff. The literal
  wording "wire them into the root orchestrator" is satisfied directly.
- **Cons:** No new numbered script — if the user expected a new slot they
  won't see one.

### Option C — Both (new slot AND root shortcuts)
- **What it means:** Option A + Option B simultaneously.
- **Pros:** Maximum surface area.
- **Cons:** Worst of both — duplicate code AND duplicate UX paths. The
  toolkit already had this discussion when 68 was created (it consolidated
  user+group into one slot intentionally). Going back on that without a
  trigger would churn registry numbering.

## Recommendation

**Option B.** The phrase "wire them into the root orchestrator" is the
only operational gap right now: the scripts exist as separate files,
share helpers cleanly, and just need entry points in `scripts-linux/run.sh`.
This avoids duplicating `_common.sh` and matches how scripts 64/65/66/67
are exposed (top-level verb shortcuts, no extra numbered folder).

## Inference actually used in this task

Implementing **Option B**:
1. Add root shortcuts in `scripts-linux/run.sh`:
   - `add-group` / `group-add` -> `68-user-mgmt/add-group.sh`
   - `add-groups-from-json` / `groups-from-json` -> `68-user-mgmt/add-group-from-json.sh`
2. Pass through every remaining argument unchanged.
3. Document in root `--help`.
4. Smoke-test with `--help` and `--dry-run`.

If the user later wants the standalone slot (Option A), it's a pure
additive change: new folder + registry entry; the root shortcuts can keep
pointing at 68 or be repointed in one line.

## How to revert / change course

- Revert: delete the two `case` arms added to `scripts-linux/run.sh` and
  the matching `--help` lines.
- Switch to Option A later: add `scripts-linux/69-group-mgmt/` (clone the
  68 layout), add a registry entry, repoint the two root case arms to the
  new path. No data migration — group state lives in `/etc/group`, not
  in the repo.