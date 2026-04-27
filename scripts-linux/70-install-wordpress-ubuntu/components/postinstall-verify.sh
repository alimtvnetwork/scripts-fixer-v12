#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/postinstall-verify.sh
# Three-part post-install verification for the WordPress stack:
#   1. Web vhost is enabled, syntactically valid, and the service is active
#      (nginx OR apache, picked from WP_HTTP_SERVER).
#   2. PHP-FPM socket exists and is reachable (cgi-fcgi if available, else
#      the unix-socket connect test via /dev/tcp-style bash + nc fallback).
#   3. Root URL responds. Strict gate: HTTP 200 (or 301/302 redirect to a
#      final 200, e.g. when --https rewrote :80 to :443). Reuses the
#      existing WordPress fingerprint check from http-verify.sh.
#
# Designed to be called LAST in _install_all -- failure here means the
# install completed but the site won't load, which the operator must know
# before opening the wizard. Returns rc=0 only when ALL three pass.
set -u

# --- Check 1: vhost active --------------------------------------------------
_pv_check_vhost() {
    local server="${WP_HTTP_SERVER:-nginx}"
    case "$server" in
        apache|apache2|httpd)
            if ! command -v apache2 >/dev/null 2>&1; then
                log_err "[70][postinstall] apache2 binary missing -- vhost cannot be active"
                return 1
            fi
            if ! sudo systemctl is-active --quiet apache2; then
                log_err "[70][postinstall] apache2 service is NOT active (systemctl is-active failed) -- run 'systemctl status apache2' for the reason"
                return 1
            fi
            local vhost="/etc/apache2/sites-available/wordpress.conf"
            if [ ! -f "$vhost" ]; then
                log_file_error "$vhost" "WordPress apache vhost missing -- 'install http' did not complete"
                return 1
            fi
            # Enabled? Apache uses sites-enabled symlinks just like nginx.
            if [ ! -L "/etc/apache2/sites-enabled/wordpress.conf" ] && \
               [ ! -e "/etc/apache2/sites-enabled/wordpress.conf" ]; then
                log_err "[70][postinstall] WordPress apache vhost is NOT enabled (no symlink in sites-enabled). Run: sudo a2ensite wordpress.conf && sudo systemctl reload apache2"
                return 1
            fi
            if ! sudo apache2ctl configtest >/tmp/postinstall-apache-t.log 2>&1; then
                log_err "[70][postinstall] apache2ctl configtest FAILED -- see /tmp/postinstall-apache-t.log:"
                sudo cat /tmp/postinstall-apache-t.log >&2
                return 1
            fi
            log_ok "[70][postinstall] apache2 vhost active + configtest OK"
            return 0
            ;;
        *)
            if ! command -v nginx >/dev/null 2>&1; then
                log_err "[70][postinstall] nginx binary missing -- vhost cannot be active"
                return 1
            fi
            if ! sudo systemctl is-active --quiet nginx; then
                log_err "[70][postinstall] nginx service is NOT active (systemctl is-active failed) -- run 'journalctl -u nginx' for the reason"
                return 1
            fi
            local vhost="/etc/nginx/sites-available/wordpress.conf"
            if [ ! -f "$vhost" ]; then
                log_file_error "$vhost" "WordPress nginx vhost missing -- 'install http' did not complete"
                return 1
            fi
            if [ ! -L "/etc/nginx/sites-enabled/wordpress.conf" ] && \
               [ ! -e "/etc/nginx/sites-enabled/wordpress.conf" ]; then
                log_err "[70][postinstall] WordPress nginx vhost is NOT enabled (no symlink in sites-enabled). Run: sudo ln -sf $vhost /etc/nginx/sites-enabled/wordpress.conf && sudo systemctl reload nginx"
                return 1
            fi
            if ! sudo nginx -t >/tmp/postinstall-nginx-t.log 2>&1; then
                log_err "[70][postinstall] 'nginx -t' FAILED -- see /tmp/postinstall-nginx-t.log:"
                sudo cat /tmp/postinstall-nginx-t.log >&2
                return 1
            fi
            log_ok "[70][postinstall] nginx vhost active + 'nginx -t' OK"
            return 0
            ;;
    esac
}

