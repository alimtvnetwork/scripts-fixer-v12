---
name: Remote runner (script 63)
description: 63-remote-runner runs commands on multiple SSH hosts. Inventory in config.json with hosts[]+groups{}+defaults{}; password (sshpass) by default with prompts; key auth supported; targets all/group:X/host:Y/<bare>; parallel mode; per-session logs; auto chmod 600 + auto .gitignore.
type: feature
---
## scripts-linux/63-remote-runner/

Bootstrap (creates `config.json` from `config.sample.json`, chmod 600,
adds to project `.gitignore`):
  scripts-linux/run.sh -I 63 install

Verbs:
  run.sh run <target> -- "<cmd>" [--parallel N] [--dry-run]
  run.sh list           # show hosts + groups
  run.sh check [target] # tcp-ping reachability via /dev/tcp
  run.sh help

Targets:
  all          -- groups.all (or every host[].name if groups.all undefined)
  group:<name> -- groups.<name>
  host:<name>  -- single host by name
  <bare-name>  -- group first, fallback host

## Auth model

Per-host `auth` overrides `defaults.auth`:
- `password` -- uses `sshpass`. Reads from host.password / defaults.password.
  If empty, prompts interactively (terminal echo disabled).
  Password passed via `SSHPASS` env var, NEVER on argv (no `ps` leak).
- `key` -- uses `ssh -i <identity_file>`. `~` expanded to `$HOME`.

`defaults.strict_host_key_checking` is `false` by default (lab-friendly).

## Security hardening (every run)

- `chmod 600 config.json` -- file holds plaintext passwords.
- Auto-add `scripts-linux/63-remote-runner/config.json` to project `.gitignore`
  (walks up from $ROOT to find the gitignore).
- Sample file is `config.sample.json` (safe to commit, marked "CHANGE_ME").

## Parallel mode

`--parallel N` runs up to N hosts concurrently via background jobs +
`wait -n`; per-host exit codes captured via tmpfiles. Default N=1 (serial).
Auto-disabled in `--dry-run` (which is sequential).

## Session logs

Every `run` writes `scripts-linux/.logs/63/<TS>-<target>.log` with one
`## [host] exit=N dur=Ns` block per host containing full stdout+stderr.

## Bugs found + fixed during build

1. **Empty fields collapsed when reading TSV** (e.g. host with empty
   `identity_file` shifted next field into wrong slot). Fixed by emitting
   one field per LINE from jq and reading via 8 separate `IFS= read -r`
   calls instead of `IFS=$'\t' read`. Affected `run_on_host` + `verb_check`.
2. **Flag parser stopped at `--`** so `run target -- "cmd" --dry-run`
   treated `--dry-run` as part of the command. Replaced with two-pass
   parser: pass 1 collects flags + splits positionals at `--`; pass 2
   sets target + cmd. Flags now valid in any position.

Spec: `.lovable/specs/01-zsh-and-remote-runner-spec.md`
Built: v0.117.0
