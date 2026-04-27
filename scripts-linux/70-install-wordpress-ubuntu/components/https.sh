#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/https.sh
# Optional Let's Encrypt / certbot HTTPS for the WordPress vhost.
# Honors: WP_HTTPS, WP_HTTPS_EMAIL, WP_SERVER_NAME, WP_HTTP_SERVER,
#         WP_INSTALL_PATH, WP_HTTPS_STAGING,
#         WP_DNS_PROVIDER, WP_DNS_CREDENTIALS, WP_HTTPS_WILDCARD,
#         WP_DNS_PROPAGATION.
#
# Challenge selection (auto):
#   * --wildcard FORCES DNS-01 -- Let's Encrypt does not allow wildcard
#     certs via HTTP-01.
#   * --dns <provider> selects the matching certbot-dns-* plugin and uses
#     DNS-01 for issuance.
#   * Default (no --dns, no --wildcard) = HTTP-01 via the --nginx/--apache
#     installer plugin (port 80 must reach the host from the internet).
#
# When DNS-01 is used, certbot only ISSUES the cert (`certonly`); it does
# NOT install it into the web server. We then call `certbot install
# --nginx|--apache --cert-name <primary>` to wire it in. nginx still gets
# our deterministic vhost rewrite afterwards.
#
# Cert renewal: certbot ships a systemd timer (certbot.timer) on apt
# packaging -- we enable it. DNS-01 renewals reuse the credentials file
# from the original issuance (stored in /etc/letsencrypt/renewal/*.conf),
# so renewals are unattended.
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

# HTTP-01 (single-host) -d args. WORDPRESS_HTTPS_WILDCARD ignored here.
_https_collect_d_args() {
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

# DNS-01-aware -d args. When wildcard mode is on, every FQDN is reduced to
# its apex and gets BOTH `-d example.com` and `-d *.example.com` so the
# cert covers root + any subdomain. www.* tokens are merged into the apex
# because the wildcard already covers them.
_https_collect_d_args_dns() {
    local out="" token base
    # shellcheck disable=SC2206
    local hosts=( ${WP_SERVER_NAME:-} )
    declare -A seen=()
    for token in "${hosts[@]}"; do
        _https_is_real_hostname "$token" || {
            log_warn "[70][https] skipping non-FQDN server_name token: '$token'"
            continue
        }
        if [ "${WP_HTTPS_WILDCARD:-0}" = "1" ]; then
            base="${token#www.}"
            if [ -z "${seen[$base]:-}" ]; then
                out="$out -d $base -d *.$base"
                seen[$base]=1
            fi
        else
            out="$out -d $token"
        fi
    done
    printf '%s' "$out"
}

_https_certbot_install() {
    # Install certbot + the right plugin(s):
    #   - installer plugin matching the active HTTP server (always)
    #   - DNS authenticator plugin matching WP_DNS_PROVIDER (when set)
    local server="${WP_HTTP_SERVER:-nginx}"
    local installer_pkg dns_pkg=""
    case "$server" in
        apache|apache2|httpd) installer_pkg="python3-certbot-apache" ;;
        *)                    installer_pkg="python3-certbot-nginx"  ;;
    esac

    case "${WP_DNS_PROVIDER:-}" in
        "")           dns_pkg="" ;;
        cloudflare)   dns_pkg="python3-certbot-dns-cloudflare" ;;
        route53)      dns_pkg="python3-certbot-dns-route53" ;;
        digitalocean) dns_pkg="python3-certbot-dns-digitalocean" ;;
        manual)       dns_pkg="" ;;  # built into certbot core
        *)
            log_err "[70][https] unsupported --dns provider: '${WP_DNS_PROVIDER}' (supported: cloudflare|route53|digitalocean|manual)"
            return 2
            ;;
    esac

    local need=0
    command -v certbot >/dev/null 2>&1 || need=1
    dpkg -s "$installer_pkg" >/dev/null 2>&1 || need=1
    if [ -n "$dns_pkg" ] && ! dpkg -s "$dns_pkg" >/dev/null 2>&1; then
        need=1
    fi
    if [ "$need" -eq 0 ]; then
        log_info "[70][https] certbot + $installer_pkg${dns_pkg:+ + $dns_pkg} already installed"
        return 0
    fi

    log_info "[70][https] installing certbot + $installer_pkg${dns_pkg:+ + $dns_pkg}"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            certbot "$installer_pkg" ${dns_pkg:+$dns_pkg}; then
        log_err "[70][https] apt-get install certbot $installer_pkg${dns_pkg:+ $dns_pkg} failed"
        return 1
    fi
    return 0
}

