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
#   --site-port <n>       nginx HTTP port (default: 80)
#   --server-name <name>  nginx server_name (default: localhost)
#   --db-name <name>      WordPress DB name (default: wordpress)
#   --db-user <name>      WordPress DB user (default: wp_user)
#   --db-pass <pw>        WordPress DB password (default: auto-generate)
#   --http nginx|apache   HTTP server (default: nginx)
#   --firewall            open WP_SITE_PORT in UFW after install (UFW must
#                         be enabled separately; this only adds the rule)
#   -h | --help           show this help and exit
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
                mysql|php|nginx|apache|http|firewall|http-verify|wordpress|wp-only|wp|prereqs|prerequisites)
                    SUBCOMPONENT="$1"; shift ;;
            esac
            ;;
        -i|--interactive)  INTERACTIVE=1; shift ;;
        --db)              WP_DB_ENGINE="$2"; shift 2 ;;
        --php)             WP_PHP_VERSION="$2"; shift 2 ;;
        --port)            WP_MYSQL_PORT="$2"; shift 2 ;;
        --datadir)         WP_MYSQL_DATADIR="$2"; shift 2 ;;
        --path)            WP_INSTALL_PATH="$2"; shift 2 ;;
        --site-port)       WP_SITE_PORT="$2"; shift 2 ;;
        --server-name)     WP_SERVER_NAME="$2"; shift 2 ;;
        --db-name)         WP_DB_NAME="$2"; shift 2 ;;
        --db-user)         WP_DB_USER="$2"; shift 2 ;;
        --db-pass)         WP_DB_PASS="$2"; shift 2 ;;
        --http)            WP_HTTP_SERVER="$2"; shift 2 ;;
        --firewall)        WP_FIREWALL="1"; shift ;;
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

_run_interactive() {
    log_info "[70] Interactive mode -- press Enter to accept the [default]"
    WP_DB_ENGINE="$(_prompt    'DB engine (mysql|mariadb)'      "$WP_DB_ENGINE")"
    WP_MYSQL_PORT="$(_prompt   'MySQL port'                     "$WP_MYSQL_PORT")"
    WP_MYSQL_DATADIR="$(_prompt 'MySQL data dir'                "$WP_MYSQL_DATADIR")"
    WP_PHP_VERSION="$(_prompt  'PHP version (8.1|8.2|8.3|latest)' "$WP_PHP_VERSION")"
    WP_INSTALL_PATH="$(_prompt 'WordPress install path'         "$WP_INSTALL_PATH")"
    WP_SITE_PORT="$(_prompt    'nginx HTTP port'                "$WP_SITE_PORT")"
    WP_SERVER_NAME="$(_prompt  'nginx server_name'              "$WP_SERVER_NAME")"
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
    if [ $rc -eq 0 ]; then
        log_ok "[70][verify] OK -- all components reachable"
        log_info "[70][verify] site: http://${WP_SERVER_NAME}:${WP_SITE_PORT}/"
    else
        log_err "[70][verify] FAILED -- see lines above for the failing component"
    fi
    return $rc
}

_uninstall_all() {
    component_wordpress_uninstall
    component_firewall_uninstall
    component_nginx_uninstall
    component_apache_uninstall
    # Leave php + mysql in place by default (other apps may depend on them).
    # The operator can run `install uninstall mysql` / `install uninstall php`
    # explicitly to remove those packages too.
    log_info "[70] WordPress + nginx vhost removed. To also remove PHP / MySQL packages, run: $0 uninstall php   and   $0 uninstall mysql"
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
        fi
        ;;
    check)
        _check_all || rc=$?
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