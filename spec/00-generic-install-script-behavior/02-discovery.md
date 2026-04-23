# 02 — Discovery: Fixed v1..v20 Window

## Algorithm

1. **Identify current repo** from the bootstrap's hardcoded URL:
   - `owner` = GitHub user/org
   - `base` = repo name minus trailing `-vN`
   - `current` = trailing integer (informational only)
2. **Build candidate list:** `for N in 1..20: candidates += "<base>-v<N>"`.
   This is a **fixed window**, not relative to `current`. A user on v3
   probes the same set as a user on v17.
3. **Parallel HEAD probe** each candidate at
   `https://github.com/<owner>/<base>-v<N>` with a 5-second timeout per
   request.
4. **Pick the highest N** whose HEAD returned `200`.
5. **Compare to current:**
   - `highest > current` → redirect (see §Redirect)
   - `highest == current` → log `[RESOLVED] already-latest`, continue
   - `highest < current` → log `[WARN] running-ahead-of-published`, continue
6. **All probes failed** (network down) → log `[SKIP] discovery-offline`,
   continue with current.

## Redirect rules

- Only one redirect hop per invocation. Set
  `SCRIPTS_FIXER_REDIRECTED=1` before re-invoking.
- If `SCRIPTS_FIXER_REDIRECTED=1` is already set on entry, skip
  discovery entirely.
- Re-invoke the **same entry-point name** (`install.ps1`, `install.sh`,
  `quick-install.ps1`, etc.) on the newer repo's `main` branch — unless
  strict release-tag mode is active (see `03-strict-release-mode.md`).

## Probe parallelism

- **PowerShell 7+:** `Start-ThreadJob` with throttle 20.
- **Windows PowerShell 5.1:** sequential fallback, still bounded to
  v1..v20 (max 20 sequential HEAD requests, ~5s each = bounded ≤100s).
- **Bash:** `xargs -P 20 -I {} curl -fsI --max-time 5 ...`.

## Why fixed window

- Predictable: every user probes the same URL set; easy to debug.
- Bounded: max 20 requests, no risk of runaway probes.
- Matches user clarification on 2026-04-23 (overrides the earlier
  "current+20" wording).

## Logging

| Prefix | When |
|--------|------|
| `[VERSION]` | Print parsed `owner/base/current` |
| `[SCAN]` | Begin parallel probe over v1..v20 |
| `[FOUND]` | One per probe that returned 200 |
| `[RESOLVED]` | Final pick (with version number) |
| `[REDIRECT]` | About to re-invoke a different repo |
| `[SKIP]` | Discovery skipped (loop guard, offline, etc.) |
| `[WARN]` | Anomaly (running-ahead, partial probe failure) |