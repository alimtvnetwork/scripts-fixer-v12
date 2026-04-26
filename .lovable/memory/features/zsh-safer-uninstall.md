---
name: Safer ZSH uninstall (script 62)
description: 62-install-zsh-clear restores newest ~/.zsh-backups/<TS>/.zshrc and surgically strips ONLY marker-bounded blocks (60+61). Interactive R/K/D/A prompt with side-by-side current-vs-backup manifest; --yes / --no-prompt skip flags. Aggressive ops opt-in via flags.
type: feature
---
## Default behaviour (safe)

`62 install` does, in order:
1. **Pre-clear safety backup** -> `~/.zsh-backups/pre-clear-<TS>/.zshrc`
   Manifest of backed-up files (size + line count + mtime) is printed to stderr.
2. **Restore** newest non-`pre-clear-*` backup's `.zshrc` (selectable via `--backup=<TS>`)
   On a TTY, prompts the user with side-by-side summary of CURRENT vs SELECTED:
   `[R]estore (default)  [K]eep current  [D]iff (loops)  [A]bort`
3. **Strip** every marker-bounded block listed in `config.json:marker_pairs[]`:
   - `# >>> lovable zsh extras >>>` ... `# <<< lovable zsh extras <<<` (60)
   - `# >>> lovable zsh-theme switcher >>>` ... `# <<< ... <<<` (61)
4. **Clear install markers** `.installed/{60,61,62}.ok`

Never touches `~/.oh-my-zsh`, never `chsh`, never `apt purge` in safe mode.
If user picks [K]eep, marker-strip still runs. If [A]bort, only the
pre-clear safety backup remains; ~/.zshrc is unchanged.

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
| `--yes`, `-y`         | skip prompt, always RESTORE         |
| `--no-prompt`         | skip prompt, always KEEP current    |

## Marker strip (awk)

Deletes `BEGIN..END` inclusive; handles **multiple occurrences** (verified).
Uses `awk` not `sed` so multi-line spans across the file work cleanly.
Pre-clear safety backup is excluded from the "newest" picker via
`! -name 'pre-clear-*'`.

## Interactive prompt

`prompt_restore_decision()` reads the keystroke from `/dev/tty` (works
even when stdout is piped). The prompt UI is rendered to **stderr** so
the function's stdout carries only the decision string
(`restore | keep | abort`) for capture by `decision=$(...)`.

Decision precedence:
`--yes` > `--no-prompt` > non-TTY (default RESTORE) > TTY interactive prompt.

## list-backups (enriched)

Now shows: dir name | `zshrc:yes/no` | file count | zshrc size.

## Verbs

| Verb            | Action                                                       |
|-----------------|--------------------------------------------------------------|
| `install`       | safe restore + strip (default; prompts on TTY)               |
| `check`         | exit 1 + names residual marker blocks                        |
| `strip`         | marker strip only (no restore)                               |
| `restore [SEL]` | restore .zshrc only (no strip; prompts on TTY)               |
| `list-backups`  | newest-first table: dir, zshrc, file count, zshrc size       |
| `repair`        | rerun install                                                |
| `uninstall`     | clears 62.ok marker only                                     |

## Critical impl detail

Helper functions invoked in `$(...)` (e.g. `pick=$(choose_backup_dir ...)`)
MUST emit warnings to **stderr** (`log_warn ... >&2`) -- otherwise the
warning text is captured into the variable and silently dropped.
The same rule applies to `prompt_restore_decision`: ALL log calls and the
prompt UI go to stderr; only `echo restore|keep|abort` reaches stdout.

## Tests

- `tests/test-clear.sh` -- 28 assertions across 6 fixtures (restore+strip,
  --no-restore, check, duplicate markers, list-backups + restore <TS>,
  no-backup-root).
- `tests/test-prompts.sh` -- 25 assertions across 8 fixtures (--yes,
  --no-prompt, non-TTY default, simulated 'k' via PTY, pre-clear manifest
  visible, list-backups enriched columns, restore --no-prompt declined,
  bare-install CI no-regression).

Built: v0.122.0 (interactive prompts added)
