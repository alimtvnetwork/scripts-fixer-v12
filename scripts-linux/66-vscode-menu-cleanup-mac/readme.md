# 66-vscode-menu-cleanup-mac

macOS-only surgical cleanup of the "registry-equivalent" surfaces that VS
Code uses on macOS. There is no Windows-style registry on macOS, so this
script targets the *functional* equivalents users see in Finder and at
login:

| Surface | macOS location | Mode |
|---|---|---|
| Finder Quick Actions / Services | `~/Library/Services/*Code*.workflow` | `glob` |
| User LaunchAgents | `~/Library/LaunchAgents/*.plist` (filtered: must reference Code.app) | `launchctl` |
| System LaunchAgents | `/Library/LaunchAgents/*.plist` (sudo) | `launchctl` |
| LaunchDaemons | `/Library/LaunchDaemons/*.plist` (sudo, system domain) | `launchctl` |
| Login Items | `System Events` open-at-login list | `loginitem` |
| Shell shims (user) | `~/.local/bin/code`, `~/bin/code` (and `code-insiders`) | `shim` |
| Shell shims (system) | `/usr/local/bin/code`, `/opt/homebrew/bin/code` (sudo) | `shim` |
| URL handlers | `vscode://` / `vscode-insiders://` LaunchServices bindings | `lsregister` |

Path allow-list lives in `config.json::targets.{user|system}` -- nothing
outside that file is ever touched (CODE RED safety: surgical, never
enumerative).

## Usage

```bash
# preview
scripts-linux/run.sh 66 --dry-run

# apply (user scope -- safe default, no sudo needed)
scripts-linux/run.sh 66

# include /Library, /usr/local, /opt/homebrew
sudo scripts-linux/run.sh 66 --system

# limit to one or two surfaces
scripts-linux/run.sh 66 --only services,loginitems --dry-run

# limit to one VS Code edition
scripts-linux/run.sh 66 --edition insiders --dry-run

# list every defined category
scripts-linux/run.sh 66 list
```

## Safety guarantees

- Apply by default (matches script 65). `--dry-run` previews every path,
  launchctl label, and LaunchServices handler that *would* be touched.
- Shim removal first inspects the file/symlink and only deletes if it
  references `Code.app` / `Code - Insiders.app` -- a stray `code` script
  that does something else is **kept**, not deleted.
- LaunchAgent / LaunchDaemon plists are removed only when their content
  references `Code.app`, `Code - Insiders.app`, `/code`, or `/code-insiders`.
- System scope is opt-in: pass `--system` (or run as root). The default
  `auto` scope picks `system` only when the script is already running as
  root, otherwise it stays in `user`.
- Per-run logs + manifest land in `.logs/66/<TS>/{command.txt, rows.tsv,
  manifest.json}`; the manifest schema mirrors script 65 so a single
  parser can consume both.

## Per-run output

- `command.txt` -- exact invocation (for forensic re-runs).
- `rows.tsv`    -- one row per action (`status \t id \t kind \t target \t detail`).
- `manifest.json` -- structured summary with totals and the same row data.

## Exit codes

- `0` clean run (apply or dry-run).
- `1` completed but at least one delete/unload/unregister failed.
- `2` precondition failure (config missing, wrong OS, invalid scope).