62-install-zsh-clear  (safer ZSH uninstall)
============================================

A safety-first uninstaller for the 60+61 ZSH stack. Two operations by default,
both non-destructive to anything you didn't deploy via lovable scripts:

  1. RESTORE -- copies the newest ~/.zsh-backups/<TS>/.zshrc back into
                ~/.zshrc (the same backup script 60 made before installing).
  2. STRIP   -- surgically removes ONLY the marker-bounded blocks deployed
                by 60-install-zsh and 61-install-zsh-theme-switcher:
                  # >>> lovable zsh extras >>>     ... # <<< lovable zsh extras <<<
                  # >>> lovable zsh-theme switcher >>> ... # <<< ... <<<
                Everything outside those markers is left untouched.

Before doing anything, it ALWAYS makes a fresh safety copy at
  ~/.zsh-backups/pre-clear-<TIMESTAMP>/.zshrc
so you can roll back even from a botched restore.

What it WILL NOT do unless you ask
----------------------------------
  - Delete ~/.oh-my-zsh           -> --remove-omz
  - Delete ~/.zshrc               -> --remove-zshrc
  - Restore default shell (chsh)  -> --restore-shell
  - apt-get purge zsh             -> --remove-zsh-pkg

Interactive prompt (default ON)
-------------------------------
On a TTY, `install` and `restore` show a side-by-side summary of:
  - your CURRENT ~/.zshrc  (size, line count, mtime, first non-blank line)
  - the SELECTED backup    (every file in the backup dir + zshrc preview)
then ask:
  [R]estore from backup  (default; press Enter)
  [K]eep current         (still strip marker blocks)
  [D]iff                 (unified diff, loops back to prompt)
  [A]bort                (no changes other than the pre-clear safety backup)

Skip flags:
  --yes, -y       always restore, never prompt
  --no-prompt     always keep current ~/.zshrc, never prompt

Disable globally via config.json: "interactive_by_default": false.

Quick start
-----------
  scripts-linux/run.sh -I 62 install              # safe: restore + strip
  scripts-linux/62-install-zsh-clear/run.sh check # report residual markers
  scripts-linux/62-install-zsh-clear/run.sh list-backups
  scripts-linux/62-install-zsh-clear/run.sh restore latest        # prompts
  scripts-linux/62-install-zsh-clear/run.sh restore latest --yes  # no prompt
  scripts-linux/62-install-zsh-clear/run.sh restore 20260426-124557
  scripts-linux/62-install-zsh-clear/run.sh strip
  # Aggressive (opt-in):
  scripts-linux/62-install-zsh-clear/run.sh install --remove-omz --restore-shell

Verbs
-----
  install         restore newest backup + strip marker blocks (safe default)
  check           report any residual lovable marker blocks in ~/.zshrc
  strip           strip marker blocks only (no restore)
  restore [SEL]   restore .zshrc from backup (SEL = latest | <TIMESTAMP> | <abs path>)
  list-backups    list ~/.zsh-backups/* with zshrc presence
  repair          re-run install
  uninstall       clears 62's own install marker

Files
-----
  config.json       behaviour + marker pairs + aggressive defaults
  log-messages.json catalog of log strings
  run.sh            implementation