# Validate credentials file for the chosen provider. Enforces chmod 600
# (certbot refuses world/group readable creds). Returns rc=0 ok, 2 fatal.
_https_validate_dns_credentials() {
    local provider="${WP_DNS_PROVIDER:-}"
    local creds="${WP_DNS_CREDENTIALS:-}"
    case "$provider" in
        "" )
            return 0
            ;;
        manual)
            log_warn "[70][https] --dns manual: certbot will pause and prompt you to create _acme-challenge TXT records by hand. NOT suitable for unattended installs or auto-renewal."
            return 0
            ;;
        cloudflare|digitalocean)
            if [ -z "$creds" ]; then
                log_err "[70][https] --dns ${provider} requires --dns-credentials <path-to-ini-file>. Create a file containing 'dns_${provider}_api_token = <token>' and chmod it 600."
                return 2
            fi
            if [ ! -f "$creds" ]; then
                log_file_error "$creds" "DNS credentials file not found (expected INI format for certbot-dns-${provider})"
                return 2
            fi
            local mode
            mode="$(stat -c '%a' "$creds" 2>/dev/null || stat -f '%Lp' "$creds" 2>/dev/null || echo "")"
            if [ -n "$mode" ] && [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
                log_warn "[70][https] DNS credentials file '$creds' has mode $mode -- certbot requires 600 or 400. Fixing with 'chmod 600 $creds'."
                if ! sudo chmod 600 "$creds"; then
                    log_file_error "$creds" "chmod 600 failed -- certbot will reject the credentials file"
                    return 2
                fi
            fi
            return 0
            ;;
        route53)
            if [ -n "$creds" ]; then
                log_info "[70][https] --dns route53: ignoring --dns-credentials (route53 plugin reads ~/.aws/credentials or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)"
            fi
            if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && \
               [ ! -f "$HOME/.aws/credentials" ] && \
               [ ! -f "/root/.aws/credentials" ]; then
                log_warn "[70][https] --dns route53 but no AWS credentials found (checked AWS_ACCESS_KEY_ID env, ~/.aws/credentials, /root/.aws/credentials). certbot will fail unless your IAM role grants route53:ChangeResourceRecordSets."
            fi
            return 0
            ;;
    esac
}

# Build certbot authenticator + credentials flag string for the chosen
# provider. Echoes the flag string; caller word-splits it.
_https_dns_authenticator_flags() {
    local provider="${WP_DNS_PROVIDER:-}"
    local creds="${WP_DNS_CREDENTIALS:-}"
    local prop="${WP_DNS_PROPAGATION:-60}"
    case "$provider" in
        cloudflare)
            printf -- '--dns-cloudflare --dns-cloudflare-credentials %s --dns-cloudflare-propagation-seconds %s' \
                "$creds" "$prop" ;;
        route53)
            printf -- '--dns-route53 --dns-route53-propagation-seconds %s' "$prop" ;;
        digitalocean)
            printf -- '--dns-digitalocean --dns-digitalocean-credentials %s --dns-digitalocean-propagation-seconds %s' \
                "$creds" "$prop" ;;
        manual)
            printf -- '--manual --preferred-challenges dns --manual-public-ip-logging-ok' ;;
        *)
            printf -- '' ;;
    esac
}

