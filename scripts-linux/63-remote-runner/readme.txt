63-remote-runner
================

Run a command on one host, a group, or every host defined in config.json.
Defaults to PASSWORD auth (sshpass) so you can drive a lab/classroom of
cloud VMs without setting up keys first; supports key auth too.

Quick start
-----------
  scripts-linux/run.sh -I 63 install                  # bootstrap (creates config.json from sample)
  $EDITOR scripts-linux/63-remote-runner/config.json  # add your hosts + passwords
  scripts-linux/63-remote-runner/run.sh list          # show inventory
  scripts-linux/63-remote-runner/run.sh check all     # tcp-ping every host
  scripts-linux/63-remote-runner/run.sh run all -- "hostname && uptime"
  scripts-linux/63-remote-runner/run.sh run group:web -- "sudo systemctl restart nginx"
  scripts-linux/63-remote-runner/run.sh run host:db-1 -- "df -h" --parallel 1

Targets
-------
  all                every host in groups.all (or every host[] if undefined)
  group:<name>       every host name in groups.<name>
  host:<name>        single host by name
  <bare-name>        resolved as group first, else as host

Auth
----
Per-host `auth` overrides `defaults.auth`:
  password   uses sshpass; reads `password` field or prompts interactively
             (terminal echo is disabled while typing)
  key        uses ssh -i <identity_file>  (~ expansion supported)

Flags
-----
  --parallel N    run on up to N hosts at once (default: 1, serial)
  --dry-run       print what would run, do not actually connect

Security
--------
* config.json is chmod 600 on every run.
* config.json is auto-added to the project .gitignore on every run.
* Passwords are passed to sshpass via SSHPASS env var, never on argv
  (so they don't show up in `ps`).
* StrictHostKeyChecking is OFF by default for lab/training. Flip
  defaults.strict_host_key_checking to true for production.
* Password mode is fine for lab/classroom -- prefer key auth in production.

Logs
----
Every `run` writes a per-session log to:
  scripts-linux/.logs/63/<TIMESTAMP>-<target>.log
Each host's full stdout/stderr is captured under a `## [host] exit=N` header.

Files
-----
  run.sh                  Main entry (verbs: install|run|list|check|help)
  config.sample.json      Inventory template -- copy to config.json
  config.json             Your real inventory (auto-created, gitignored, chmod 600)
  log-messages.json       Centralised log strings
  readme.txt              This file

Companion scripts (per spec 01)
-------------------------------
  60-install-zsh                   built v0.116.0
  61-install-zsh-theme-switcher    built v0.115.0
  62-install-zsh-clear             not yet built
  63-remote-runner                 THIS SCRIPT (built v0.117.0)

Spec: .lovable/specs/01-zsh-and-remote-runner-spec.md

let's start now 2026-04-26 18:30 (UTC+8)
