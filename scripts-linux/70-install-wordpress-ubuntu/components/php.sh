#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/php.sh
# Installs PHP-FPM + WordPress-required extensions. Honors WP_PHP_VERSION
# (8.1 | 8.2 | 8.3 | latest -- adds Ondrej PPA when a specific old version
# is requested that Ubuntu's default repo doesn't ship).
#
# Repository policy (confirmed v0.155.0):
#   * Auto-detects Ubuntu 20.04 / 22.04 / 24.04 via /etc/os-release.
#   * 'latest' (default)  -> APT only, no PPA. Resolves to whatever the
#                            distro ships:   24.04 -> 8.3
#                                            22.04 -> 8.1
#                                            20.04 -> 7.4  (EOL warning)
#   * Pinned --php X.Y    -> APT first; only adds ppa:ondrej/php when the
#                            distro's default APT repo does NOT ship X.Y.
set -u

# Map Ubuntu release -> the PHP version its default APT repo ships.
# Used to decide whether a pinned --php X.Y needs the Ondrej PPA.
_php_distro_default() {
    local ver="${1:-}"
    case "$ver" in
        24.04|24.10|25.04) echo "8.3" ;;
        22.04|22.10|23.04|23.10) echo "8.1" ;;
        20.04|20.10|21.04|21.10) echo "7.4" ;;
        *) echo "" ;;   # unknown release -> assume PPA needed for any pin
    esac
}

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

# Strict verify: every WordPress-required extension must be loaded, and the
# PHP version must be >= 7.4 (WordPress 6.x minimum). Logs the missing list
# on failure so the operator knows exactly what to fix.
#
# Required set: mysqli mbstring xml curl intl gd
# (zip/bcmath/soap/imagick are installed but treated as optional here.)
component_php_verify_strict() {
    if ! command -v php >/dev/null 2>&1; then
        log_err "[70][php][verify] 'php' binary not found in PATH"
        return 1
    fi
    local ver; ver="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '')"
    local major minor
    major="$(printf '%s' "$ver" | cut -d. -f1)"
    minor="$(printf '%s' "$ver" | cut -d. -f2)"
    case "$major$minor" in
        ''|*[!0-9]*)
            log_err "[70][php][verify] could not parse PHP version (got '$ver')"
            return 1
            ;;
    esac
    if [ "$major" -lt 7 ] || { [ "$major" -eq 7 ] && [ "$minor" -lt 4 ]; }; then
        log_err "[70][php][verify] PHP $ver is below the WordPress minimum (7.4)"
        return 1
    fi
    log_info "[70][php][verify] PHP version $ver detected (>= 7.4 OK)"

    local required="mysqli mbstring xml curl intl gd"
    local loaded; loaded="$(php -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    local missing="" ext
    for ext in $required; do
        if ! printf '%s\n' "$loaded" | grep -qx "$ext"; then
            missing="$missing $ext"
        fi
    done
    if [ -n "$missing" ]; then
        log_err "[70][php][verify] missing required PHP extensions:$missing"
        log_err "[70][php][verify] install with: sudo apt-get install -y$(printf ' php-%s' $missing)"
        return 1
    fi
    log_ok "[70][php][verify] all required extensions present ($required)"
    return 0
}

component_php_install() {
    local v; v="$(_php_resolve_version)"

    # ---- detect Ubuntu release & decide repo policy ------------------------
    local ubu_ver distro_default needs_ppa=0
    ubu_ver="$(get_ubuntu_version 2>/dev/null || echo unknown)"
    distro_default="$(_php_distro_default "$ubu_ver")"
    log_info "[70][php] starting installation (requested='${WP_PHP_VERSION:-latest}', resolved='$v', ubuntu='$ubu_ver', apt-default='${distro_default:-?}')"

    if [ "$v" = "default" ]; then
        # 'latest' = APT only. Warn when distro default is EOL (PHP 7.4).
        case "$distro_default" in
            7.4) log_warn "[70][php] Ubuntu $ubu_ver ships PHP 7.4 (EOL since Nov 2022); WordPress will run but is unsupported. Pin --php 8.1|8.2|8.3 to use Ondrej PPA." ;;
            "")  log_warn "[70][php] could not detect Ubuntu version; using whatever 'php-fpm' resolves to via APT" ;;
        esac
    else
        # Pinned version: only add Ondrej PPA when the distro's default APT
        # repo does NOT already ship that exact version.
        if [ -n "$distro_default" ] && [ "$distro_default" = "$v" ]; then
            log_info "[70][php] Ubuntu $ubu_ver default APT already provides PHP $v -- skipping Ondrej PPA"
        else
            needs_ppa=1
        fi
    fi

    if [ "$needs_ppa" = "1" ]; then
        if ! grep -rq 'ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            log_info "[70][php] adding Ondrej PHP PPA (Ubuntu $ubu_ver default is '${distro_default:-unknown}', requested '$v')"
            if ! sudo add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1; then
                log_err "[70][php] add-apt-repository ppa:ondrej/php failed -- check that 'software-properties-common' is installed (apt-get install software-properties-common)"
                return 1
            fi
        else
            log_info "[70][php] Ondrej PPA already present"
        fi
    fi

    sudo apt-get update -y >/dev/null 2>&1 || true
    local pkgs; pkgs="$(_php_pkg_list "$v")"
    # shellcheck disable=SC2086 # $pkgs is a deliberately word-split package list
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