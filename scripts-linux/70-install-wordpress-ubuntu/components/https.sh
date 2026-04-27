#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/https.sh
# Optional Let's Encrypt / certbot HTTPS for the WordPress vhost.
# Honors: WP_HTTPS, WP_HTTPS_EMAIL, WP_SERVER_NAME, WP_HTTP_SERVER,
#         WP_INSTALL_PATH, WP_HTTPS_STAGING.
#
# Strategy:
#   nginx  -> certbot --nginx (it edits the vhost in place; we then rewrite
#             our own vhost with explicit HTTP->HTTPS redirect + ssl_*
#             directives so the result is deterministic and idempotent).
#   apache -> certbot --apache (plugin handles redirect + SSL conf cleanly).
# Cert renewal: certbot installs a systemd timer (certbot.timer) on apt
# packaging -- we just verify it's enabled.
set -u

# --- helpers ----------------------------------------------------------------

_https_is_real_hostname() {
    # Reject localhost / IPs / single-label names (Let's Encrypt requires a
    # FQDN with at least one dot AND a public DNS record).
    local host="$1"
    case "$host" in
        ""|localhost|localhost.localdomain) return 1 ;;
    esac
    # IPv4 literal?
    if printf '%s' "$host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        return 1
    fi
    # Must have at least one dot.
    case "$host" in *.*) return 0 ;; *) return 1 ;; esac
}

_https_collect_d_args() {
    # Echo "-d host1 -d host2 ..." for every space-separated token in
    # WP_SERVER_NAME that passes _https_is_real_hostname. Tokens that don't
    # pass are logged and skipped.
    local out="" token
    # shellcheck disable=SC2206
    local hosts=( ${WP_SERVER_NAME:-} )
    for token in "${hosts[@]}"; do
        if _https_is_real_hostname "$token"; then
            out="$out -d $token"
        else
            log_warn "[70][https] skipping non-FQDN server_name token: '$token'"
        fi
    done
    printf '%s' "$out"
}

_https_certbot_install() {
    # Install certbot + the right plugin for the active HTTP server.
    local server="${WP_HTTP_SERVER:-nginx}" plugin_pkg
    case "$server" in
        apache|apache2|httpd) plugin_pkg="python3-certbot-apache" ;;
        *)                    plugin_pkg="python3-certbot-nginx"  ;;
    esac

    if command -v certbot >/dev/null 2>&1 && \
       dpkg -s "$plugin_pkg" >/dev/null 2>&1; then
        log_info "[70][https] certbot + $plugin_pkg already installed"
        return 0
    fi

    log_info "[70][https] installing certbot + $plugin_pkg"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            certbot "$plugin_pkg"; then
        log_err "[70][https] apt-get install certbot $plugin_pkg failed"
        return 1
    fi
    return 0
}

# --- nginx vhost rewrite (HTTP -> HTTPS + ssl directives) -------------------

_https_rewrite_nginx_vhost() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local server_name="${WP_SERVER_NAME:-localhost}"
    local primary
    # First server_name token = cert lineage name on disk.
    # shellcheck disable=SC2206
    local hosts=( $server_name )
    primary="${hosts[0]}"

    local cert_dir="/etc/letsencrypt/live/${primary}"
    if [ ! -f "${cert_dir}/fullchain.pem" ] || \
       [ ! -f "${cert_dir}/privkey.pem" ]; then
        log_file_error "${cert_dir}/fullchain.pem" "certificate not present after certbot run -- cannot rewrite nginx vhost with SSL"
        return 1
    fi

    # Discover FPM socket the same way nginx.sh does.
    local sock
    if declare -f _nginx_fpm_socket >/dev/null 2>&1; then
        sock="$(_nginx_fpm_socket)"
    else
        sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1)"
        sock="${sock:-/run/php/php-fpm.sock}"
    fi

    local vhost="/etc/nginx/sites-available/wordpress.conf"
    log_info "[70][https] rewriting nginx vhost with HTTPS + redirect -> $vhost"
    if ! sudo tee "$vhost" >/dev/null <<EOF
# Written by 70-install-wordpress-ubuntu (HTTPS profile, do not edit by hand)
# Cert lineage: ${primary}  (other names served via server_name on :443)