# Wire a DNS-01-issued cert into the active web server. nginx still gets
# the deterministic vhost rewrite afterwards; this just teaches certbot
# which web server to install into.
_https_install_cert_into_webserver() {
    local server="${WP_HTTP_SERVER:-nginx}" installer_flag primary
    case "$server" in
        apache|apache2|httpd) installer_flag="--apache" ;;
        *)                    installer_flag="--nginx"  ;;
    esac
    # shellcheck disable=SC2206
    local hosts=( ${WP_SERVER_NAME} )
    primary="${hosts[0]}"
    log_info "[70][https] installing DNS-01 cert into web server: certbot install $installer_flag --cert-name $primary"
    if ! sudo certbot install $installer_flag --cert-name "$primary" \
            --non-interactive --redirect 2>&1 | tee -a /tmp/certbot-70.log; then
        log_err "[70][https] 'certbot install $installer_flag --cert-name $primary' failed -- cert was issued but not wired into the web server. See /tmp/certbot-70.log."
        return 1
    fi
    return 0
}

# --- nginx vhost rewrite (HTTP -> HTTPS + ssl directives) -------------------

_nginx_fpm_socket_inline() {
    if declare -f _nginx_fpm_socket >/dev/null 2>&1; then
        _nginx_fpm_socket; return
    fi
    local sock; sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1)"
    echo "${sock:-/run/php/php-fpm.sock}"
}

