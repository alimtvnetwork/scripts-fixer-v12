#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/http-verify.sh
# Curls the configured WordPress URL and confirms WordPress is actually
# being served (not the default web-server welcome page or a PHP-FPM error).
set -u

# Returns 0 when the page looks like WordPress, 1 otherwise.
# Detection: HTTP 2xx/3xx + body contains a WordPress fingerprint.
component_http_verify() {
    local server_name="${WP_SERVER_NAME:-localhost}"
    local port="${WP_SITE_PORT:-80}"
    local url="http://${server_name}:${port}/"
    log_info "[70][http-verify] GET $url"

    if ! command -v curl >/dev/null 2>&1; then
        log_err "[70][http-verify] 'curl' not installed -- cannot verify"
        return 1
    fi

    local body_file; body_file="$(mktemp)"
    local code
    code="$(curl -sSL -o "$body_file" -w '%{http_code}' \
              --connect-timeout 5 --max-time 15 --max-redirs 5 \
              -H 'Host: '"${server_name}" \
              "$url" 2>/dev/null || echo "000")"
    # curl may emit several concatenated http_code values on retry/redirect
    # ('000000...'); keep only the final 3-digit chunk for clean logs.
    code="${code: -3}"

    case "$code" in
        2*|3*) : ;;
        000)
            log_err "[70][http-verify] connection failed for $url (curl returned 000 -- service down? wrong port? firewall blocking?)"
            rm -f "$body_file"; return 1 ;;
        502)
            log_err "[70][http-verify] HTTP 502 from $url -- web server reached but PHP-FPM upstream failed; check 'systemctl status php*-fpm'"
            rm -f "$body_file"; return 1 ;;
        503)
            log_err "[70][http-verify] HTTP 503 from $url -- PHP-FPM socket unreachable from web server"
            rm -f "$body_file"; return 1 ;;
        *)
            log_err "[70][http-verify] HTTP $code from $url (expected 2xx/3xx)"
            rm -f "$body_file"; return 1 ;;
    esac

    # WordPress fingerprints (any one of these proves WP is rendering):
    #   - <meta name="generator" content="WordPress ...">
    #   - wp-content / wp-includes asset URLs
    #   - The setup wizard ("WordPress &rsaquo; Setup Configuration File")
    #   - The 5-minute install ("WordPress &rsaquo; Installation")
    if grep -qiE 'wp-(content|includes|admin)|name="generator" content="WordPress|WordPress.{0,40}(Setup|Installation)' "$body_file"; then
        local title
        title="$(grep -oiE '<title[^>]*>[^<]+</title>' "$body_file" | head -1 | sed 's/<[^>]*>//g')"
        log_ok "[70][http-verify] WordPress detected at $url (HTTP $code, title='${title:-?}')"
        rm -f "$body_file"; return 0
    fi

    log_err "[70][http-verify] HTTP $code OK but page does not look like WordPress (no wp-content/wp-includes/generator markers)."
    log_err "[70][http-verify]   first 200 chars of body:"
    head -c 200 "$body_file" >&2; echo "" >&2
    rm -f "$body_file"
    return 1
}
