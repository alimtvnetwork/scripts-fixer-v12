---
name: ZSH theme switcher (script 61)
description: 61-install-zsh-theme-switcher wires a `zsh-theme` shell command into ~/.zshrc -- interactive numbered menu, --random, --list, --current; backed by config.json themes[]
type: feature
---
## scripts-linux/61-install-zsh-theme-switcher/

Wires a `zsh-theme` shell function into `~/.zshrc` between unique markers
so users can switch Oh-My-Zsh themes from the terminal prompt.

## Files

| File | Purpose |
|------|---------|
| `run.sh` | verbs: install/check/switch/list/repair/uninstall; install accepts `--theme NAME --no-prompt` |
| `config.json` | curated 34-theme list, default_theme, marker_begin/marker_end, shell_function_name |
| `payload/zsh-theme-fn.zsh` | the zsh function injected into `~/.zshrc`. Must NOT contain marker comments -- the wrapper owns them. Uses `__LOVABLE_CFG_PATH__` placeholder substituted at install time |
| `log-messages.json` | centralized log strings |
| `readme.txt` | user-facing docs |

## Wiring contract

- Markers in `~/.zshrc`:
  - `# >>> lovable zsh-theme switcher >>>`
  - `# <<< lovable zsh-theme switcher <<<`
- `install` is idempotent (skips if begin marker found).
- `install` backs up `~/.zshrc` to `~/.zshrc.backup-<TS>` on first wire-in.
- `install` creates a minimal `~/.zshrc` if missing (so the script works
  before script 60-install-zsh exists).
- `uninstall` strips the block via awk (BEGIN..END inclusive, single block
  only -- payload must not contain extra marker lines).
- ZSH_THEME line is preserved on uninstall.

## User-facing commands (after install + `exec zsh`)

```
zsh-theme              # interactive numbered menu (current theme has *)
zsh-theme agnoster     # switch immediately
zsh-theme --list       # list configured themes
zsh-theme --current    # print current ZSH_THEME
zsh-theme --random     # pick randomly from config.themes[]
zsh-theme --help       # usage
```

## Soft-skip behaviour

If `~/.oh-my-zsh/` is missing, `install` still wires the function and
prints a yellow warning. Theme switching activates as soon as OMZ is
installed (script 60).

## Companion scripts (per spec 01)

- 60-install-zsh         -- not yet built
- 61-install-zsh-theme-switcher -- THIS SCRIPT (built v0.115.0)
- 62-install-zsh-clear   -- not yet built
- 63-remote-runner       -- not yet built

Spec: `.lovable/specs/01-zsh-and-remote-runner-spec.md`
