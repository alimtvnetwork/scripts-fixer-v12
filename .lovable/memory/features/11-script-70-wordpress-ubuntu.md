---
name: script 70 Ubuntu WordPress installer
description: scripts-linux/70-install-wordpress-ubuntu/ -- modular bash installer (mysql/php/nginx/wordpress sub-scripts) with --interactive prompts; root run.sh shortcuts `install wordpress` / `install wp` / `install wp-only` / `wp` / `wordpress`
type: feature
---
## Script 70 -- Ubuntu WordPress installer (v0.136.0)

Folder: `scripts-linux/70-install-wordpress-ubuntu/`

Layout (modular):
```
70-install-wordpress-ubuntu/
  config.json                # defaults + supported versions
  log-messages.json          # parameterized log strings
  readme.txt                 # full usage + flag reference
  run.sh                     # orchestrator (verbs + flag parser)
  components/
    mysql.sh                 # MySQL 8 (default) or MariaDB 10.11 LTS
    php.sh                   # PHP-FPM (latest, or 8.1/8.2/8.3 via Ondrej PPA)
    nginx.sh                 # nginx + WP vhost wired to PHP-FPM socket
    wordpress.sh             # download tarball + DB + wp-config.php + salts
```

### Top-level shortcuts (in `scripts-linux/run.sh`)
- `./run.sh install wordpress [args]`  -- full LEMP + WordPress
- `./run.sh install wp [args]`         -- alias of `install wordpress`
- `./run.sh install wp-only [args]`    -- only the WordPress component
- `./run.sh wp [args]` / `./run.sh wordpress [args]` -- shortcut without `install`
- `./run.sh uninstall wordpress`       -- remove WordPress + nginx vhost
  (PHP + MySQL packages kept; remove explicitly via direct script call if needed)

### Per-component verbs (direct script call)
`install|check|repair|uninstall [mysql|php|nginx|wordpress|wp-only]`

### Interactive mode (`-i` / `--interactive`)
Prompts for: DB engine, MySQL port, MySQL data dir, PHP version, install path,
nginx port, server_name, DB name, DB user, DB password (blank = auto-generate
24-char alnum from `/dev/urandom`).

Reads from `/dev/tty` so it works under `sudo` and pipes; falls back to
defaults silently when no tty available.

### Flag reference
`--db mysql|mariadb` `--php 8.1|8.2|8.3|latest` `--port <n>` `--datadir <path>`
`--path <path>` `--site-port <n>` `--server-name <name>` `--db-name <name>`
`--db-user <name>` `--db-pass <pw>`

### Outputs
- `.installed/70-{mysql,php,nginx,wordpress}.ok` markers
- `.installed/70-wordpress-credentials.json` (chmod 600) -- contains site URL,
  DB host/port/name/user/password (critical when password was auto-generated)
- `.logs/70.log` -- shared logger output

### CODE RED compliance
Every file/path failure logs via `log_file_error path='...' reason='...'`:
nginx vhost write failures, tar extract failures, missing
`wp-config-sample.php`, MySQL conf.d directory missing, etc.

### Idempotency
- `mysql.sh`: skips when binary + service already healthy
- `php.sh`: skips when `php -m` already shows `mysqli`
- `nginx.sh`: re-writes vhost on every run (cheap, keeps it in sync)
- `wordpress.sh`: skips download when `$WP_INSTALL_PATH/wp-config.php` exists

### Prerequisites stage (v0.156.0)
`run.sh` exposes a dedicated `_install_prerequisites` stage and CLI verb
(`install prereqs` / `install prerequisites`). It runs MySQL + PHP first,
then calls `component_php_verify_strict` which:
- Parses `PHP_VERSION` and refuses anything below 7.4 (WordPress 6.x min).
- Checks every required extension is loaded: **mysqli mbstring xml curl
  intl gd**. Logs the missing list + the exact `apt-get install` line to
  fix it.
- Logs `[70][prereqs]` markers so the operator sees the boundary clearly.

`_install_all` now delegates the first two stages to `_install_prerequisites`
instead of calling `component_mysql_install` + `component_php_install`
directly -- nginx + WordPress only run when prereqs pass strict verify.

`component_php_verify` (loose check) is unchanged so existing call sites
(`_check_all`, `php.sh` idempotency check) keep their fast path.

