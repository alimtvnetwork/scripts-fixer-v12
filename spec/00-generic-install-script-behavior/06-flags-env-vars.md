# 06 — Flags, Env Vars, and Precedence

## Flags

| PowerShell | Bash | Effect | Applies to |
|------------|------|--------|------------|
| `-Release` | `--release` | Force strict release-tag mode | quick-install, error-manage |
| `-Main` | `--main` | Force main-branch even if a release exists | quick-install only |
| `-NoMainFallback` | `--no-main-fallback` | Disallow main fallback | quick-install |
| `-NoUpgrade` | `--no-upgrade` | Skip v1..v20 discovery | all three |
| `-Version` | `--version` | Print resolved version + exit (no install) | all three |
| `-Json` | `--json` | Machine-readable output | error-manage |
| `-Fix` | `--fix` | error-manage: re-invoke installer | error-manage |

## Env vars

| Var | Default | Effect |
|-----|---------|--------|
| `SCRIPTS_FIXER_RELEASE` | unset | `1` = same as `--release` |
| `SCRIPTS_FIXER_NO_UPGRADE` | unset | `1` = same as `--no-upgrade` |
| `SCRIPTS_FIXER_NO_MAIN` | unset | `1` = same as `--no-main-fallback` |
| `SCRIPTS_FIXER_PROBE_MAX` | `20` | Capped at 20 (fixed window). Legacy compatibility only. |
| `SCRIPTS_FIXER_REDIRECTED` | unset | Loop guard, set internally before re-invocation |

## Precedence (highest wins)

1. **Entry-point name** — `release-install` always implies strict mode,
   no flag can disable it. `quick-install` defaults non-strict.
2. **Explicit flags** on the command line.
3. **Env vars** in the current process.
4. **`.resolved/install-source.json`** previous mode (only on re-runs
   without explicit flags).
5. **Spec defaults** (last resort).

## Conflict rules

| Combination | Outcome |
|-------------|---------|
| `--release` + `--main` | **Error** — exit `2`, log `[FAIL] conflicting-modes` |
| `--release` + `--no-main-fallback` | OK (no-op; release mode already forbids main) |
| `--no-upgrade` + `--release` | OK; skip discovery, run release lookup against current repo only |
| `--no-upgrade` + `--main` | OK; skip discovery, run from current repo's main |
| `release-install` invoked + `--main` | **Error** — entry point wins; exit `2` |

## Examples

```powershell
# Strict, latest release across v1..v20
iwr https://.../release-install.ps1 | iex

# Skip discovery, install from current repo's main
iwr https://.../quick-install.ps1 | iex -NoUpgrade

# Diagnostic only
iwr https://.../error-manage.ps1 | iex -Version -Json
```