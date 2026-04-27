# 65-os-clean (Windows)

**Cross-OS user/system cleanup -- Windows side.** Thin dispatcher that
wraps the existing `scripts/os/run.ps1 clean` flow with a strict
`plan -> confirm -> apply -> verify` lifecycle that mirrors the Linux/
macOS counterpart at `scripts-linux/65-os-clean/`.

## Lifecycle

| Stage | What happens |
|---|---|
| 1. PLAN    | Invokes `scripts/os/run.ps1 clean --dry-run` with any forwarded `--only` / `--skip` / `--bucket` flags. Parses per-category counts from the captured output. |
| 2. CONFIRM | Renders a per-category plan table and prompts the operator to type `yes`. `--yes` skips the prompt. Empty plan exits 0 silently. Non-interactive sessions without `--yes` abort safely. |
| 3. APPLY   | Invokes `scripts/os/run.ps1 clean --yes` for real. Captures rc. |
| 4. VERIFY  | Re-invokes `scripts/os/run.ps1 clean --dry-run`. Any category whose row count drops to 0 = `PASS`. Categories where rows persist = `FAIL(n)`. |

A summary table with `STATUS / CATEGORY / BEFORE / AFTER / VERIFIED`
columns prints at the end, plus a `manifest.json` under
`.logs/65/<TS>/` that contains the plan, apply rc, and per-category
verification.

## Usage

```powershell
.\run.ps1 -I 65                       # plan -> confirm -> apply -> verify
.\run.ps1 -I 65 -- --dry-run          # preview only (no prompt, no apply, no verify)
.\run.ps1 -I 65 -- --yes              # apply without confirmation
.\run.ps1 -I 65 -- --bucket D         # only browser caches
.\run.ps1 -I 65 -- --only chrome,edge # only listed categories
.\run.ps1 -I 65 -- --skip ms-search   # skip listed categories
.\run.ps1 -I 65 -- --json             # also emit a machine-readable summary
.\run.ps1 -I 65 -- --help             # full help including forwarded flags
```

`--dry-run` short-circuits after the PLAN stage -- no prompt is shown,
no deletions happen, no verify pass is run. The Linux side
(`run.sh --dry-run`) behaves identically.

## Per-run artifacts

Every invocation writes to `.logs/65/<TIMESTAMP>/`:

| File           | Contents |
|----------------|----------|
| `command.txt`  | Verbatim args this script received |
| `plan.txt`     | Stdout/stderr from the PLAN dry-run |
| `apply.txt`    | Stdout/stderr from the APPLY pass (skipped on `--dry-run`) |
| `verify.txt`   | Stdout/stderr from the VERIFY dry-run (skipped on `--dry-run`) |
| `manifest.json`| Plan rows, apply rc, per-category verification, totals |

`LOGS_OVERRIDE=<dir>` redirects all of the above to `<dir>` -- used by
the smoke harness so CI never touches the real `.logs/65` tree.

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | All stages succeeded; verify shows zero residue |
| 1    | Operator aborted at confirm prompt (or non-interactive without `--yes`) |
| 2    | Pre-flight failure (delegate missing, log dir un-creatable) |
| 11   | Apply succeeded but verify detected residue in 1+ categories |
| 30   | Delegate threw an unhandled exception |
| other| Propagated exit code from `scripts/os/run.ps1 clean` |

## Forwarded flags (passed to the delegate)

The dispatcher consumes only `--dry-run`, `--yes`, `--json`, `--help`.
Everything else is forwarded verbatim to `scripts/os/run.ps1 clean`,
including `--only`, `--skip`, `--bucket`, `--days`, `--summary-json`,
`--summary-tail`. Run `.\run.ps1 os clean --help` for the full
delegate flag set (59 categories as of v0.48.0).

## Design notes

- **Why dispatch instead of fork?** `scripts/os/run.ps1 clean` already
  ships 59 hand-tuned cleanup helpers under `scripts/os/helpers/clean-categories/`.
  Re-implementing them here would duplicate logic and drift. The
  dispatcher pattern lets script 65 add the lifecycle/verify story
  without touching the underlying helpers.
- **Why dry-run for verify?** The os runner's dry-run mode is the
  single source of truth for "what would still be cleaned" -- so
  re-invoking it after the apply tells us exactly which targets
  were missed (independent of the apply's own self-reported rc).
- **CODE-RED**: every file/path failure logs the exact path + reason,
  per repo policy.

## Related

- `scripts-linux/65-os-clean/` -- POSIX side, identical lifecycle.
- `scripts/os/run.ps1` -- 59-category cleanup engine (delegate).
- `scripts/54-vscode-menu-installer/` -- example of the same router
  pattern at the script-65 level.
