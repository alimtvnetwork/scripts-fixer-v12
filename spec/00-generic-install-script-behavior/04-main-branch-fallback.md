# 04 — Main-Branch Fallback

## When main is allowed

Only when **all** of these are true:

1. Strict release-tag mode is **not** active (see `03-strict-release-mode.md`).
2. Entry point is `quick-install.ps1` / `quick-install.sh` or the legacy
   `install.ps1` / `install.sh`.
3. Either:
   - the chosen repo has no published release **and** the user has not
     opted out of main fallback (`--no-main-fallback`), or
   - the user explicitly passed `--main` / `-Main`.

## When main is forbidden

- `release-install.*` entry points.
- `--release`, `-Release`, or `SCRIPTS_FIXER_RELEASE=1` in scope.
- URL contained `/releases/download/`.
- `--no-main-fallback` / `SCRIPTS_FIXER_NO_MAIN=1`.

If forbidden and no release exists, exit code `2` with
`[FAIL] no-release-available`.

## Safety rails when main IS used

- Always log `[NOTICE] using-main-branch` so the user sees it in the
  banner.
- Pin the commit by recording `git rev-parse HEAD` into
  `.resolved/install-source.json`:
  ```json
  {
    "source": "main",
    "owner": "alimtvnetwork",
    "repo": "scripts-fixer-v9",
    "ref": "main",
    "commit": "abc123...",
    "resolvedAt": "2026-04-23T10:00:00+08:00"
  }
  ```
- This file is consumed by `error-manage` and `audit` for diagnostics.

## Re-runs

If `.resolved/install-source.json` exists from a previous main install
and the user runs again without flags, prefer the same mode (main) and
log `[RESUME] previous-mode-main`. Override with `--release` to switch.