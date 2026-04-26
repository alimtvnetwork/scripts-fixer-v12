# 64-startup-add

Cross-OS startup management on the Unix side (Linux + macOS).
Mirrors the Windows-side `scripts/os/` startup block.

## Subverbs

| Subverb | Purpose |
|---|---|
| `app`    | Register an app to run at user login |
| `env`    | Persist an environment variable (KEY=VALUE) |
| `list`   | List all entries tagged `lovable-startup-*` |
| `remove` | Remove a single entry by name (optionally scoped by `--method`) |

## Methods

### Linux
| Method         | Where it writes                                            | Best for                 |
|----------------|------------------------------------------------------------|--------------------------|
| `autostart`    | `~/.config/autostart/lovable-startup-<name>.desktop`       | Default GUI desktop      |
| `systemd-user` | `~/.config/systemd/user/lovable-startup-<name>.service`    | Headless / server / WSL  |
| `shell-rc`     | Marker block in `~/.zshrc` or `~/.bashrc`                  | Terminal-only login      |

### macOS
| Method         | Where it writes                                            | Best for                 |
|----------------|------------------------------------------------------------|--------------------------|
| `launchagent`  | `~/Library/LaunchAgents/com.lovable-startup.<name>.plist`  | Default — survives reboot|
| `login-item`   | System Events login items (via `osascript`)                | GUI apps that need Dock  |
| `shell-rc`     | Marker block in `~/.zshrc` or `~/.bashrc`                  | Terminal-only login      |

## Examples

```bash
# Add an app with default method (autostart on Linux GUI, launchagent on macOS)
./run.sh -I 64 -- app /usr/local/bin/myapp --name myapp

# Force shell-rc method on Linux
./run.sh -I 64 -- app /usr/bin/tmux --name tmux --method shell-rc

# Add an env var (default scope: user, default method: shell-rc)
./run.sh -I 64 -- env "EDITOR=nvim"
./run.sh -I 64 -- env "PATH_EXTRA=/opt/bin:/usr/local/bin"

# macOS-only: set a var in the live launchd session AND mirror to shell-rc
./run.sh -I 64 -- env "JAVA_HOME=/Library/Java/Home" --method launchctl

# List everything we manage
./run.sh -I 64 -- list

# Remove every entry named "myapp" (across all methods)
./run.sh -I 64 -- remove myapp --all

# Remove only the autostart entry, leave shell-rc intact
./run.sh -I 64 -- remove myapp --method autostart

# Remove a single env var (its line in the env block; block stays for siblings)
./run.sh -I 64 -- remove EDITOR --method shell-rc-env
```

## Tag convention

Every entry this script writes is tagged with the prefix `lovable-startup` so
`list` and `remove` can find them across all 6 methods without false positives:

- File names:    `lovable-startup-<name>.{desktop,service,plist}`
- Plist labels:  `com.lovable-startup.<name>`
- Login items:   `com.lovable-startup.<name>`
- Shell blocks:  `# >>> lovable-startup-<name> (lovable-startup-app) >>>`
- Env block:     `# >>> lovable-startup-env (managed) >>>`

Override with `STARTUP_TAG_PREFIX=...` if you must coexist with other toolkits.

## Headless Linux

By default `systemd --user` units stop when the user logs out. To keep your
startup entry running on a headless server:

```bash
STARTUP_LINGER=1 ./run.sh -I 64 -- app /usr/local/bin/myd --method systemd-user
# (calls `loginctl enable-linger $USER` for you; needs sudo on first run)
```

## Idempotency & file-error rule

- Re-running `app add ...` upserts: it removes the old file/block first.
- All file/path failures call `log_file_error <path> <reason>` so you always
  see the exact path that failed and why (CODE RED rule).
- Sourcing the modified shell-rc is safe: env values are single-quoted with
  the `'\''` idiom so spaces, `:`, `&`, and embedded quotes round-trip exactly.