# ---- HTTP :80 -- redirect everything to HTTPS ----
server {
    listen 80;
    listen [::]:80;
    server_name ${server_name};

    # ACME http-01 challenges land here on renewal.
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ---- HTTPS :443 -- the real WordPress vhost ----
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${server_name};

    ssl_certificate     ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

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
        log_file_error "$vhost" "tee failed while rewriting HTTPS nginx vhost"
        return 1
    fi

    # Make sure certbot's recommended SSL options + dhparams exist (certbot
    # writes them on first run, but verify so a missing include doesn't
    # silently break nginx -t).
    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        log_file_error "/etc/letsencrypt/options-ssl-nginx.conf" "missing -- certbot --nginx should have written it; HTTPS vhost will fail nginx -t"
        return 1
    fi
    if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
        log_warn "[70][https] /etc/letsencrypt/ssl-dhparams.pem missing -- generating (this can take ~1 min)"
        if ! sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 \
                2>/dev/null; then
            log_file_error "/etc/letsencrypt/ssl-dhparams.pem" "openssl dhparam failed"
            return 1
        fi
    fi

    if ! sudo nginx -t 2>&1 | tee /tmp/nginx-https-t.log >/dev/null; then
        log_err "[70][https] 'nginx -t' failed AFTER writing HTTPS vhost -- see /tmp/nginx-https-t.log:"
        sudo cat /tmp/nginx-https-t.log >&2
        return 1
    fi
    if ! sudo systemctl reload nginx; then
        log_err "[70][https] systemctl reload nginx failed after writing HTTPS vhost"
        return 1
    fi
    return 0
}

# --- public API -------------------------------------------------------------

component_https_verify() {
    # Pass if:
    #   - certbot binary present
    #   - at least one cert lineage exists for the primary server_name
    #   - cert is not expired (`certbot certificates` reports VALID days > 0)
    command -v certbot >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2206
    local hosts=( ${WP_SERVER_NAME:-} )
    local primary="${hosts[0]:-}"
    [ -z "$primary" ] && return 1
    [ -f "/etc/letsencrypt/live/${primary}/fullchain.pem" ] || return 1
    return 0
}

