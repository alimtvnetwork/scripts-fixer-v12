================================================================================
Script 70 -- Ubuntu WordPress installer (Nginx + PHP-FPM + MySQL/MariaDB + WP)
================================================================================

Modular installer that brings up a full WordPress site on Ubuntu in one shot.

Components (each is its own bash file under components/, called in order):
  1. mysql.sh      MySQL 8 (default) or MariaDB 10.11 LTS
                   Honors WP_MYSQL_PORT and WP_MYSQL_DATADIR
  2. php.sh        PHP-FPM (latest, or 8.1 / 8.2 / 8.3 via Ondrej PPA)
                   Installs WordPress-required extensions: mysql, xml, curl,
                   gd, mbstring, zip, intl, bcmath, soap, imagick
  3. nginx.sh      nginx + WordPress vhost wired to PHP-FPM socket
                   Disables the default site to avoid port conflicts
  4. wordpress.sh  Downloads https://wordpress.org/latest.tar.gz, extracts to
                   the install path, creates DB + user, writes wp-config.php
                   with fresh salts pulled from api.wordpress.org/secret-key

Usage from the toolkit root (scripts-linux/):

  ./run.sh install wordpress              # full stack, all defaults
  ./run.sh install wordpress -i           # interactive prompts
  ./run.sh install wp                     # alias
  ./run.sh install wp-only --path /srv/site  # WordPress only (prereqs assumed)
  ./run.sh wp -i                          # shortcut without 'install'

  ./run.sh uninstall wordpress            # remove WP + nginx vhost
                                          # (PHP and MySQL packages are kept;
                                          # remove explicitly if desired)

Direct (script-level) invocation supports per-component verbs:

  ./70-install-wordpress-ubuntu/run.sh install                # all
  ./70-install-wordpress-ubuntu/run.sh install mysql          # one component
  ./70-install-wordpress-ubuntu/run.sh install php
  ./70-install-wordpress-ubuntu/run.sh install nginx
  ./70-install-wordpress-ubuntu/run.sh install wordpress
  ./70-install-wordpress-ubuntu/run.sh check                  # verify all
  ./70-install-wordpress-ubuntu/run.sh repair                 # wipe markers + reinstall
  ./70-install-wordpress-ubuntu/run.sh uninstall mysql        # remove one

Flags (all optional):
  -i | --interactive          Prompt for every customisable value
  --db mysql|mariadb          DB engine (default: mysql)
  --php 8.1|8.2|8.3|latest    PHP version (default: latest)
  --port <n>                  MySQL port (default: 3306)
  --datadir <path>            MySQL data dir (default: /var/lib/mysql)
  --path <path>               WordPress install path (default: /var/www/wordpress)
  --site-port <n>             nginx HTTP port (default: 80)
  --server-name <name>        nginx server_name (default: localhost)
  --db-name <name>            WP DB name (default: wordpress)
  --db-user <name>            WP DB user (default: wp_user)
  --db-pass <pw>              WP DB password (default: auto-generated 24 chars)

Outputs:
  .installed/70-mysql.ok                     marker after MySQL install
  .installed/70-php.ok                       marker after PHP install
  .installed/70-nginx.ok                     marker after nginx install
  .installed/70-wordpress.ok                 marker after WordPress install
  .installed/70-wordpress-credentials.json   chmod 600, contains site URL,
                                             DB name/user/password (esp.
                                             important when password was
                                             auto-generated)
  .logs/70.log                               full log from this script

CODE RED compliance:
Every file/path error logs `FILE-ERROR path='<exact path>' reason='<exact reason>'`
via `log_file_error` from _shared/logger.sh. Examples include nginx vhost
write failures, tar extract failures, missing wp-config-sample.php in the
downloaded tarball, etc.

Idempotency:
  * mysql.sh skips when binary + service are already healthy
  * php.sh skips when `php -m` already shows mysqli
  * nginx.sh re-writes the vhost on every run (cheap; keeps it in sync)
  * wordpress.sh skips download when wp-config.php already exists at the
    install path

Built: v0.136.0.