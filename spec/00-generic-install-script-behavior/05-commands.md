# 05 — Command Contracts

Three top-level entry points obey this spec. Each is a thin shell that
sources the shared discovery + mode resolution, then dispatches.

## `quick-install`

- **Files:** `quick-install.ps1`, `quick-install.sh`
- **Default mode:** non-strict, main-branch fallback **allowed**
- **Discovery:** v1..v20 HEAD probe, auto-redirect to highest live repo
- **Use case:** "Just install the latest, fastest path."
- **Exit codes:** `0` ok, `1` clone/install failure, `3` network failure

## `release-install`

- **Files:** `release-install.ps1`, `release-install.sh`
- **Default mode:** strict release-tag mode (always)
- **Discovery:** v1..v20 HEAD probe, then per-repo release lookup
- **Main-branch fallback:** forbidden
- **Use case:** "I need a reproducible, signed install for production."
- **Exit codes:** `0` ok, `2` no release available, `3` network failure

## `error-manage`

- **Files:** `error-manage.ps1`, `error-manage.sh`
- **Mode:** read-only diagnostics; no install side effects
- **Behavior:**
  1. Read `.resolved/install-source.json` (if present).
  2. Run discovery (v1..v20) **without redirecting** — just report.
  3. Print: current repo, current commit/tag, latest available repo,
     latest available release, drift status (`up-to-date`,
     `newer-repo-available`, `newer-release-available`,
     `running-ahead`, `unknown-offline`).
  4. Print last 10 entries from the most recent log file under
     `.logs/`.
  5. Exit `0` always (read-only).
- **Flags:**
  - `--json` → emit machine-readable report to stdout
  - `--fix` → upgrade to latest by re-invoking `quick-install` (or
    `release-install` if previous mode was strict)

## Cross-command guarantees

- All three commands honor `SCRIPTS_FIXER_NO_UPGRADE=1` (skip
  discovery, behave as if v1..v20 probe found nothing newer).
- All three honor `SCRIPTS_FIXER_PROBE_MAX` for **legacy** callers but
  cap at 20 — fixed window wins. Log `[NOTICE] probe-max-capped`.
- All three write to `.resolved/install-source.json` after a successful
  install (`quick-install`, `release-install`) or skip the write
  (`error-manage`).
- All three set `SCRIPTS_FIXER_REDIRECTED=1` before re-invocation.