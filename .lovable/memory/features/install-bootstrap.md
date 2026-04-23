---
name: Install bootstrap auto-discovery
description: install.ps1/install.sh probe parallel for newer scripts-fixer-vN repos, redirect, then fresh-clone. Includes -Version flag.
type: feature
---

# Install Bootstrap Auto-Discovery

## Behavior

`install.ps1` (Windows) and `install.sh` (Unix/macOS) both:

1. **Parse current version** from their own repo URL: `scripts-fixer-vN` → `current = N`
2. **Probe in parallel** v(N+1)..v(N+30) (default; configurable via `SCRIPTS_FIXER_PROBE_MAX`, max 100) — fail-fast HTTP HEAD with 5s timeout
3. **Pick the highest** that returned 200
4. **Redirect** by re-invoking that newer repo's `install.{ps1,sh}` and exiting; sets `SCRIPTS_FIXER_REDIRECTED=1` as loop guard
5. **Else proceed:** remove existing `$HOME/scripts-fixer` (or `$env:USERPROFILE\scripts-fixer`) entirely, fresh `git clone`, hand off to `run.ps1`
6. **Logs** every step with `[VERSION]`, `[SCAN]`, `[FOUND]`, `[OK]`, `[REDIRECT]`, `[RESOLVED]`, `[SKIP]`, `[WARN]` prefixes

## Flags

| Flag | PowerShell | Bash | Effect |
|------|-----------|------|--------|
| Skip auto-upgrade | `-NoUpgrade` | `--no-upgrade` | Stay on current version |
| Diagnostic only | `-Version` | `--version` | Probe latest, print resolution, exit without cloning |

## Env Vars

| Var | Default | Purpose |
|-----|---------|---------|
| `SCRIPTS_FIXER_NO_UPGRADE` | unset | Same as `-NoUpgrade` flag |
| `SCRIPTS_FIXER_PROBE_MAX` | `30` | How many `vN+k` to probe (capped at 100) |
| `SCRIPTS_FIXER_REDIRECTED` | unset | Internal loop guard, set to `1` after one redirect hop |

## Implementation Notes

- **PowerShell:** uses `Start-ThreadJob` for parallel probing when available (PS 7+ / module installed); falls back to sequential on Windows PowerShell 5.1
- **Bash:** uses `xargs -P 20` over `curl -fsI` for parallel HEAD probes
- **Fresh clone:** clears read-only attributes on Windows (handles git pack files) before `Remove-Item -Recurse -Force`. On failure, logs the exact path and tells the user to close terminals/editors. Bash uses `rm -rf` and suggests `sudo rm -rf` on failure.
- **CODE RED compliance:** every file/path failure logs the exact failing folder path per `strictly-avoid.md` #4

## Spec

Full algorithm, edge cases, and reference implementations: `spec/install-bootstrap/readme.md`

## See also (v0.75.0+)

The cross-repo behavior for `quick-install`, `release-install`, and
`error-manage` is now governed by the generic spec at
`spec/00-generic-install-script-behavior/`. Locked defaults: fixed
v1..v20 HEAD probe, auto-redirect, log-only when no newer found,
strict release-tag mode forbids main fallback.
