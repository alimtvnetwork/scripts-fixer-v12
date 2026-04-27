#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/apache.sh
# Installs Apache2 with mpm_event + proxy_fcgi to talk to PHP-FPM.
# Honors WP_INSTALL_PATH / WP_SITE_PORT / WP_SERVER_NAME.
set -u

_apache_fpm_socket() {
    local svc="${WP_PHP_FPM_SERVICE:-}"
    if [ -n "$svc" ]; then
        local v="${svc#php}"; v="${v%-fpm}"
        if [ -S "/run/php/php${v}-fpm.sock" ]; then
            echo "/run/php/php${v}-fpm.sock"; return
        fi
    fi
    local sock
    sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1)"
    echo "${sock:-/run/php/php-fpm.sock}"
}

component_apache_verify() {
    command -v apache2 >/dev/null 2>&1 || return 1
    sudo systemctl is-active --quiet apache2 || return 1
    return 0
}

component_apache_install() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local port="${WP_SITE_PORT:-80}"
    local server_name="${WP_SERVER_NAME:-localhost}"
    log_info "[70][apache] starting installation (path=$install_path port=$port server_name=$server_name)"

    if ! command -v apache2 >/dev/null 2>&1; then
        sudo apt-get update -y >/dev/null 2>&1 || true
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y apache2; then
            log_err "[70][apache] apt-get install apache2 failed"
            return 1
        fi
    fi

    # Switch to mpm_event + enable proxy_fcgi/setenvif/rewrite (PHP-FPM path).
    sudo a2dismod mpm_prefork mpm_worker >/dev/null 2>&1 || true
    if ! sudo a2enmod mpm_event proxy proxy_fcgi setenvif rewrite >/dev/null 2>&1; then
        log_err "[70][apache] a2enmod failed for mpm_event/proxy_fcgi/setenvif/rewrite"
        return 1
    fi

    local sock; sock="$(_apache_fpm_socket)"
    if [ ! -S "$sock" ]; then
        log_warn "[70][apache] PHP-FPM socket not found at: $sock (failure: -S test failed; vhost will be written but PHP requests will 503 until php-fpm starts)"
    fi

    # Custom port -> needs Listen directive update.
    if [ "$port" != "80" ]; then
        local ports_conf="/etc/apache2/ports.conf"
        if ! sudo grep -qE "^Listen ${port}\$" "$ports_conf" 2>/dev/null; then
            log_info "[70][apache] adding 'Listen ${port}' to $ports_conf"
            if ! echo "Listen ${port}" | sudo tee -a "$ports_conf" >/dev/null; then
                log_file_error "$ports_conf" "tee append 'Listen ${port}' failed"
                return 1
            fi
        fi
    fi

    local vhost="/etc/apache2/sites-available/wordpress.conf"
    log_info "[70][apache] writing vhost -> $vhost"
    if ! sudo tee "$vhost" >/dev/null <<EOF
# Written by 70-install-wordpress-ubuntu (do not edit by hand)
<VirtualHost *:${port}>
    ServerName ${server_name}
    DocumentRoot ${install_path}
    DirectoryIndex index.php index.html

    <Directory ${install_path}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \\.php\$>
        SetHandler "proxy:unix:${sock}|fcgi://localhost"
    </FilesMatch>

    <Files ".ht*">
        Require all denied
    </Files>

    ErrorLog \${APACHE_LOG_DIR}/wordpress-error.log
    CustomLog \${APACHE_LOG_DIR}/wordpress-access.log combined
</VirtualHost>
EOF
    then
        log_file_error "$vhost" "tee failed while writing apache vhost"
        return 1
    fi

    # Disable default site to avoid :80 conflicts.
    sudo a2dissite 000-default >/dev/null 2>&1 || true
    if ! sudo a2ensite wordpress >/dev/null 2>&1; then
        log_err "[70][apache] a2ensite wordpress failed"
        return 1
    fi

    if ! sudo apache2ctl configtest 2>&1 | tee /tmp/apache-t.log | grep -qi "Syntax OK"; then
        log_err "[70][apache] 'apache2ctl configtest' failed -- see /tmp/apache-t.log:"
        sudo cat /tmp/apache-t.log >&2
        return 1
    fi

    sudo systemctl enable apache2 >/dev/null 2>&1 || true
    if ! sudo systemctl restart apache2; then
        log_err "[70][apache] systemctl restart apache2 failed -- run 'journalctl -u apache2' for the exact reason"
        return 1
    fi

    if ! component_apache_verify; then
        log_err "[70][apache] post-install verify failed (binary missing or service inactive)"
        return 1
    fi
    log_ok "[70][apache] installed OK (vhost=$vhost listening :${port})"
    mkdir -p "$ROOT/.installed" && touch "$ROOT/.installed/70-apache.ok"
    return 0
}

component_apache_uninstall() {
    sudo a2dissite wordpress >/dev/null 2>&1 || true
    sudo rm -f /etc/apache2/sites-available/wordpress.conf 2>/dev/null || true
    sudo systemctl reload apache2 2>/dev/null || true
    rm -f "$ROOT/.installed/70-apache.ok"
    log_ok "[70][apache] WordPress vhost removed (apache2 package left in place)"
}
