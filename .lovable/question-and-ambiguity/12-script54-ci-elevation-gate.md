# 12 - Script 54 CI: elevation-gated AllUsers job

**Spec reference:** "Implement a separate CI step that runs Script 54 with
-OnlyScope AllUsers only when elevation is available, and otherwise marks
it as skipped."

## Inference used

Created `.github/workflows/test-script-54.yml` with **two independent
jobs** rather than one job with conditional steps. Two jobs surface
clearly in the GitHub Checks UI -- a skipped AllUsers job is visible at
a glance, while a single-job design would hide the AllUsers result
inside step output.

### Job layout

| Job                   | Always runs? | Scope            | Skip behaviour                                       |
|-----------------------|--------------|------------------|------------------------------------------------------|
| `matrix-currentuser`  | yes          | CurrentUser only | n/a -- HKCU writes never need elevation              |
| `matrix-allusers`     | yes (probes) | AllUsers only    | If runner not elevated: emits `::notice` + `[SKIPPED]` line, exits 0 |

### Elevation probe

The `Probe elevation` step uses `WindowsPrincipal.IsInRole(Administrator)`
and writes `is_admin=true|false` to `$GITHUB_OUTPUT`. The two follow-up
steps gate on that output:

- `Skip notice` runs when `is_admin != 'true'` -- prints a GitHub
  `::notice` annotation AND a `[SKIPPED]` console line so the run log
  matches the harness's own SKIP convention. Exits 0.
- `Run scope matrix (AllUsers only)` runs when `is_admin == 'true'` --
  invokes `run-scope-matrix.ps1 -OnlyScope AllUsers -ReportPath ...`
  and propagates `$LASTEXITCODE`.

### Why not let the harness's exit-3 do the skipping?

`run-scope-matrix.ps1` already exits 3 when `-OnlyScope AllUsers` is
asked but the host isn't elevated. Mapping exit 3 to "skipped" inside
the job would let real elevation-probe bugs (e.g., probe says admin but
the matrix disagrees) silently pass. By probing first and treating
exit 3 as a hard failure inside the gated step, we keep the two
elevation checks honest against each other.

### Hosted runner reality

`windows-latest` GitHub-hosted runners do run as Administrator by
default, so the AllUsers job will normally execute. The skip path
exists for self-hosted runners and any future hosted-runner image
change that drops default elevation.

### Other notes

- File-existence guard before invoking the matrix script -- emits a
  CODE-RED-style `FILE NOT FOUND: <path>` message if the harness is
  missing from the checkout.
- Both jobs upload their `-ReportPath` JSON as a build artifact (30-day
  retention) so the residue ledger from task 11 is reachable from CI.
- Trigger paths scoped to `scripts/54-vscode-menu-installer/**` and the
  workflow file itself, mirroring `test-script-53.yml`.

## Verification

- `python -c "yaml.safe_load(...)"` parses cleanly: 2 jobs,
  CurrentUser=3 steps, AllUsers=5 steps with the expected `if:`
  guards on the skip-notice / matrix / upload steps.
- Confirmed `run-scope-matrix.ps1` already supports
  `-OnlyScope AllUsers` and `-ReportPath` (added in tasks 0 and 11).

## How to revert

Delete `.github/workflows/test-script-54.yml`.
