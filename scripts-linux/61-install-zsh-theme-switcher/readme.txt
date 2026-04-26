61-install-zsh-theme-switcher
=============================

Wires a `zsh-theme` shell command into your ~/.zshrc so you can switch
Oh-My-Zsh themes interactively from the terminal prompt.

Quick start
-----------
  scripts-linux/run.sh -I 61 install
  exec zsh                # reload shell
  zsh-theme               # interactive numbered menu
  zsh-theme agnoster      # switch immediately
  zsh-theme --random      # surprise me
  zsh-theme --list        # show all configured themes
  zsh-theme --current     # print current ZSH_THEME

run.sh verbs
------------
  install                 Inject the `zsh-theme` function into ~/.zshrc
                          (idempotent; uses begin/end markers).
                          Optional flags:
                            --theme <name>   set ZSH_THEME after wiring
                            --no-prompt      bypass theme-list validation
  check                   Verify the wiring block + ZSH_THEME line are present
  switch <name>           Change ZSH_THEME from outside zsh
                            --force          bypass validation against config.themes[]
  list                    Print configured themes
  repair                  Remove wiring block + reinstall
  uninstall               Remove wiring block (ZSH_THEME line preserved)

Examples
--------
  scripts-linux/run.sh -I 61 install --theme bira --no-prompt
  scripts-linux/61-install-zsh-theme-switcher/run.sh switch agnoster
  scripts-linux/61-install-zsh-theme-switcher/run.sh switch p10k --force

Files
-----
  run.sh                          Main entry (install/check/switch/list/...)
  config.json                     Curated theme list, default theme, markers
  payload/zsh-theme-fn.zsh        The zsh function injected into ~/.zshrc
  log-messages.json               Centralized log strings

Behaviour notes
---------------
  - Idempotent: re-running `install` won't duplicate the block (markers).
  - Backs up ~/.zshrc to ~/.zshrc.backup-<TS> on first install.
  - Creates a minimal ~/.zshrc if missing (run script 60 for the full one).
  - Soft-skips when Oh-My-Zsh isn't installed: wiring still happens; theme
    will activate as soon as OMZ is present.
  - Preserves your ZSH_THEME line on `uninstall`.

let's start now 2026-04-26 17:45 (UTC+8)
