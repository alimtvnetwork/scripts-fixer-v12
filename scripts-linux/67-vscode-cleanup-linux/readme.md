# Script 67 — vscode-cleanup-linux

Detect-and-remove uninstaller for Visual Studio Code on Linux/Ubuntu.

The script first runs a **read-only detect phase** that probes for every
install method this toolkit knows about, then runs an **apply phase** that
removes ONLY the artifacts belonging to the detected methods. Nothing
outside `config.json` is ever touched (CODE RED safety: surgical, never
enumerative).

## Methods detected

| id            | how it's detected                                                                  | what it removes                                                       |
|---------------|------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| `apt`         | `dpkg -s code` succeeds **and** `/etc/apt/sources.list.d/vscode.list` exists      | `apt-get purge code[-insiders]`, vscode.list, `packages.microsoft.gpg`, `apt-get update` |
| `snap`        | `snap list code` (or `code-insiders`) succeeds                                    | `snap remove code[-insiders]`                                         |
| `deb`         | `dpkg -s code` succeeds **but** the MS apt source file is **absent**              | `dpkg -r code[-insiders]` only                                        |
| `tarball`     | One of `/opt/VSCode-linux-*`, `/opt/visual-studio-code`, `~/.local/share/code`     | extract dir, `/usr/local/bin/code{,-insiders}` shim, `~/.local/bin/code{,-insiders}` shim, `*.desktop` files |
| `user-config` | `~/.config/Code{,-Insiders}`, `~/.vscode{,-insiders,-server,-server-insiders}`     | each of those directories                                             |

`deb` is intentionally separate from `apt`: it represents a one-off
`dpkg -i code_*.deb` install where the user did not add the Microsoft repo,
so we must not touch `/etc/apt/sources.list.d/vscode.list` or the GPG keyring.

## Usage

```bash
# Detect-only (read-only, no changes):
scripts-linux/run.sh 67 detect

# Preview what apply mode would do:
scripts-linux/run.sh 67 --dry-run

# Apply (default). User-scope artifacts only when not root:
scripts-linux/run.sh 67

# Full purge including system-scope (apt/snap/dpkg + /usr/local/bin shims):
sudo scripts-linux/run.sh 67 --system

# Limit to a single method:
scripts-linux/run.sh 67 --only user-config
sudo scripts-linux/run.sh 67 --only apt --system

# Inspect the catalog of methods, probes, and removal steps:
scripts-linux/run.sh 67 list
```

Top-level shortcuts in `scripts-linux/run.sh`:

- `vscode-clean-linux` — same as `67 run`
- `vscode-clean-linux-detect` — same as `67 detect`
- `vscode-clean-linux-list` — same as `67 list`
- `vscode-clean-linux-help` — same as `67 help`

## Output

Each invocation writes:

- `.logs/67/<TS>/command.txt` — the exact command line used
- `.logs/67/<TS>/rows.tsv`    — one row per action attempted
- `.logs/67/<TS>/manifest.json` — machine-readable summary (rows + totals + detected methods)
- `.logs/67/latest`           — symlink to the most recent run

## Safety guarantees

1. **Detect first**: nothing is removed for a method unless the detect phase
   confirmed at least one of its probes hit (or you passed `--skip-detect`
   together with `--only`).
2. **Allow-list only**: every package name and path is hard-coded in
   `config.json`. The script never enumerates `/usr` or `~/` looking for
   "anything VS Code-ish".
3. **CODE RED file errors**: every failed operation logs the exact path and
   reason via `log_file_error`.
4. **Dry-run by default**: pass `--dry-run` to preview; the apply mode is
   explicit but not destructive without confirmation when run on user scope.