_https_rewrite_nginx_vhost() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local server_name="${WP_SERVER_NAME:-localhost}"
    local primary
    # shellcheck disable=SC2206
    local hosts=( $server_name )
    primary="${hosts[0]}"

    local cert_dir="/etc/letsencrypt/live/${primary}"
    if [ ! -f "${cert_dir}/fullchain.pem" ] || \
       [ ! -f "${cert_dir}/privkey.pem" ]; then
        log_file_error "${cert_dir}/fullchain.pem" "certificate not present after certbot run -- cannot rewrite nginx vhost with SSL"
        return 1
    fi

    local sock; sock="$(_nginx_fpm_socket_inline)"
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

    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        log_file_error "/etc/letsencrypt/options-ssl-nginx.conf" "missing -- certbot's nginx plugin should have written it; HTTPS vhost will fail nginx -t"
        return 1
    fi
    if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
        log_warn "[70][https] /etc/letsencrypt/ssl-dhparams.pem missing -- generating (this can take ~1 min)"
        if ! sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null; then
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
    log_info "[70][https] server_name='${WP_SERVER_NAME:-}' http_server='${WP_HTTP_SERVER:-nginx}' staging='${WP_HTTPS_STAGING:-0}' dns='${WP_DNS_PROVIDER:-<http-01>}' wildcard='${WP_HTTPS_WILDCARD:-0}'"

    # Wildcard requires DNS-01.
    if [ "${WP_HTTPS_WILDCARD:-0}" = "1" ] && [ -z "${WP_DNS_PROVIDER:-}" ]; then
        log_err "[70][https] --wildcard requires --dns <provider> (Let's Encrypt does not allow wildcard certs via HTTP-01). Choose cloudflare, route53, digitalocean, or manual."
        return 2
    fi

    # 1. Hostname / -d args
    local d_args
    if [ -n "${WP_DNS_PROVIDER:-}" ]; then
        d_args="$(_https_collect_d_args_dns)"
    else
        d_args="$(_https_collect_d_args)"
    fi
    if [ -z "$d_args" ]; then
        log_err "[70][https] WP_SERVER_NAME='${WP_SERVER_NAME:-}' has no public FQDN to request a certificate for. Set --server-name to a real domain (e.g. example.com www.example.com) and re-run."
        return 2
    fi

    # 2. Email
    local email="${WP_HTTPS_EMAIL:-}"
    local email_args
    if [ -z "$email" ]; then
        log_warn "[70][https] WP_HTTPS_EMAIL not set -- using --register-unsafely-without-email (you will NOT receive renewal-failure notices)"
        email_args="--register-unsafely-without-email"
    else
        email_args="--email $email --no-eff-email"
    fi

    # 3. DNS credentials sanity (no-op if HTTP-01)
    if ! _https_validate_dns_credentials; then
        return 2
    fi

    # 4. certbot + plugins
    if ! _https_certbot_install; then
        return 1
    fi

    # 5. Pre-check HTTP-01 reachability (only when using HTTP-01)
    if [ -z "${WP_DNS_PROVIDER:-}" ] && declare -f component_http_verify >/dev/null 2>&1; then
        if ! component_http_verify >/dev/null 2>&1; then
            log_warn "[70][https] HTTP verify failed before certbot run -- if challenge fails, fix DNS/firewall (port 80 must reach this host from the internet) and retry"
        fi
    fi

    local staging_flag=""
    if [ "${WP_HTTPS_STAGING:-0}" = "1" ]; then
        staging_flag="--staging"
        log_info "[70][https] using Let's Encrypt STAGING environment (cert will NOT be browser-trusted)"
    fi

    # 6. Issue
    local server="${WP_HTTP_SERVER:-nginx}" installer_flag
    case "$server" in
        apache|apache2|httpd) installer_flag="--apache" ;;
        *)                    installer_flag="--nginx"  ;;
    esac

    if [ -n "${WP_DNS_PROVIDER:-}" ]; then
        # DNS-01 path: certonly with the DNS authenticator, then install
        # the cert into the web server in a second step.
        local dns_flags; dns_flags="$(_https_dns_authenticator_flags)"
        log_info "[70][https] running: certbot certonly $dns_flags --non-interactive --agree-tos $email_args $staging_flag $d_args"
        # shellcheck disable=SC2086
        if ! sudo certbot certonly $dns_flags \
                --non-interactive --agree-tos \
                $email_args $staging_flag $d_args \
                2>&1 | tee /tmp/certbot-70.log; then
            log_err "[70][https] certbot certonly (DNS-01) failed -- see /tmp/certbot-70.log and /var/log/letsencrypt/letsencrypt.log"
            return 1
        fi
        if ! _https_install_cert_into_webserver; then
            return 1
        fi
    else
        # HTTP-01 path: single certbot call with the installer plugin.
        log_info "[70][https] running: certbot $installer_flag --non-interactive --agree-tos $email_args $staging_flag $d_args --redirect"
        # shellcheck disable=SC2086
        if ! sudo certbot $installer_flag --non-interactive --agree-tos \
                $email_args $staging_flag $d_args --redirect \
                2>&1 | tee /tmp/certbot-70.log; then
            log_err "[70][https] certbot (HTTP-01) failed -- see /tmp/certbot-70.log and /var/log/letsencrypt/letsencrypt.log"
            return 1
        fi
    fi

    # 7. Deterministic nginx vhost rewrite (apache: certbot's plugin output
    #    is already deterministic enough).
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

    # 8. Renewal timer
    if systemctl list-unit-files 2>/dev/null | grep -q '^certbot.timer'; then
        sudo systemctl enable --now certbot.timer >/dev/null 2>&1 || \
            log_warn "[70][https] could not enable certbot.timer"
    else
        log_warn "[70][https] certbot.timer unit not found -- run 'sudo certbot renew --dry-run' to verify auto-renewal"
    fi

    # 9. Markers
    mkdir -p "$ROOT/.installed"
    # shellcheck disable=SC2206
    local hosts=( ${WP_SERVER_NAME} )
    echo "${hosts[0]}" | sudo tee "$ROOT/.installed/70-https.primary" >/dev/null
    if [ -n "${WP_DNS_PROVIDER:-}" ]; then
        echo "${WP_DNS_PROVIDER}" | sudo tee "$ROOT/.installed/70-https.dns" >/dev/null
    else
        rm -f "$ROOT/.installed/70-https.dns"
    fi
    [ "${WP_HTTPS_WILDCARD:-0}" = "1" ] && touch "$ROOT/.installed/70-https.wildcard" || rm -f "$ROOT/.installed/70-https.wildcard"
    touch "$ROOT/.installed/70-https.ok"

    log_ok "[70][https] === HTTPS stage complete (cert lineage: ${hosts[0]}, challenge: ${WP_DNS_PROVIDER:-http-01}${WP_HTTPS_WILDCARD:+, wildcard}) ==="
    log_info "[70][https] site: https://${hosts[0]}/"
    log_info "[70][https] renewal: 'sudo certbot renew --dry-run' to test (timer fires twice daily)"
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
        log_warn "[70][https] no primary host known -- skipping certbot delete (run 'certbot certificates' to inspect)"
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
    rm -f "$ROOT/.installed/70-https.ok" \
          "$ROOT/.installed/70-https.primary" \
          "$ROOT/.installed/70-https.dns" \
          "$ROOT/.installed/70-https.wildcard"
    return 0
}
