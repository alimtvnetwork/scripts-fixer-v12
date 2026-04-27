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