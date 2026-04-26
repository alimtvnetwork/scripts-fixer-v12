---
name: ZSH validation step (script 60)
description: 60-install-zsh `validate` verb runs ~17 checks (zsh PATH, OMZ paths, theme resolution, custom plugin dirs, plugins=() membership, BEGIN/END marker order); auto-runs after install + repair.
type: feature
---
## Verb

`scripts-linux/60-install-zsh/run.sh validate` -- standalone, also auto-runs at
end of `install` and `repair` (failures logged but do NOT remove install marker).

## Checks (severity)

| # | Check                                | Severity on miss |
|---|--------------------------------------|------------------|
| 1 | `zsh` in PATH                        | FAIL             |
| 2 | `~/.oh-my-zsh` dir                   | FAIL             |
| 3 | `~/.oh-my-zsh/oh-my-zsh.sh`          | FAIL             |
| 4 | `~/.oh-my-zsh/themes/` dir           | FAIL             |
| 5 | `~/.oh-my-zsh/custom/` dir           | FAIL             |
| 6 | `~/.oh-my-zsh/plugins/` dir          | FAIL             |
| 7 | `~/.zshrc` exists                    | FAIL             |
| 8 | `^export ZSH=` line                  | FAIL             |
| 9 | `^ZSH_THEME=` line                   | FAIL             |
| 10| `^plugins=(` line                    | FAIL             |
| 11| `source $ZSH/oh-my-zsh.sh` line      | FAIL             |
| 12| default_theme resolvable (themes/ OR custom/themes/) | WARN |
| 13| active ZSH_THEME == default_theme    | WARN             |
| 14| each `config.json:custom_plugins[].dest` exists | FAIL  |
| 15| each plugin in `plugins=(...)` exists in plugins/ or custom/plugins/ | WARN |
| 16| BEGIN+END extras markers both present (when deploy_extras=true) | FAIL |
| 17| BEGIN line < END line (ordering)     | FAIL             |

Exit 0 = zero FAILs (WARNs allowed). Exit 1 = >=1 FAIL.

## Output format

Colored, one row per check, prefixed `[PASS] [WARN] [FAIL]`, ending with
summary line `validation OK (N checks passed)` or
`validation FAILED (N hard errors)`.

## Tests

`scripts-linux/60-install-zsh/tests/test-validate.sh` -- 16 assertions over
7 fixtures (good, missing zshrc, missing END marker, theme mismatch,
missing plugin clone, missing entrypoint, zsh missing from PATH).
Stubs a fake `zsh` in PATH to keep tests sandbox-portable.

Built: v0.120.0