# --- Check 2: PHP-FPM socket reachable -------------------------------------
_pv_resolve_fpm_socket() {
    # Same logic as nginx.sh::_nginx_fpm_socket but inlined so this component
    # works even if nginx.sh isn't sourced (e.g. apache-only setups).
    local svc="${WP_PHP_FPM_SERVICE:-}"
    if [ -n "$svc" ]; then
        local v="${svc#php}"; v="${v%-fpm}"
        if [ -S "/run/php/php${v}-fpm.sock" ]; then
            echo "/run/php/php${v}-fpm.sock"; return
        fi
    fi
    local sock; sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1)"
    echo "${sock:-/run/php/php-fpm.sock}"
}

_pv_check_fpm() {
    local sock; sock="$(_pv_resolve_fpm_socket)"
    if [ ! -S "$sock" ]; then
        log_file_error "$sock" "PHP-FPM unix socket missing (-S test failed) -- run 'systemctl status php*-fpm' to see why FPM did not create it"
        return 1
    fi

    # Find the FPM service that owns the socket so we can check its state.
    local fpm_svc=""
    for s in $(systemctl list-units --type=service --no-legend 2>/dev/null \
                | awk '{print $1}' | grep -E '^php.*-fpm\.service$'); do
        if sudo systemctl is-active --quiet "$s"; then
            fpm_svc="$s"; break
        fi
    done
    if [ -z "$fpm_svc" ]; then
        log_err "[70][postinstall] no active php*-fpm service found (socket exists at $sock but the service is not running)"
        return 1
    fi

    # Reachability test -- prefer cgi-fcgi (real FastCGI handshake), fall
    # back to a passive socket-connectable check if the binary is absent.
    if command -v cgi-fcgi >/dev/null 2>&1; then
        if ! SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET \
                cgi-fcgi -bind -connect "$sock" >/tmp/postinstall-fpm.log 2>&1; then
            log_err "[70][postinstall] cgi-fcgi handshake to $sock FAILED -- see /tmp/postinstall-fpm.log. Common cause: socket owner mismatch (sock owned by www-data but web server runs as different user)"
            sudo head -c 500 /tmp/postinstall-fpm.log >&2; echo "" >&2
            return 1
        fi
    else
        # Passive check: can our shell connect()? Bash can't open AF_UNIX
        # directly, so use python3 which is preinstalled on Ubuntu Server.
        if command -v python3 >/dev/null 2>&1; then
            if ! sudo python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect('$sock')
    s.close()
except Exception as e:
    print('connect failed:', e); sys.exit(1)
" >/tmp/postinstall-fpm.log 2>&1; then
                log_err "[70][postinstall] socket connect to $sock FAILED -- see /tmp/postinstall-fpm.log:"
                sudo cat /tmp/postinstall-fpm.log >&2
                return 1
            fi
        else
            log_warn "[70][postinstall] cgi-fcgi + python3 both missing -- cannot actively probe FPM socket. Existence check passed (-S OK on $sock); trusting service-active state."
        fi
    fi
    log_ok "[70][postinstall] PHP-FPM socket reachable: $sock (service: $fpm_svc)"
    return 0
}

