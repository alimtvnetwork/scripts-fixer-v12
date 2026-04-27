#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/run.sh
# Ubuntu WordPress installer (Nginx + PHP-FPM + MySQL/MariaDB + WordPress).
#
# Verbs:
#   install               install all components in order
#   install wp-only       install ONLY WordPress (assumes prereqs are present)
#   install prereqs       install ONLY prerequisites (MySQL + PHP + extensions),
#                         then run strict PHP verification (mysqli mbstring
#                         xml curl intl gd) and check PHP version >= 7.4
#   install <component>   install one of: mysql | php | nginx | wordpress
#   check                 verify every installed component
#   repair                wipe markers, re-run install
#   uninstall             remove WordPress + per-component cleanup
#
# Flags:
#   --interactive | -i    prompt for port / data dir / php version /
#                         install path / site port / db name|user|pass
#   --db mysql|mariadb    pick DB engine (default: mysql)
#   --php <ver>           pin PHP version (8.1|8.2|8.3|latest, default: latest)
#   --port <n>            MySQL port (default: 3306)
#   --datadir <path>      MySQL data directory (default: /var/lib/mysql)
#   --path <path>         WordPress install path (default: /var/www/wordpress)
#                         (also used as nginx/apache document root)
#   --docroot <path>      Alias of --path (document root for the vhost)
#   --site-port <n>       nginx HTTP port (default: 80)
#   --server-name <name>  vhost server_name -- your domain (default: localhost)
#                         Examples: example.com, "example.com www.example.com",
#                         blog.example.com. Use a space-separated list to
#                         serve multiple hostnames from the same vhost.
#   --db-name <name>      WordPress DB name (default: wordpress)
#   --db-user <name>      WordPress DB user (default: wp_user)
#   --db-pass <pw>        WordPress DB password (default: auto-generate)
#   --http nginx|apache   HTTP server (default: nginx)
#   --firewall            open WP_SITE_PORT in UFW after install (UFW must
#                         be enabled separately; this only adds the rule)
#   --https               obtain a Let's Encrypt cert for --server-name and
#                         rewrite the vhost to redirect HTTP -> HTTPS
#                         (requires a real public FQDN + port 80 reachable
#                         from the internet for the http-01 challenge)
#   --email <addr>        contact email for Let's Encrypt renewal warnings
#                         (omit to register without email -- not recommended)
#   --https-staging       use Let's Encrypt staging endpoint (cert is NOT
#                         browser-trusted) -- useful for dry-runs without
#                         hitting prod rate limits
#   --show-credentials    after a successful 'install', also print the saved
#                         DB credentials + salts location (otherwise stays
#                         silent so logs can be safely shared)
#   --json                with 'show-credentials' verb, emit raw JSON
#                         instead of the human-readable block
#   -h | --help           show this help and exit
#
# Extra verbs:
#   show-credentials | creds | show-creds
#                         print the saved DB credentials + salts location
#                         from .installed/70-wordpress-credentials.json
#                         (add --json for machine-readable output)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="70"
export ROOT

. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$SCRIPT_DIR/components/mysql.sh"
. "$SCRIPT_DIR/components/php.sh"
. "$SCRIPT_DIR/components/nginx.sh"
. "$SCRIPT_DIR/components/apache.sh"
. "$SCRIPT_DIR/components/firewall.sh"
. "$SCRIPT_DIR/components/http-verify.sh"
. "$SCRIPT_DIR/components/https.sh"
. "$SCRIPT_DIR/components/wordpress.sh"

CONFIG="$SCRIPT_DIR/config.json"
if [ ! -f "$CONFIG" ]; then
    log_file_error "$CONFIG" "config.json missing for 70-install-wordpress-ubuntu"
    exit 1
fi

