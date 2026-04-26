#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/mysql.sh
# Installs MySQL 8 (default) or MariaDB. Supports custom port + data dir
# when WP_MYSQL_PORT / WP_MYSQL_DATADIR are set in the environment.
set -u

_mysql_apt_pkg() {
    case "${WP_DB_ENGINE:-mysql}" in
        mariadb) echo "mariadb-server mariadb-client" ;;
        *)       echo "mysql-server mysql-client" ;;
    esac
}

_mysql_service_name() {
    case "${WP_DB_ENGINE:-mysql}" in
        mariadb) echo "mariadb" ;;
        *)       echo "mysql" ;;
    esac
}

_mysql_conf_dir() {
    # Both packages drop their per-package include here on Ubuntu.
    case "${WP_DB_ENGINE:-mysql}" in
        mariadb) echo "/etc/mysql/mariadb.conf.d" ;;
        *)       echo "/etc/mysql/mysql.conf.d"   ;;
    esac
}

component_mysql_verify() {
    local svc; svc="$(_mysql_service_name)"
    if ! command -v mysql >/dev/null 2>&1; then return 1; fi
    if ! sudo systemctl is-active --quiet "$svc"; then return 1; fi
    return 0
}

component_mysql_install() {
    log_info "[70][mysql] starting installation (engine=${WP_DB_ENGINE:-mysql})"
    if component_mysql_verify; then
        log_ok "[70][mysql] already installed and active -- skipping"
        mkdir -p "$ROOT/.installed" && touch "$ROOT/.installed/70-mysql.ok"
        return 0
    fi

    local pkgs; pkgs="$(_mysql_apt_pkg)"
    sudo apt-get update -y >/dev/null 2>&1 || true
    # shellcheck disable=SC2086 # $pkgs is a deliberately word-split package list
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs; then
        log_err "[70][mysql] apt-get install failed for: $pkgs"
        return 1
    fi

    # Apply custom port + data directory ONLY when the operator passed them
    # via interactive prompts. Defaults are left untouched so we don't move
    # a freshly-initialised data dir around for no reason.
    local port="${WP_MYSQL_PORT:-3306}"
    local datadir="${WP_MYSQL_DATADIR:-/var/lib/mysql}"
    local conf_dir; conf_dir="$(_mysql_conf_dir)"
    local conf_file="${conf_dir}/99-wordpress-installer.cnf"

    if [ "$port" != "3306" ] || [ "$datadir" != "/var/lib/mysql" ]; then
        if [ ! -d "$conf_dir" ]; then
            log_file_error "$conf_dir" "expected MySQL conf.d directory missing after package install"
            return 1
        fi
        log_info "[70][mysql] writing override config -> $conf_file (port=$port datadir=$datadir)"
        if ! sudo tee "$conf_file" >/dev/null <<EOF
# Written by 70-install-wordpress-ubuntu (do not edit by hand)
[mysqld]
port = ${port}
datadir = ${datadir}
EOF
        then
            log_file_error "$conf_file" "failed to write MySQL override config (tee returned non-zero)"
            return 1
        fi

        # Move the data dir if the operator changed it AND the default exists.
        if [ "$datadir" != "/var/lib/mysql" ]; then
            local svc; svc="$(_mysql_service_name)"
            sudo systemctl stop "$svc" 2>/dev/null || true
            if [ -d /var/lib/mysql ] && [ ! -d "$datadir" ]; then
                if ! sudo mkdir -p "$(dirname "$datadir")"; then
                    log_file_error "$(dirname "$datadir")" "mkdir -p failed for new datadir parent"
                    return 1
                fi
                if ! sudo rsync -a /var/lib/mysql/ "$datadir/"; then
                    log_file_error "$datadir" "rsync from /var/lib/mysql failed; aborting datadir move"
                    sudo systemctl start "$svc" 2>/dev/null || true
                    return 1
                fi
                sudo chown -R mysql:mysql "$datadir" || true
            fi
        fi
    fi

    local svc; svc="$(_mysql_service_name)"
    sudo systemctl enable "$svc" >/dev/null 2>&1 || true
    if ! sudo systemctl restart "$svc"; then
        log_err "[70][mysql] systemctl restart $svc failed -- check 'journalctl -u $svc' for the exact reason"
        return 1
    fi

    if ! component_mysql_verify; then
        log_err "[70][mysql] post-install verification failed (mysql binary or service inactive)"
        return 1
    fi
    log_ok "[70][mysql] installed OK (engine=${WP_DB_ENGINE:-mysql} port=${port} datadir=${datadir})"
    mkdir -p "$ROOT/.installed" && touch "$ROOT/.installed/70-mysql.ok"
    return 0
}

component_mysql_uninstall() {
    local pkgs; pkgs="$(_mysql_apt_pkg)"
    sudo systemctl stop "$(_mysql_service_name)" 2>/dev/null || true
    # shellcheck disable=SC2086 # $pkgs is a deliberately word-split package list
    sudo apt-get remove --purge -y $pkgs 2>/dev/null || true
    sudo rm -f "$(_mysql_conf_dir)/99-wordpress-installer.cnf" 2>/dev/null || true
    rm -f "$ROOT/.installed/70-mysql.ok"
    log_ok "[70][mysql] removed"
}