#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/php.sh
# Installs PHP-FPM + WordPress-required extensions. Honors WP_PHP_VERSION
# (8.1 | 8.2 | 8.3 | latest -- adds Ondrej PPA when a specific old version
# is requested that Ubuntu's default repo doesn't ship).
set -u

_php_resolve_version() {
    local req="${WP_PHP_VERSION:-latest}"
    if [ "$req" = "latest" ]; then
        # Use whatever apt's `php-fpm` meta-package resolves to (default PHP).
        echo "default"
        return
    fi
    case "$req" in
        8.1|8.2|8.3) echo "$req" ;;
        *)
            log_warn "[70][php] unknown WP_PHP_VERSION='$req' -- falling back to 'default'"
            echo "default"
            ;;
    esac
}

_php_pkg_list() {
    local v="$1"
    if [ "$v" = "default" ]; then
        echo "php-fpm php-cli php-mysql php-xml php-curl php-gd php-mbstring php-zip php-intl php-bcmath php-soap php-imagick"
    else
        # Ondrej PPA naming: php8.x-fpm etc.
        echo "php${v}-fpm php${v}-cli php${v}-mysql php${v}-xml php${v}-curl php${v}-gd php${v}-mbstring php${v}-zip php${v}-intl php${v}-bcmath php${v}-soap php${v}-imagick"
    fi
}

_php_fpm_service() {
    local v="$1"
    if [ "$v" = "default" ]; then
        # Whatever php meta installed; query the unit pattern.
        local svc
        svc="$(systemctl list-unit-files 2>/dev/null | awk '/^php[0-9.]+-fpm\.service/ {print $1; exit}')"
        echo "${svc:-php-fpm}"
    else
        echo "php${v}-fpm"
    fi
}

component_php_verify() {
    command -v php >/dev/null 2>&1 || return 1
    php -m 2>/dev/null | grep -qi '^mysqli$' || return 1
    return 0
}

component_php_install() {
    local v; v="$(_php_resolve_version)"
    log_info "[70][php] starting installation (requested='${WP_PHP_VERSION:-latest}', resolved='$v')"

    if [ "$v" != "default" ]; then
        # Need Ondrej PPA for non-default PHP versions on Ubuntu.
        if ! grep -rq 'ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            log_info "[70][php] adding Ondrej PHP PPA (required for php${v})"
            if ! sudo add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1; then
                log_err "[70][php] add-apt-repository ppa:ondrej/php failed -- check that 'software-properties-common' is installed"
                return 1
            fi
        fi
    fi

    sudo apt-get update -y >/dev/null 2>&1 || true
    local pkgs; pkgs="$(_php_pkg_list "$v")"
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs; then
        log_err "[70][php] apt-get install failed for: $pkgs"
        return 1
    fi

    local svc; svc="$(_php_fpm_service "$v")"
    sudo systemctl enable "$svc" >/dev/null 2>&1 || true
    if ! sudo systemctl restart "$svc"; then
        log_err "[70][php] systemctl restart $svc failed -- run 'journalctl -u $svc' for the exact reason"
        return 1
    fi

    if ! component_php_verify; then
        log_err "[70][php] post-install verify failed -- 'php -m' missing 'mysqli'"
        return 1
    fi
    local installed_ver; installed_ver="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '?')"
    log_ok "[70][php] installed OK (php=$installed_ver fpm=$svc)"
    # Export for downstream nginx config
    export WP_PHP_FPM_SERVICE="$svc"
    mkdir -p "$ROOT/.installed" && touch "$ROOT/.installed/70-php.ok"
    return 0
}

component_php_uninstall() {
    sudo apt-get remove --purge -y 'php*' 2>/dev/null || true
    rm -f "$ROOT/.installed/70-php.ok"
    log_ok "[70][php] removed"
}