# ---- defaults ---------------------------------------------------------------
INTERACTIVE=0
VERB=""
SUBCOMPONENT=""
export WP_DB_ENGINE="mysql"
export WP_PHP_VERSION="latest"
export WP_MYSQL_PORT="3306"
export WP_MYSQL_DATADIR="/var/lib/mysql"
export WP_INSTALL_PATH="/var/www/wordpress"
export WP_SITE_PORT="80"
export WP_SERVER_NAME="localhost"
export WP_DB_NAME="wordpress"
export WP_DB_USER="wp_user"
export WP_DB_PASS=""
export WP_HTTP_SERVER="nginx"   # nginx | apache
export WP_FIREWALL="0"          # 1 = open WP_SITE_PORT via UFW
export WP_HTTPS="0"             # 1 = obtain LE cert + redirect HTTP->HTTPS
export WP_HTTPS_EMAIL=""        # contact email for Let's Encrypt
export WP_HTTPS_STAGING="0"     # 1 = use LE staging endpoint
export WP_SHOW_CREDENTIALS="0"  # 1 = print credentials block after install
SHOW_CREDS_JSON="0"             # 1 = show-credentials verb emits raw JSON

_show_help() {
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        install|check|repair|uninstall)
            VERB="$1"; shift
            # Optional positional: component (mysql|php|nginx|wordpress|wp-only|wp)
            case "${1:-}" in
                mysql|php|nginx|apache|http|firewall|http-verify|https|wordpress|wp-only|wp|prereqs|prerequisites)
                    SUBCOMPONENT="$1"; shift ;;
            esac
            ;;
        show-credentials|show-creds|creds)
            VERB="show-credentials"; shift ;;
        -i|--interactive)  INTERACTIVE=1; shift ;;
        --db)              WP_DB_ENGINE="$2"; shift 2 ;;
        --php)             WP_PHP_VERSION="$2"; shift 2 ;;
        --port)            WP_MYSQL_PORT="$2"; shift 2 ;;
        --datadir)         WP_MYSQL_DATADIR="$2"; shift 2 ;;
        --path)            WP_INSTALL_PATH="$2"; shift 2 ;;
        --docroot)         WP_INSTALL_PATH="$2"; shift 2 ;;
        --site-port)       WP_SITE_PORT="$2"; shift 2 ;;
        --server-name|--domain)
                           WP_SERVER_NAME="$2"; shift 2 ;;
        --db-name)         WP_DB_NAME="$2"; shift 2 ;;
        --db-user)         WP_DB_USER="$2"; shift 2 ;;
        --db-pass)         WP_DB_PASS="$2"; shift 2 ;;
        --http)            WP_HTTP_SERVER="$2"; shift 2 ;;
        --firewall)        WP_FIREWALL="1"; shift ;;
        --https)           WP_HTTPS="1"; shift ;;
        --email)           WP_HTTPS_EMAIL="$2"; shift 2 ;;
        --https-staging)   WP_HTTPS_STAGING="1"; shift ;;
        --show-credentials) WP_SHOW_CREDENTIALS="1"; shift ;;
        --json)            SHOW_CREDS_JSON="1"; shift ;;
        -h|--help)         _show_help; exit 0 ;;
        *)
            log_warn "[70] Unknown arg: '$1' -- run with --help for usage"
            shift ;;
    esac
done

VERB="${VERB:-install}"

# ---- interactive prompts ----------------------------------------------------
_prompt() {
    # _prompt "label" "default" -> echoes user reply (default if empty)
    local label="$1" default="$2" reply=""
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        echo "$default"
        return
    fi
    printf '  %s [%s]: ' "$label" "$default" > /dev/tty
    if ! IFS= read -r reply < /dev/tty; then
        echo "$default"
        return
    fi
    [ -z "$reply" ] && reply="$default"
    echo "$reply"
}

# _validate_server_name <value> -> rc=0 if every space-separated token looks
# like a hostname (letters/digits/dot/hyphen, or 'localhost'). Logs a warning
# but does NOT reject -- the operator may know better than this regex.
_validate_server_name() {
    local value="$1" token bad=0
    [ -z "$value" ] && return 0
    for token in $value; do
        if ! printf '%s' "$token" | grep -qE '^([a-zA-Z0-9_]([a-zA-Z0-9_-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$|^localhost$'; then
            log_warn "[70] server_name token '$token' does not look like a valid hostname (continuing anyway)"
            bad=1
        fi
    done
    return $bad
}

