# Generic Install-Script Behavior — Cross-Repo Spec

**Status:** Draft v1 (defaults locked, ready for implementation)
**Scope:** Applies to every repo in the `<base>-v<N>` family that ships
`quick-install`, `release-install`, or `error-manage` entry points.
**Defaults locked on:** 2026-04-23 (Malaysia, UTC+8).

## What this spec replaces

- The single-purpose `spec/install-bootstrap/readme.md` (still valid for
  the `install.ps1` bootstrap, but narrower in scope).
- Ad-hoc per-repo behaviors for `release-install`, `quick-install`, and
  `error-manage`. From v0.75.0 onward, all three obey this spec.

## File index

| # | File | Purpose |
|---|------|---------|
| 01 | `01-readme.md` | This document — overview + locked defaults |
| 02 | `02-discovery.md` | Fixed v1..v20 window, HEAD probe, redirect rules |
| 03 | `03-strict-release-mode.md` | When release-tag mode triggers + behavior |
| 04 | `04-main-branch-fallback.md` | When main is used + safety rails |
| 05 | `05-commands.md` | `quick-install` / `release-install` / `error-manage` contracts |
| 06 | `06-flags-env-vars.md` | All flags, env vars, and precedence |
| 07 | `07-implementation-checklist.md` | Migration steps for each existing repo |

## Locked defaults (from user, 2026-04-23)

| Decision | Value |
|----------|-------|
| Discovery range | **Fixed window v1..v20** (not relative `current..current+20`) |
| Probe mechanism | **HTTP HEAD** with 5s timeout, parallel |
| Probe target | `https://github.com/<owner>/<base>-v<N>` (200 = exists) |
| On newer found | **Auto-redirect** to highest live version |
| On no newer found | **Log only** (`[VERSION]`, `[RESOLVED]`), continue with current |
| Strict release-tag mode | Triggered by `release-install`, `--release` flag, `SCRIPTS_FIXER_RELEASE` env, or any URL containing `/releases/download/` |
| Main-branch fallback | Allowed for `quick-install` only; **forbidden** for `release-install` |
| Loop guard | `SCRIPTS_FIXER_REDIRECTED=1` after one hop |
| Spec file layout | `spec/00-generic-install-script-behavior/NN-name.md`, numbered |

## Non-goals

- Does **not** cover the per-script installers under `scripts/NN-install-*`.
- Does **not** replace `spec/install-bootstrap/readme.md` for the
  bootstrap's internal algorithm — that doc stays authoritative for the
  HEAD-probe parallelization details.
- Does **not** auto-upgrade installed tools; only the bootstrap entry
  point is redirected.

## Versioning

Bump the parent project minor version any time this spec changes a
default. Document the change in `changelog.md` under the matching
release.

## Pending issue closure

This spec resolves
`.lovable/pending-issues/01-generic-install-spec-awaiting-confirmation.md`.
The 15-item checklist is folded into the locked-defaults table above.
Mark the pending issue as `resolved` after merging.