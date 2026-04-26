# 65-os-clean — Cross-OS cleanup (Linux + macOS)

Sweeps user temp + caches, trash, package-manager caches
(apt/dnf/pacman/brew/npm/pnpm/bun/yarn/pip), and rotated/system/user logs
+ crash dumps. Apply by default; pass `--dry-run` for a preview.

## Subverbs

| Verb              | Purpose                                                |
|-------------------|--------------------------------------------------------|
| `run` (default)   | Sweep every enabled category.                          |
| `list-categories` | Print every category with label, bucket, destructive flag. |
| `help`            | Show flag reference.                                   |

## Flags

| Flag                   | Effect                                                                  |
|------------------------|-------------------------------------------------------------------------|
| `--dry-run` / `-n`     | Preview only; no deletions, no package mutations.                       |
| `--apply`              | Force apply (default; explicit for clarity in CI).                      |
| `--only A,B,C`         | Limit to comma-separated category ids.                                  |
| `--exclude A,B,C`      | Skip these categories.                                                  |
| `--yes` / `-y`         | Pre-approve destructive categories (`trash`, `logs-system`).            |
| `--json`               | Emit a single JSON document on stdout (manifest-shaped).                |
| `--quiet`              | Suppress per-item locked-path notes (still in manifest).                |

## Categories

| ID            | OS    | Destructive | Path / command                                              |
|---------------|-------|-------------|--------------------------------------------------------------|
| `temp-user`   | both  | no          | `${TMPDIR:-/tmp}/${USER}-*` glob                             |
| `caches-user` | both  | no          | `~/.cache` (Linux) / `~/Library/Caches` (macOS); preserves `lovable`, `ssh`, `gnupg` |
| `trash`       | both  | **yes**     | `~/.local/share/Trash` / `~/.Trash`                          |
| `pkg-apt`     | linux | no          | `sudo apt-get clean`                                         |
| `pkg-dnf`     | linux | no          | `sudo dnf clean all`                                         |
| `pkg-pacman`  | linux | no          | `sudo pacman -Sc --noconfirm`                                |
| `pkg-brew`    | both  | no          | `brew cleanup -s --prune=all`                                |
| `pkg-npm`     | both  | no          | `npm cache clean --force`                                    |
| `pkg-pnpm`    | both  | no          | `pnpm store prune`                                           |
| `pkg-bun`     | both  | no          | `~/.bun/install/cache` (contents)                            |
| `pkg-yarn`    | both  | no          | `yarn cache clean`                                           |
| `pkg-pip`     | both  | no          | `pip cache purge`                                            |
| `logs-rotated`| both  | no          | `/var/log/*.gz`/`*.1`/`*.old` (sudo)                         |
| `logs-journal`| linux | no          | `sudo journalctl --vacuum-time=7d`                           |
| `logs-user`   | both  | no          | `~/.npm/_logs`, `~/Library/Logs`                             |
| `logs-system` | both  | **yes**     | `/var/crash` / `/Library/Logs/DiagnosticReports` (sudo)      |

Destructive categories are skipped unless `--yes` is passed.

## Examples

```bash
scripts-linux/run.sh os-clean                          # apply, all categories
scripts-linux/run.sh os-clean --dry-run                # preview only
scripts-linux/run.sh os-clean --only caches-user,pkg-bun
scripts-linux/run.sh os-clean --yes --only trash       # actually empty the trash
scripts-linux/run.sh os-clean --dry-run --json | jq '.totals'
```

## Per-run logs

`{repo}/.logs/65/<TIMESTAMP>/` contains `command.txt`, `manifest.json`,
and `rows.tsv`. The manifest mirrors the Windows `scripts/os/` clean
schema so one parser can consume both.

## Tests

`tests/01-smoke.sh` seeds fixtures in `caches-user`, `trash`, `logs-user`,
and `pkg-bun`, runs `--dry-run` (must not delete) and apply with `--yes`
(must delete and preserve `~/.cache/lovable/`). 21/21 assertions pass.
