# 15 - Interactive mode for 16/18/70 (PHP / MySQL / WordPress)

**Spec:** "Implement an --interactive mode that asks me for the MySQL port,
MySQL data directory, WordPress directory path, and PHP version (or 'latest')
before installing anything."

## Decisions confirmed via questions

| Decision | Choice |
|---|---|
| Where --interactive lives | All three on BOTH Windows and Linux |
| Prompt UX | Show default in brackets, Enter accepts it (no validation loop required, but I added one anyway -- it only triggers on bad input) |

## What I found vs what I built

| Script | Platform | Existed already? | What I changed |
|---|---|---|---|
| 70 (WordPress) | Linux  | YES -- full --interactive with all 4 prompts | Verified intact, no changes |
| 70 (WordPress) | Windows| N/A -- script 70 is Linux-only | Skipped (out of scope) |
| 16 (PHP)       | Linux  | NO -- single-line installer | Rewrote with --interactive, --php=<ver>, validators |
| 16 (PHP)       | Windows| NO -- choco-only installer | Added -Interactive, -PhpVersion, persistence |
| 18 (MySQL)     | Linux  | NO -- single-line installer | Rewrote with --interactive, --port, --datadir, validators, my.cnf override writer |
| 18 (MySQL)     | Windows| NO -- choco-only installer | Added -Interactive, -MysqlPort, -MysqlDataDir, persistence |

## New shared helpers

* `scripts-linux/_shared/interactive.sh` (93 lines) -- POSIX bash:
  `interactive_is_enabled`, `interactive_strip_flag`, `prompt_with_default`,
  `validate_port`, `validate_php_version`, `validate_path_writable`
* `scripts/shared/interactive.ps1` (92 lines) -- PowerShell mirror:
  `Test-InteractiveFlag`, `Remove-InteractiveFlag`, `Read-PromptWithDefault`,
  `Test-PortValue`, `Test-PhpVersion`, `Test-PathWritable`

Both honour: prompt to stderr/host so command substitution captures only the
reply; read from `/dev/tty` (bash) so piped stdin doesn't break interactive UX;
non-interactive sessions get the default with a warning instead of hanging.

## Validators

* port: integer 1..65535
* php-version: `latest` OR `[5-9].N[.N]` (rejects 4.x, "oops", empty)
* path: exists OR parent directory exists (creatable)

Defaults applied:
* Linux 18: port=3306, datadir=/var/lib/mysql
* Win   18: port=3306, datadir=C:\ProgramData\MySQL\Data
* Linux 16: php=latest (apt installs `php-cli php-fpm`; specific = `phpX.Y-cli phpX.Y-fpm`)
* Win   16: php=latest (choco installs latest stable; captured value persisted only)

## Persistence

Windows 16/18 write the captured answers to `scripts/.resolved/16-interactive.json`
and `scripts/.resolved/18-interactive.json` for downstream tools.

Linux 18 writes `/etc/mysql/conf.d/99-script18.cnf` (port + datadir override)
**only when** the answers differ from MySQL defaults, then `systemctl restart mysql`.

## Validation (this loop)

| Check | Result |
|---|---|
| bash `interactive.sh` syntax | OK |
| bash unit tests (16 cases) | 16/16 PASS |
| Linux 16 `--help`           | renders flags + verbs |
| Linux 18 `--help`           | renders flags + verbs |
| Linux 16 bad `--php=99.99`  | rc=2, file-error logged |
| Linux 18 bad `--port=99999` | rc=2, file-error logged |
| Linux 18 bad `--datadir=/no/such/parent/x` | rc=2 |
| Simulated --interactive flow (4 prompts, with default fallback) | all 4 captured correctly |
| PowerShell parse: shared/interactive.ps1, 16/run.ps1, 18/run.ps1 | PARSE OK |
| PowerShell unit tests (18 cases)             | 18/18 PASS |
| PowerShell non-interactive Read-Prompt fallback | returns default |

## Why Windows install behaviour wasn't changed

Choco installs latest by default and doesn't accept `--port` or `--datadir`.
Rather than fork the Choco flow (high risk of breaking sister scripts),
the captured answers are persisted to `.resolved/` and surfaced via clear
log lines. A follow-up script (or a future task) can read those JSON files
and write a `my.ini` override + `Stop-Service / Start-Service` cycle. The
prompt UX itself is already in place and validated.

## How to revert

`rm scripts-linux/_shared/interactive.sh scripts/shared/interactive.ps1`
plus `git checkout` of the 4 modified `run.{sh,ps1}` files.
