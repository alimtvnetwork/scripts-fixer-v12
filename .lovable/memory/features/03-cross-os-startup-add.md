---
name: Cross-OS startup-add (script 64)
description: Unix-side startup entry manager covering 6 methods with tag-based enumeration
type: feature
---

# Cross-OS startup-add (`scripts-linux/64-startup-add`)

Mirrors the Windows-side `scripts/os/` startup block. Subverbs: `app`, `env`,
`list`, `remove`. Every entry is tagged with `STARTUP_TAG_PREFIX`
(default `lovable-startup`) so `list`/`remove` can find them deterministically.

## 6 methods

| OS    | App methods                              | Env methods            |
|-------|------------------------------------------|------------------------|
| Linux | `autostart`, `systemd-user`, `shell-rc`  | `shell-rc`             |
| macOS | `launchagent`, `login-item`, `shell-rc`  | `shell-rc`, `launchctl`|

Defaults (when `--method` omitted):
- Linux GUI (`$DISPLAY` or `$WAYLAND_DISPLAY` set) -> `autostart`
- Linux headless                                   -> `systemd-user`
- macOS                                            -> `launchagent`

## File layout

```
scripts-linux/64-startup-add/
  config.json            tag prefix, method matrix, paths, lingerForHeadless
  log-messages.json
  readme.md              full per-method docs + examples
  run.sh                 dispatcher (app|env|list|remove)
  helpers/
    detect.sh            OS + session detection, default method picker
    methods-linux.sh     write_autostart_desktop, write_systemd_user_unit,
                         append_shell_rc_app, write_shell_rc_env (shared)
    methods-macos.sh     write_launchagent_plist, add_login_item,
                         write_launchctl_env (mirrors to shell-rc)
    enumerate.sh         list_startup_entries (TSV), remove_startup_entry
```

## Conventions

- Tag prefix is the single source of truth. File names use
  `lovable-startup-<name>.{desktop,service,plist}`; plist/login labels use
  `com.lovable-startup.<name>`; shell-rc blocks use marker pairs.
- Env values are **single-quoted with the `'\''` idiom** so spaces, `:`,
  `&`, and embedded single quotes survive sourcing. Never use `printf %q`
  here (it breaks when re-injected via awk `-v`).
- macOS plist values are XML-escaped via `sed`, not bash parameter expansion
  (the latter mangled `<`/`>` inside command substitution).
- Idempotent upserts: every `write_*` removes the old artifact first.
- CODE RED: every `rm`/`mv`/`mkdir`/`write` failure path calls
  `log_file_error <path> <reason>`.

## Headless Linux

`STARTUP_LINGER=1` triggers `loginctl enable-linger $USER` when writing a
systemd-user unit, so the unit keeps running after logout.

## Smoke test

```bash
TEST_HOME=$(mktemp -d) HOME=$TEST_HOME bash scripts-linux/64-startup-add/run.sh \
  app /usr/bin/echo --name hello
HOME=$TEST_HOME bash scripts-linux/64-startup-add/run.sh list
HOME=$TEST_HOME bash scripts-linux/64-startup-add/run.sh remove hello --all
```

Verified end-to-end at v0.126.0 (4 entries -> 2 removes -> empty list).
