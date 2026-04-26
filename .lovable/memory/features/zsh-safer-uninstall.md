---
name: Safer ZSH uninstall (script 62)
description: 62-install-zsh-clear restores newest ~/.zsh-backups/<TS>/.zshrc and surgically strips ONLY marker-bounded blocks (60 extras + 61 switcher). Aggressive ops (~/.oh-my-zsh removal, chsh, apt purge) are opt-in via flags.
type: feature
---
## Default behaviour (safe)

`62 install` does, in order:
1. **Pre-clear safety backup** -> `~/.zsh-backups/pre-clear-<TS>/.zshrc`
2. **Restore** newest non-`pre-clear-*` backup's `.zshrc` (selectable via `--backup=<TS>`)
3. **Strip** every marker-bounded block listed in `config.json:marker_pairs[]`:
   - `# >>> lovable zsh extras >>>` ... `# <<< lovable zsh extras <<<` (60)
   - `# >>> lovable zsh-theme switcher >>>` ... `# <<< ... <<<` (61)
4. **Clear install markers** `.installed/{60,61,62}.ok`

Never touches `~/.oh-my-zsh`, never `chsh`, never `apt purge` in safe mode.

## Aggressive opt-ins (off by default)

CLI flags OR `config.json:aggressive.*`:

| Flag                  | Effect                              |
|-----------------------|-------------------------------------|
| `--remove-omz`        | `rm -rf ~/.oh-my-zsh`               |
| `--remove-zshrc`      | `rm -f ~/.zshrc`                    |
| `--restore-shell`     | `chsh -s $restore_shell_path`       |
| `--remove-zsh-pkg`    | `apt-get purge -y zsh`              |
| `--no-restore`        | skip step 2 (strip-in-place only)   |
| `--backup=<sel>`      | `latest` | `<TS>` | abs path         |

## Marker strip (awk)

Deletes `BEGIN..END` inclusive; handles **multiple occurrences** (verified).
Uses `awk` not `sed` so multi-line spans across the file work cleanly.
Pre-clear safety backup is excluded from the "newest" picker via
`! -name 'pre-clear-*'`.

## Verbs

| Verb            | Action                                                       |
|-----------------|--------------------------------------------------------------|
| `install`       | safe restore + strip (default)                               |
| `check`         | exit 1 + names residual marker blocks                        |
| `strip`         | marker strip only (no restore)                               |
| `restore [SEL]` | restore .zshrc only (no strip), SEL=latest|<TS>|abs path     |
| `list-backups`  | newest-first table with zshrc-presence column                |
| `repair`        | rerun install                                                |
| `uninstall`     | clears 62.ok marker only                                     |

## Critical impl detail

Helper functions invoked in `$(...)` (e.g. `pick=$(choose_backup_dir ...)`)
MUST emit warnings to **stderr** (`log_warn ... >&2`) -- otherwise the
warning text is captured into the variable and silently dropped.

## Tests

`scripts-linux/62-install-zsh-clear/tests/test-clear.sh` -- **28 assertions**
across 6 fixtures: restore+strip happy path, --no-restore preservation of
non-marker user lines, check verb (clean + residual), duplicate marker
blocks, list-backups + restore <TS>, no-backup-root graceful path.

Built: v0.121.0
