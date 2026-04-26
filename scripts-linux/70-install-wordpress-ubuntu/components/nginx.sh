#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/nginx.sh
# Installs nginx and writes a WordPress vhost using PHP-FPM.
# Honors WP_INSTALL_PATH / WP_SITE_PORT / WP_SERVER_NAME.
set -u

_nginx_fpm_socket() {
    # Try the explicit service name from php.sh first; fall back to a glob.
    local svc="${WP_PHP_FPM_SERVICE:-}"
    if [ -n "$svc" ]; then
        local v="${svc#php}"; v="${v%-fpm}"
        if [ -S "/run/php/php${v}-fpm.sock" ]; then
            echo "/run/php/php${v}-fpm.sock"
            return
        fi
    fi
    # Generic discovery -- pick the newest socket present.
    local sock
    sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1)"
    echo "${sock:-/run/php/php-fpm.sock}"
}

component_nginx_verify() {
    command -v nginx >/dev/null 2>&1 || return 1
    sudo systemctl is-active --quiet nginx || return 1
    return 0
}

component_nginx_install() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local port="${WP_SITE_PORT:-80}"
    local server_name="${WP_SERVER_NAME:-localhost}"
    log_info "[70][nginx] starting installation (path=$install_path port=$port server_name=$server_name)"

    if ! command -v nginx >/dev/null 2>&1; then
        sudo apt-get update -y >/dev/null 2>&1 || true
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx; then
            log_err "[70][nginx] apt-get install nginx failed"
            return 1
        fi
    fi

    local sock; sock="$(_nginx_fpm_socket)"
    if [ ! -S "$sock" ]; then
        log_warn "[70][nginx] PHP-FPM socket not found at: $sock (failure: -S test failed; nginx vhost will be written but PHP requests will 502 until php-fpm starts)"
    fi

    local vhost="/etc/nginx/sites-available/wordpress.conf"
    log_info "[70][nginx] writing vhost -> $vhost"
    if ! sudo tee "$vhost" >/dev/null <<EOF
# Written by 70-install-wordpress-ubuntu (do not edit by hand)
server {
    listen ${port};
    listen [::]:${port};
    server_name ${server_name};
    root ${install_path};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${sock};
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOF
    then
        log_file_error "$vhost" "tee failed while writing nginx vhost"
        return 1
    fi

    # Enable site, disable default to avoid port conflicts.
    if ! sudo ln -sf "$vhost" /etc/nginx/sites-enabled/wordpress.conf; then
        log_file_error "/etc/nginx/sites-enabled/wordpress.conf" "ln -sf failed"
        return 1
    fi
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    if ! sudo nginx -t 2>&1 | tee /tmp/nginx-t.log >/dev/null; then
        log_err "[70][nginx] 'nginx -t' configuration test failed -- see /tmp/nginx-t.log:"
        sudo cat /tmp/nginx-t.log >&2
        return 1
    fi

    sudo systemctl enable nginx >/dev/null 2>&1 || true
    if ! sudo systemctl restart nginx; then
        log_err "[70][nginx] systemctl restart nginx failed"
        return 1
    fi

    if ! component_nginx_verify; then
        log_err "[70][nginx] post-install verify failed (binary missing or service inactive)"
        return 1
    fi
    log_ok "[70][nginx] installed OK (vhost=$vhost listening :${port})"
    mkdir -p "$ROOT/.installed" && touch "$ROOT/.installed/70-nginx.ok"
    return 0
}

component_nginx_uninstall() {
    sudo rm -f /etc/nginx/sites-enabled/wordpress.conf 2>/dev/null || true
    sudo rm -f /etc/nginx/sites-available/wordpress.conf 2>/dev/null || true
    sudo systemctl reload nginx 2>/dev/null || true
    rm -f "$ROOT/.installed/70-nginx.ok"
    log_ok "[70][nginx] WordPress vhost removed (nginx package left in place)"
}