# _validate_docroot <path> -> rc=0 if absolute path; warn otherwise.
_validate_docroot() {
    local value="$1"
    case "$value" in
        /*) return 0 ;;
        *)  log_warn "[70] document root '$value' is not absolute -- nginx/apache require an absolute path"
            return 1 ;;
    esac
}

_run_interactive() {
    log_info "[70] Interactive mode -- press Enter to accept the [default]"
    WP_DB_ENGINE="$(_prompt    'DB engine (mysql|mariadb)'      "$WP_DB_ENGINE")"
    WP_MYSQL_PORT="$(_prompt   'MySQL port'                     "$WP_MYSQL_PORT")"
    WP_MYSQL_DATADIR="$(_prompt 'MySQL data dir'                "$WP_MYSQL_DATADIR")"
    WP_PHP_VERSION="$(_prompt  'PHP version (8.1|8.2|8.3|latest)' "$WP_PHP_VERSION")"
    WP_INSTALL_PATH="$(_prompt 'Document root / WordPress install path (absolute, e.g. /var/www/example.com)' "$WP_INSTALL_PATH")"
    _validate_docroot "$WP_INSTALL_PATH" || true
    WP_SITE_PORT="$(_prompt    'nginx HTTP port'                "$WP_SITE_PORT")"
    WP_SERVER_NAME="$(_prompt  'Server name / domain (e.g. example.com www.example.com)' "$WP_SERVER_NAME")"
    _validate_server_name "$WP_SERVER_NAME" || true
    WP_DB_NAME="$(_prompt      'DB name'                        "$WP_DB_NAME")"
    WP_DB_USER="$(_prompt      'DB user'                        "$WP_DB_USER")"
    WP_DB_PASS="$(_prompt      'DB password (blank = auto-generate)' "$WP_DB_PASS")"
    export WP_DB_ENGINE WP_PHP_VERSION WP_MYSQL_PORT WP_MYSQL_DATADIR \
           WP_INSTALL_PATH WP_SITE_PORT WP_SERVER_NAME \
           WP_DB_NAME WP_DB_USER WP_DB_PASS
}

if [ "$INTERACTIVE" = "1" ] && [ "$VERB" = "install" ]; then
    _run_interactive
fi

# Non-interactive: still run validators so a typo in --server-name or
# --docroot is surfaced before MySQL/PHP packages get installed.
if [ "$INTERACTIVE" = "0" ] && [ "$VERB" = "install" ]; then
    _validate_server_name "$WP_SERVER_NAME" || true
    _validate_docroot "$WP_INSTALL_PATH"    || true
fi

# ---- verb dispatchers -------------------------------------------------------
_install_one() {
    case "$1" in
        mysql)     component_mysql_install     ;;
        php)       component_php_install       ;;
        nginx)     component_nginx_install     ;;
        apache)    component_apache_install    ;;
        http)      _install_http               ;;
        firewall)  component_firewall_install  ;;
        http-verify) component_http_verify     ;;
        https)     WP_HTTPS=1 component_https_install ;;
        wordpress|wp|wp-only) component_wordpress_install ;;
        prereqs|prerequisites) _install_prerequisites ;;
        *)         log_err "[70] Unknown component: '$1'"; return 2 ;;
    esac
}

# ---- HTTP server (nginx | apache) ------------------------------------------
# Dispatches to the requested HTTP server. Validates WP_HTTP_SERVER first so a
# typo doesn't silently fall through to nginx.
_install_http() {
    case "${WP_HTTP_SERVER:-nginx}" in
        nginx)
            log_info "[70][http] HTTP server = nginx"
            component_nginx_install ;;
        apache|apache2|httpd)
            log_info "[70][http] HTTP server = apache2"
            # Pre-emptively stop nginx if installed -- :80 conflict otherwise.
            if command -v nginx >/dev/null 2>&1 && sudo systemctl is-active --quiet nginx; then
                log_info "[70][http] stopping nginx to free port for apache"
                sudo systemctl stop nginx 2>/dev/null || true
                sudo systemctl disable nginx 2>/dev/null || true
            fi
            component_apache_install ;;
        *)
            log_err "[70][http] unknown WP_HTTP_SERVER='${WP_HTTP_SERVER}' (expected: nginx|apache)"
            return 2 ;;
    esac
}

# ---- prerequisites ---------------------------------------------------------
# Installs MySQL/MariaDB and PHP-FPM (with mysqli, mbstring, xml, curl, intl,
# gd, plus zip/bcmath/soap/imagick), then runs strict verification: PHP
# version >= 7.4 and every required extension loaded. Refuses to return
# success unless both engines pass strict verify -- nginx + WordPress stages
# rely on this contract.
_install_prerequisites() {
    log_info "[70][prereqs] === prerequisites stage start ==="
    log_info "[70][prereqs] components: $WP_DB_ENGINE + PHP-FPM ($WP_PHP_VERSION)"
    log_info "[70][prereqs] required PHP extensions: mysqli mbstring xml curl intl gd"

    if ! component_mysql_install; then
        log_err "[70][prereqs] MySQL/MariaDB install failed -- cannot continue"
        return 1
    fi
    if ! component_mysql_verify; then
        log_err "[70][prereqs] MySQL/MariaDB verify failed after install"
        return 1
    fi
    log_ok "[70][prereqs] MySQL/MariaDB OK"

    if ! component_php_install; then
        log_err "[70][prereqs] PHP-FPM install failed -- cannot continue"
        return 1
    fi
    if ! component_php_verify_strict; then
        log_err "[70][prereqs] PHP strict verify failed -- see missing extensions above"
        return 1
    fi
    log_ok "[70][prereqs] === prerequisites stage complete ==="
    return 0
}

_install_all() {
    log_info "[70] Starting Ubuntu WordPress installer (engine=$WP_DB_ENGINE php=$WP_PHP_VERSION path=$WP_INSTALL_PATH)"
    local rc=0
    _install_prerequisites      || rc=$?
    [ $rc -eq 0 ] && _install_http               || rc=$?
    [ $rc -eq 0 ] && component_wordpress_install || rc=$?
    [ $rc -eq 0 ] && component_firewall_install  || rc=$?
    # HTTPS runs AFTER firewall so port 443 (and the redirected :80 traffic)
    # can reach this host before certbot tries the http-01 challenge.
    # Skipped automatically when WP_HTTPS=0.
    [ $rc -eq 0 ] && component_https_install     || rc=$?
    if [ $rc -eq 0 ]; then
        # HTTP-loads check is best-effort: don't fail the whole install if
        # the wizard page isn't reachable yet (DNS, container networking).
        if ! component_http_verify; then
            log_warn "[70] HTTP verification failed -- WordPress files are in place but the site did not respond as expected. Investigate before opening the install wizard."
        fi
    fi
    return $rc
}

_check_all() {
    local rc=0
    component_mysql_verify     && log_ok "[70][verify] mysql OK"     || { log_err "[70][verify] mysql FAILED";     rc=1; }
    component_php_verify       && log_ok "[70][verify] php OK"       || { log_err "[70][verify] php FAILED";       rc=1; }
    case "${WP_HTTP_SERVER:-nginx}" in
        apache|apache2|httpd)
            component_apache_verify && log_ok "[70][verify] apache OK" || { log_err "[70][verify] apache FAILED"; rc=1; } ;;
        *)
            component_nginx_verify  && log_ok "[70][verify] nginx OK"  || { log_err "[70][verify] nginx FAILED";  rc=1; } ;;
    esac
    component_wordpress_verify && log_ok "[70][verify] wordpress OK" || { log_err "[70][verify] wordpress FAILED"; rc=1; }
    component_http_verify      && log_ok "[70][verify] http-loads OK" || { log_err "[70][verify] http-loads FAILED"; rc=1; }
    if [ "${WP_FIREWALL:-0}" = "1" ]; then
        component_firewall_verify && log_ok "[70][verify] firewall OK" || { log_err "[70][verify] firewall FAILED (port ${WP_SITE_PORT}/tcp not allowed in UFW)"; rc=1; }
    fi
    if [ "${WP_HTTPS:-0}" = "1" ] || [ -f "$ROOT/.installed/70-https.ok" ]; then
        component_https_verify && log_ok "[70][verify] https OK" || { log_err "[70][verify] https FAILED (no cert lineage for ${WP_SERVER_NAME%% *})"; rc=1; }
    fi
    if [ $rc -eq 0 ]; then
        log_ok "[70][verify] OK -- all components reachable"
        if [ "${WP_HTTPS:-0}" = "1" ] || [ -f "$ROOT/.installed/70-https.ok" ]; then
            log_info "[70][verify] site: https://${WP_SERVER_NAME%% *}/"
        else
            log_info "[70][verify] site: http://${WP_SERVER_NAME%% *}:${WP_SITE_PORT}/"
        fi
    else
        log_err "[70][verify] FAILED -- see lines above for the failing component"
    fi
    return $rc
}

_uninstall_all() {
    log_info "[70][uninstall] === uninstall stage start ==="
    log_info "[70][uninstall] removing: WordPress files, DB, web vhost (nginx & apache), firewall rule, HTTPS certs"
    log_info "[70][uninstall] PRESERVING: PHP packages, MySQL/MariaDB packages and data"
    local rc=0
    # HTTPS first so we revoke certs while nginx/apache still has the vhost
    # certbot recognizes (avoids 'no installer' warnings).
    component_https_uninstall    || rc=$?
    component_wordpress_uninstall || rc=$?
    component_firewall_uninstall  || rc=$?
    component_nginx_uninstall     || rc=$?
    component_apache_uninstall    || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "[70][uninstall] === uninstall complete ==="
    else
        log_warn "[70][uninstall] uninstall finished with errors (rc=$rc) -- see lines above"
    fi
    log_info "[70] To also remove PHP / MySQL packages, run explicitly:"
    log_info "[70]   $0 uninstall php"
    log_info "[70]   $0 uninstall mysql"
    return $rc
}

# ---- main -------------------------------------------------------------------
rc=0
case "$VERB" in
    install)
        if [ -n "$SUBCOMPONENT" ]; then
            _install_one "$SUBCOMPONENT" || rc=$?
        else
            _install_all || rc=$?
        fi
        if [ $rc -eq 0 ]; then
            echo ""
            log_info "[70] === WordPress installation summary ==="
            log_info "[70]   site URL    : http://${WP_SERVER_NAME}:${WP_SITE_PORT}/"
            log_info "[70]   install dir : $WP_INSTALL_PATH"
            log_info "[70]   db engine   : $WP_DB_ENGINE (port $WP_MYSQL_PORT)"
            log_info "[70]   credentials : $ROOT/.installed/70-wordpress-credentials.json"
            log_info "[70] Now visit the site URL in a browser to finish the WordPress setup wizard."
            if [ "${WP_SHOW_CREDENTIALS:-0}" = "1" ]; then
                # Only after a successful install, and only when explicitly
                # opted in -- printing credentials by default would leak them
                # into shared CI logs.
                component_wordpress_show_credentials || true
            else
                log_info "[70]   (run '$0 show-credentials' to print the DB password + salts location)"
            fi
        fi
        ;;
    check)
        _check_all || rc=$?
        ;;
    show-credentials)
        if [ "$SHOW_CREDS_JSON" = "1" ]; then
            component_wordpress_show_credentials --json || rc=$?
        else
            component_wordpress_show_credentials || rc=$?
        fi
        ;;
    repair)
        rm -f "$ROOT/.installed/70-mysql.ok" "$ROOT/.installed/70-php.ok" \
              "$ROOT/.installed/70-nginx.ok" "$ROOT/.installed/70-apache.ok" \
              "$ROOT/.installed/70-wordpress.ok"
        _install_all || rc=$?
        ;;
    uninstall)
        if [ -n "$SUBCOMPONENT" ]; then
            case "$SUBCOMPONENT" in
                mysql)     component_mysql_uninstall     ;;
                php)       component_php_uninstall       ;;
                nginx)     component_nginx_uninstall     ;;
                apache)    component_apache_uninstall    ;;
                firewall)  component_firewall_uninstall  ;;
                https)     component_https_uninstall     ;;
                wordpress|wp|wp-only) component_wordpress_uninstall ;;
            esac
        else
            _uninstall_all
        fi
        ;;
    *)
        log_err "[70] Unknown verb: '$VERB' -- use install|check|repair|uninstall"
        rc=2
        ;;
esac

exit $rc