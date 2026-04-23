# 03 — Strict Release-Tag Mode

## Purpose

Guarantees reproducible installs by pinning to a published GitHub
Release tag. Disables main-branch fallback entirely.

## Triggers (any one activates strict mode)

1. The entry point is `release-install.ps1` / `release-install.sh`.
2. Flag passed: `-Release` (PowerShell) or `--release` (Bash).
3. Env var set: `SCRIPTS_FIXER_RELEASE=1`.
4. The bootstrap URL itself contains `/releases/download/` (i.e. user
   piped from a release asset URL).

## Behavior under strict mode

- **Discovery still runs** (v1..v20 HEAD probes), but the redirect
  target must also have a **published Release**. If the highest live
  repo has no release, fall back to the next-highest that does.
- **Main-branch fallback is forbidden.** If no v1..v20 candidate has a
  release, log `[FAIL] no-release-available` and exit code `2` —
  do **not** silently install from main.
- The clone step uses `git clone --depth=1 --branch <tag>` of the
  resolved release tag, not `main`.
- All redirected hops carry `SCRIPTS_FIXER_RELEASE=1` forward so the
  newer repo also runs in strict mode.

## Tag selection within a chosen repo

1. Query `GET https://api.github.com/repos/<owner>/<base>-v<N>/releases/latest`.
2. If 404, query `/releases` and pick the highest semver tag that is
   not marked `prerelease` and not `draft`.
3. If still nothing, treat repo as "no release available" and move on.

## Logging

| Prefix | When |
|--------|------|
| `[STRICT]` | Strict mode activated, with trigger reason |
| `[TAG]` | Resolved release tag for the chosen repo |
| `[FAIL]` | No release available — exit 2 |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Installed from a release tag |
| `2` | Strict mode could not find any release in v1..v20 |
| `3` | Network failure during release lookup (after retries) |