component_https_install() {
    if [ "${WP_HTTPS:-0}" != "1" ]; then
        log_info "[70][https] WP_HTTPS=0 -- skipping (use --https to enable)"
        return 0
    fi

    log_info "[70][https] === HTTPS stage start ==="
    log_info "[70][https] server_name='${WP_SERVER_NAME:-}' http_server='${WP_HTTP_SERVER:-nginx}' staging='${WP_HTTPS_STAGING:-0}'"

    # 1. Refuse non-FQDN setups loudly -- Let's Encrypt will reject them and
    #    burn rate-limit budget on the way out.
    local d_args; d_args="$(_https_collect_d_args)"
    if [ -z "$d_args" ]; then
        log_err "[70][https] WP_SERVER_NAME='${WP_SERVER_NAME}' has no public FQDN to request a certificate for. Set --server-name to a real domain (e.g. example.com www.example.com) and re-run 'install https'."
        return 2
    fi

    # 2. Email is required by Let's Encrypt for renewal warnings.
    local email="${WP_HTTPS_EMAIL:-}"
    local email_args
    if [ -z "$email" ]; then
        log_warn "[70][https] WP_HTTPS_EMAIL not set -- requesting cert with --register-unsafely-without-email (you will NOT receive renewal failure notices). Set --email <addr> to fix."
        email_args="--register-unsafely-without-email"
    else
        email_args="--email $email --no-eff-email"
    fi

    # 3. certbot itself.
    if ! _https_certbot_install; then
        return 1
    fi

    # 4. Pre-check: HTTP must be reachable for http-01 challenge. We use
    #    component_http_verify if available, but only WARN -- certbot's own
    #    error messages are clearer than ours when the challenge fails.
    if declare -f component_http_verify >/dev/null 2>&1; then
        if ! component_http_verify >/dev/null 2>&1; then
            log_warn "[70][https] HTTP verify failed before certbot run -- if challenge fails, fix DNS/firewall (port 80 must reach this host from the internet) and retry"
        fi
    fi

    # 5. Issue / renew the certificate.
    local server="${WP_HTTP_SERVER:-nginx}" plugin_flag
    case "$server" in
        apache|apache2|httpd) plugin_flag="--apache" ;;
        *)                    plugin_flag="--nginx"  ;;
    esac

    local staging_flag=""
    if [ "${WP_HTTPS_STAGING:-0}" = "1" ]; then
        staging_flag="--staging"
        log_info "[70][https] using Let's Encrypt STAGING environment (cert will NOT be browser-trusted)"
    fi

    log_info "[70][https] running: certbot $plugin_flag --non-interactive --agree-tos $email_args $staging_flag $d_args --redirect"
    # shellcheck disable=SC2086  # word-splitting on $d_args / $email_args is intentional
    if ! sudo certbot $plugin_flag --non-interactive --agree-tos \
            $email_args $staging_flag $d_args --redirect \
            2>&1 | tee /tmp/certbot-70.log; then
        log_err "[70][https] certbot failed -- see /tmp/certbot-70.log and /var/log/letsencrypt/letsencrypt.log"
        return 1
    fi

    # 6. For nginx, replace certbot's edits with our deterministic vhost so
    #    re-running 'install' doesn't drift. For apache, certbot's plugin
    #    output is already deterministic enough (it writes wordpress-le-ssl
    #    .conf alongside our vhost).
    case "$server" in
        apache|apache2|httpd)
            log_info "[70][https] apache: certbot wrote wordpress-le-ssl.conf alongside the existing vhost"
            ;;
        *)
            if ! _https_rewrite_nginx_vhost; then
                log_err "[70][https] post-cert nginx vhost rewrite failed"
                return 1
            fi
            ;;
    esac

    # 7. Verify renewal timer is enabled (apt-installed certbot ships it).
    if systemctl list-unit-files 2>/dev/null | grep -q '^certbot.timer'; then
        sudo systemctl enable --now certbot.timer >/dev/null 2>&1 || \
            log_warn "[70][https] could not enable certbot.timer (renewals may not run automatically)"
    else
        log_warn "[70][https] certbot.timer unit not found -- automatic renewal may not be configured. Run 'sudo certbot renew --dry-run' to check."
    fi

    # 8. Persist marker + chosen primary host so uninstall knows what to revoke.
    mkdir -p "$ROOT/.installed"
    # shellcheck disable=SC2206
    local hosts=( ${WP_SERVER_NAME} )
    echo "${hosts[0]}" | sudo tee "$ROOT/.installed/70-https.primary" >/dev/null
    touch "$ROOT/.installed/70-https.ok"
    log_ok "[70][https] === HTTPS stage complete (cert lineage: ${hosts[0]}) ==="
    log_info "[70][https] site: https://${hosts[0]}/"
    return 0
}

component_https_uninstall() {
    log_info "[70][https] uninstall: revoking + deleting certificates"
    local primary=""
    if [ -f "$ROOT/.installed/70-https.primary" ]; then
        primary="$(cat "$ROOT/.installed/70-https.primary" 2>/dev/null || true)"
    fi
    if [ -z "$primary" ]; then
        # shellcheck disable=SC2206
        local hosts=( ${WP_SERVER_NAME:-} )
        primary="${hosts[0]:-}"
    fi
    if [ -z "$primary" ]; then
        log_warn "[70][https] no primary host known -- skipping certbot delete (manually run 'certbot certificates' to inspect)"
    elif ! command -v certbot >/dev/null 2>&1; then
        log_warn "[70][https] certbot not installed -- nothing to revoke"
    elif [ ! -d "/etc/letsencrypt/live/${primary}" ]; then
        log_info "[70][https] no cert lineage for '${primary}' -- nothing to revoke"
    else
        if ! sudo certbot delete --non-interactive --cert-name "$primary" 2>&1 | \
                tee /tmp/certbot-delete-70.log; then
            log_warn "[70][https] 'certbot delete --cert-name $primary' failed -- see /tmp/certbot-delete-70.log"
        else
            log_ok "[70][https] removed cert lineage: $primary"
        fi
    fi
    rm -f "$ROOT/.installed/70-https.ok" "$ROOT/.installed/70-https.primary"
    return 0
}