# --- Check 3: root URL returns 200 -----------------------------------------
_pv_check_root_200() {
    local server_name="${WP_SERVER_NAME:-localhost}"
    # Pick the first space-separated host token as the request Host header
    # (server_name may legitimately be a multi-host list).
    # shellcheck disable=SC2206
    local hosts=( $server_name )
    local host="${hosts[0]:-localhost}"

    # Use HTTPS if the operator opted in AND a cert is on disk; otherwise
    # check HTTP. We do NOT auto-follow http->https here because we want to
    # observe the FINAL status code -- curl -L gives us that already.
    local scheme="http" port="${WP_SITE_PORT:-80}"
    if [ "${WP_HTTPS:-0}" = "1" ] || [ -f "$ROOT/.installed/70-https.ok" ]; then
        if [ -f "/etc/letsencrypt/live/${host}/fullchain.pem" ]; then
            scheme="https"; port="443"
        fi
    fi
    local url="${scheme}://${host}:${port}/"
    log_info "[70][postinstall] GET $url (following redirects, expecting final HTTP 200)"

    if ! command -v curl >/dev/null 2>&1; then
        log_err "[70][postinstall] curl not installed -- cannot verify root URL"
        return 1
    fi

    local body; body="$(mktemp)"
    local code
    # -L follows redirects, -k accepts self-signed (handles --https-staging),
    # -w prints final status. Multiple status codes can be concatenated when
    # redirects happen; keep only the last 3 chars (the FINAL response).
    code="$(curl -sSLk -o "$body" -w '%{http_code}' \
              --connect-timeout 5 --max-time 20 --max-redirs 5 \
              "$url" 2>/dev/null || echo "000")"
    code="${code: -3}"

    if [ "$code" != "200" ]; then
        case "$code" in
            000) log_err "[70][postinstall] connection to $url FAILED (curl rc=000 -- service down, wrong port, or firewall blocking)" ;;
            301|302|307|308)
                log_err "[70][postinstall] $url returned final HTTP $code (redirect not followed to a 200 -- target may be down or in a redirect loop)" ;;
            502) log_err "[70][postinstall] $url returned HTTP 502 -- web server reached but PHP-FPM upstream failed" ;;
            503) log_err "[70][postinstall] $url returned HTTP 503 -- PHP-FPM socket unreachable from web server" ;;
            404) log_err "[70][postinstall] $url returned HTTP 404 -- vhost matched a different document root, or DirectoryIndex missing" ;;
            *)   log_err "[70][postinstall] $url returned HTTP $code (expected 200)" ;;
        esac
        log_err "[70][postinstall]   first 200 chars of body:"
        head -c 200 "$body" >&2; echo "" >&2
        rm -f "$body"
        return 1
    fi

    # 200 received -- now confirm it's actually WordPress (not the default
    # nginx welcome page or an Apache "It works!"). Reuse existing fingerprint.
    if declare -f component_http_verify >/dev/null 2>&1; then
        if ! component_http_verify >/dev/null 2>&1; then
            log_err "[70][postinstall] $url returned HTTP 200 but body does not look like WordPress (default web-server welcome page?)"
            return 1
        fi
    else
        # Inline minimal fingerprint check if http-verify.sh wasn't sourced.
        if ! grep -qiE 'wp-(content|includes|admin)|name="generator" content="WordPress|WordPress.{0,40}(Setup|Installation)' "$body"; then
            log_err "[70][postinstall] $url returned HTTP 200 but body lacks WordPress markers"
            rm -f "$body"; return 1
        fi
    fi
    log_ok "[70][postinstall] root URL responded with HTTP 200 + WordPress fingerprint: $url"
    rm -f "$body"
    return 0
}

# --- public API -------------------------------------------------------------
component_postinstall_verify() {
    log_info "[70][postinstall] === post-install verification start ==="
    log_info "[70][postinstall] checks: (1) web vhost active (2) PHP-FPM socket reachable (3) root URL HTTP 200"
    local rc=0 fail=""
    _pv_check_vhost     || { rc=1; fail="${fail} vhost"; }
    _pv_check_fpm       || { rc=1; fail="${fail} php-fpm-socket"; }
    _pv_check_root_200  || { rc=1; fail="${fail} root-url-200"; }
    if [ $rc -eq 0 ]; then
        log_ok "[70][postinstall] === all 3 post-install checks passed ==="
    else
        log_err "[70][postinstall] === post-install verification FAILED (failed:${fail}) ==="
        log_err "[70][postinstall] WordPress files are installed but the site is not serving correctly. Fix the failing check(s) above before opening the wizard."
    fi
    return $rc
}
