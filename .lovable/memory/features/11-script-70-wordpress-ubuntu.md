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