### WordPress install: ZIP-first download (v0.157.0)
`components/wordpress.sh` now downloads `https://wordpress.org/latest.zip`
(operator's spec) and extracts via `unzip` into a staging dir, then moves
`<staging>/wordpress/*` (including dotfiles, via `shopt -s dotglob`) into
`$WP_INSTALL_PATH`. If `unzip` is missing the script does
`apt-get install -y unzip` first; if that also fails it transparently
falls back to the previous `latest.tar.gz` + `tar -xzf --strip-components=1`
path so minimal images keep working.

The wp-config.php generation step is unchanged: copies
`wp-config-sample.php`, sed-replaces the three placeholders
(`database_name_here`, `username_here`, `password_here`) plus the
`localhost` -> `host:port` swap, then replaces the entire SALT block with
a fresh fetch from `api.wordpress.org/secret-key/1.1/salt/`. Verified the
ZIP layout contains a top-level `wordpress/` dir and that
`wp-config-sample.php` still has all three replacement targets intact.

### HTTP server, http-verify, firewall (v0.158.0)
Three new components in `components/`:
- `apache.sh`: full Apache2 alternative -- mpm_event + proxy_fcgi to PHP-FPM,
  custom port via `Listen` directive, vhost at
  `/etc/apache2/sites-available/wordpress.conf`, dual `apache2ctl configtest`
  + `systemctl restart apache2` gates.
- `http-verify.sh`: `component_http_verify` curls
  `http://$WP_SERVER_NAME:$WP_SITE_PORT/` with `-L` redirect following and
  greps for WP fingerprints (`wp-content`, `wp-includes`, generator meta,
  Setup/Installation wizard markers). Returns rc=0 + the page `<title>` on
  match. Distinguishes 502 (FPM down) / 503 (FPM unreachable) / 000
  (connection failed) for clearer remediation.
- `firewall.sh`: opt-in via `--firewall` (sets `WP_FIREWALL=1`). Installs
  UFW if missing, runs `ufw allow $WP_SITE_PORT/tcp`, persists chosen port
  to `.installed/70-firewall.port` so a port change auto-revokes the old
  rule. Never auto-enables UFW (would lock SSH out of fresh hosts) -- only
  warns if inactive.

New flags in `run.sh`:
- `--http nginx|apache`  -- selects HTTP server (default nginx). When
  apache is chosen, nginx is `systemctl stop`+`disable`d to free :80.
- `--firewall`           -- opens `WP_SITE_PORT/tcp` in UFW after install.

`_install_all` now runs: prereqs -> http -> wordpress -> firewall ->
http-verify (best-effort warn, doesn't fail the install). `_check_all`
verifies the active HTTP server + http-loads + firewall (when
`WP_FIREWALL=1`).

Verified: WordPress fingerprint detection passes against the real
`wordpress.org` (HTTP 200, follows 301), and rejects a non-WP body. Bad
`--http oops` returns rc=2 with a clear log line.

### Repository policy (v0.155.0, confirmed)
`components/php.sh` auto-detects Ubuntu via `/etc/os-release` and decides:

| Ubuntu | APT default PHP | `--php latest` uses | Pin `--php 8.1` | Pin `--php 8.3` |
|--------|-----------------|---------------------|-----------------|-----------------|
| 24.04  | 8.3             | APT (8.3)           | Ondrej PPA      | APT (no PPA)    |
| 22.04  | 8.1             | APT (8.1)           | APT (no PPA)    | Ondrej PPA      |
| 20.04  | 7.4 (EOL warn)  | APT (7.4) + warn    | Ondrej PPA      | Ondrej PPA      |
| other  | unknown         | APT (best effort)   | Ondrej PPA      | Ondrej PPA      |

Rule: `latest` is always APT-only (no third-party repos). Pinned versions
only add `ppa:ondrej/php` when the distro's APT does not already ship that
exact X.Y. PPA add failures log a remediation hint
(`apt-get install software-properties-common`).

### Verified
- `bash -n` clean on all 5 bash files + edited `scripts-linux/run.sh`
- shellcheck clean (one SC2024 suppressed with explicit comment)
- `./run.sh install wordpress --help` / `./run.sh wp --help` / direct script
  `--help` all return exit 0
- Registry `./run.sh --list` shows entry 70 with correct title

Built: v0.136.0.
### DNS-01 + wildcard SSL (v0.164.0)
`components/https.sh` now supports both ACME challenges, auto-selected:
- HTTP-01 (default): `--https` alone — needs port 80 reachable.
- DNS-01: `--dns cloudflare|route53|digitalocean|manual`.
- Wildcard: `--wildcard` forces DNS-01. Each apex becomes
  `-d example.com -d *.example.com`; `www.<apex>` tokens are merged into
  the apex so the SAN list stays minimal.

New flags: `--dns`, `--dns-credentials`, `--dns-propagation`, `--wildcard`.
`--dns` and `--wildcard` implicitly set `WP_HTTPS=1`.

DNS-01 uses `certbot certonly` then `certbot install --nginx|--apache
--cert-name <primary>`; nginx still gets the deterministic vhost rewrite.
apt installs `python3-certbot-dns-<provider>` (manual built into core).

Credentials: cloudflare/digitalocean require `--dns-credentials <ini>`
with `dns_<provider>_api_token = ...`; chmod auto-fixed to 600. route53
reads `~/.aws/credentials` or `AWS_ACCESS_KEY_ID`. manual prompts on
stdin (NOT auto-renewable).

New markers: `.installed/70-https.dns`, `.installed/70-https.wildcard`.

Spec: `scripts-linux/70-install-wordpress-ubuntu/spec/01-ssl-automation.md`
(provider tables, IAM policy, wildcard expansion rules, failure-mode
remediation). macOS confirmed out of scope by user.

### wp-config.php strict validator (v0.177.0)
`components/wordpress.sh` adds `component_wordpress_verify_config <path>
<db_name> <db_user> <db_pass> <db_host> <db_port>`, called from
`component_wordpress_install` immediately after the salts step (3b). Hard
aborts the install when wp-config.php is broken. Checks:
1. File exists, non-empty, contains "stop editing" end marker (truncation).
2. `php -l` syntax check (skipped with warn if php not on PATH).
3. `define('DB_NAME'|'DB_USER'|'DB_PASSWORD'|'DB_HOST')` values match the
   credentials we just installed (DB_HOST = `host:port`).
4. No leftover `database_name_here|username_here|password_here` placeholders.
5. All 8 salts (AUTH_KEY, SECURE_AUTH_KEY, LOGGED_IN_KEY, NONCE_KEY,
   AUTH_SALT, SECURE_AUTH_SALT, LOGGED_IN_SALT, NONCE_SALT) defined exactly
   once each, value length >= 32 chars.
6. None of the 8 salts equal the shipped placeholder
   "put your unique phrase here" (catches silent api.wordpress.org failure).
7. The 8 salt values are mutually unique (sort -u must give 8 lines).

Every failure logs via `log_file_error path='...' reason='...'` (CODE RED).
Verified end-to-end with 7 unit-test scenarios: 1 clean pass + 6 distinct
failure modes (wrong DB pass, leftover placeholder, duplicate salts,
shipped placeholder salt, missing salt, missing end marker).

### Download integrity check (v0.178.0)
`components/wordpress.sh` adds `_wp_verify_download <file> <url>`, called
immediately after both download paths (ZIP primary + tar.gz fallback) and
BEFORE any extraction so a tampered/corrupt archive never touches the host.
Algorithm choice: WordPress.org publishes `<url>.sha1` and `<url>.md5`
but **NOT** `<url>.sha256` (confirmed via 404). Implementation uses:
1. Local SHA256 logged for audit trail (no remote to compare against).
2. SHA1 vs `<url>.sha1` -- primary integrity gate. Mismatch = abort.
3. MD5 vs `<url>.md5` -- redundant secondary gate. Mismatch = abort.
4. Strict by default: missing checksum URL aborts. Set
   `WP_SKIP_CHECKSUM=1` to fall back to a warning (operator escape hatch
   for networks that block the checksum URLs but mirror the archive).
5. Empty/missing local file is caught before any network call.
On failure the corrupt archive is left in place at `/tmp/wordpress-latest-*.zip`
for forensics. Verified against live wordpress.org with 5 scenarios:
clean pass, 1-byte corruption (SHA1 mismatch caught with exact expected/got),
missing checksum URL strict (abort), missing checksum URL with skip flag
(warn + continue), and empty file (fail fast).

### Reconfigure verb + --keep-salts (v0.179.0)
New top-level verb `reconfigure` (aliases: `reconfig`, `rewrite-config`)
regenerates wp-config.php from the existing extracted WordPress files
using current `WP_DB_NAME` / `WP_DB_USER` / `WP_DB_PASS` / `WP_MYSQL_PORT`
/ `WP_INSTALL_PATH`. NO download, NO extract, NO chown of the docroot.

Refactor: extracted shared helpers in `components/wordpress.sh`:
- `_wp_write_config <path> <db_name> <db_user> <db_pass> <db_host> <db_port> [keep_salts]`
  -- single source of truth for cp + sed + salt block + verify; called by
  both install and reconfigure.
- `_wp_save_credentials_record <path> <engine> <host> <port> <name> <user> <pass>`
  -- writes the chmod-600 .installed/70-wordpress-credentials.json.
- `component_wordpress_reconfigure` -- validates install dir + sample,
  backs up existing wp-config.php to `wp-config.php.bak.<UTC-ts>`,
  applies idempotent MySQL grant (CREATE ... IF NOT EXISTS + ALTER USER),
  calls `_wp_write_config`, refreshes credentials record.

New flag `--keep-salts` (sets `WP_KEEP_SALTS=1`): preserves the existing
8 salt define() lines so active user sessions / password reset cookies
remain valid -- only DB credentials change. Default behaviour rotates
salts from `api.wordpress.org/secret-key/1.1/salt/` for safety.
If --keep-salts is set but the existing config has fewer than 8 salts,
falls back to fresh fetch with a WARN.

**Bonus bug fix discovered during testing**: the awk salt-strip regex
(`...);$`) failed against `wp-config-sample.php` because WordPress ships
it with **CRLF** line endings (the trailing `\r` sits between `;` and
`\n`, so the EOL anchor never matched). Pre-existing bug -- caused
duplicate salts on any operator-edited wp-config.php. Fixed by adding
`sudo sed -i 's/\r$//' "$cfg"` immediately before the awk filter so it
works for both fresh-from-upstream (CRLF) and post-write (LF) files.

Verified end-to-end with 4 unit tests against a real wp-config-sample.php
from upstream: default reconfigure rotates salts and applies new DB creds;
--keep-salts preserves all 8 known salts exactly once while applying new
DB creds; missing wp-config-sample.php aborts with FILE-ERR; missing
install dir aborts with FILE-ERR. All backups created at
`<install_path>/wp-config.php.bak.<UTC-ts>` for one-mv rollback.

Usage:
```
./run.sh reconfigure --db-pass NEW_PASSWORD            # rotate password + salts
./run.sh reconfigure --db-pass NEW_PASSWORD --keep-salts  # rotate password, keep sessions
./run.sh reconfigure --port 3307 --keep-salts          # MySQL port changed, no session loss
./run.sh reconfigure -i                                # interactive prompts
```

### Verify --json + before/after --diff (v0.180.0)
`component_wordpress_verify_config` refactored to collect findings into a
structured array via internal `_record` helper, then emit them either as
human log lines (text mode, default) OR as a single JSON document on
stdout when `WP_VERIFY_JSON=1` is set. Each finding has a stable schema:
`{severity, check, path, message, expected, actual, fix}`. Check IDs are
stable strings (e.g. `db.DB_PASSWORD.mismatch`, `salt.AUTH_KEY.placeholder`,
`salt.uniqueness`, `php.lint`, `file.truncated`) so downstream scripts
can match on them.

New top-level `verify` verb in `run.sh` exposes three modes:
1. `verify`                  -- text mode (existing behaviour, preserved)
2. `verify --json`           -- emit structured findings JSON to stdout
3. `verify --snapshot <file>` -- write JSON to file (also stdout if --json)
4. `verify --diff <baseline>` -- compare current verify state to a
   previously-snapshotted JSON document and emit a structured
   before/after/changes JSON with per-check transitions
   (resolved | introduced | persisted | severity_changed). Implies --json.
   Requires `jq` -- aborts with rc=2 + clear remediation if missing.

`component_wordpress_reconfigure` now auto-writes a BEFORE-snapshot at
`<install>/wp-config.php.bak.<UTC-ts>.verify.json` paired with each backup
(uses old credentials from `.installed/70-wordpress-credentials.json` when
available, else marks expected fields as `(unknown baseline)`). After a
reconfigure the operator can run `./run.sh verify --diff <bak>.verify.json`
to see exactly what changed -- the diff hint is logged for copy/paste.

**Bug fix during implementation**: initial encoding used TAB (`\t`) as the
findings record delimiter, but `IFS=$'\t' read` collapses runs of TABs
(POSIX whitespace IFS rule), so empty middle fields shifted later fields
left -- making `expected`/`actual`/`fix` misalign. Switched to ASCII
Unit Separator (`\x1f`), which is non-whitespace and preserves empty
fields exactly.

Verified end-to-end with 6 scenarios using a real upstream
wp-config-sample.php: text mode unchanged; JSON parses cleanly under
`jq`; intentional DB_PASSWORD mismatch produces correct expected/actual/
fix fields with the right `--db-pass` flag hint; reconfigure auto-writes
the .verify.json snapshot with old creds; --diff produces correct
before_expected/after_expected (db1→db2, port 3306→3307); missing
baseline aborts with CODE-RED file error.

Usage:
```
./run.sh verify --json                                      # current state, JSON
./run.sh verify --snapshot /tmp/before.json                 # save baseline
./run.sh reconfigure --db-pass NEWPASS                      # makes a change
./run.sh verify --diff /tmp/before.json                     # show what changed
# After any reconfigure, the auto-written snapshot is also usable:
./run.sh verify --diff /var/www/wordpress/wp-config.php.bak.20260427T...Z.verify.json
```
