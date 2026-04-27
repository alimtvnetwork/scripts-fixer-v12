#!/usr/bin/env bash
# scripts-linux/_shared/dns-install.sh
# Shared engine for the 100-108 DNS installer family.
#
# Every per-server script sets a few variables and calls `dns_run "$@"`.
# Capabilities:
#   * apt install (single or multiple packages from config.json)
#   * Optional snap fallback (CoreDNS, Knot Resolver in some distros)
#   * Optional binary download (CoreDNS .tar.gz)
#   * Verify command (server --version) + writes .installed/<id>.ok marker
#   * Interactive mode: prompts for listen port, listen address, forwarders
#     (when relevant) and writes a minimal config drop-in based on config.json
#   * `--no-config` to install only, leaving distro defaults intact
#
# CODE RED: every file/path error logs exact path + reason via log_file_error.
#
# Caller variables:
#   DNS_ID            e.g. "100"
#   DNS_NAME          e.g. "BIND9"
#   DNS_CONFIG_JSON   absolute path to per-script config.json
#                     Fields read:
#                       install.apt        (string|array)
#                       install.snap       (string)        -- optional
#                       install.binary     ({url, dest})   -- optional
#                       verify             (string)        -- shell test cmd
#                       systemdUnit        (string)        -- restart target
#                       configDropPath     (string)        -- where to write
#                                                            interactive override
#                       configTemplate     (string)        -- printf-style template
#                                                            with {PORT} {LISTEN}
#                                                            {FORWARDERS} placeholders
#                       defaults           ({port, listen, forwarders[]})
#   DNS_INSTALLED_MARK absolute path to .installed/<id>.ok

_dns_jq() { command -v jq >/dev/null 2>&1; }

_dns_get() {
    _dns_jq || { echo ""; return; }
    jq -r "$1 // empty" "$DNS_CONFIG_JSON" 2>/dev/null
}

_dns_get_array() {
    _dns_jq || { echo ""; return; }
    jq -r "$1 // [] | if type==\"array\" then .[] else . end" "$DNS_CONFIG_JSON" 2>/dev/null
}

_dns_help() {
    cat <<EOF
scripts-linux/$DNS_ID-install-dns-* — install $DNS_NAME from a known-good default config.

Verbs:    install (default) | check | repair | uninstall
Flags:
    --interactive, -i    Prompt for listen port / address / forwarders
                         and write a minimal drop-in override
    --no-config          Skip the config-write step (install only)
    --port <n>           Pre-set the listen port (default from config.json)
    --listen <addr>      Pre-set the listen address (default from config.json)
    --forwarders a,b,c   Comma-separated upstream forwarders (recursive servers only)
    -h, --help           Show this help

Defaults are stored in: $DNS_CONFIG_JSON
Backup of every overwritten config: <path>.bak.<timestamp>
EOF
}

_dns_verify() {
    local v; v=$(_dns_get '.verify')
    [ -z "$v" ] && return 0
    bash -c "$v" >/dev/null 2>&1
}

_dns_install_apt() {
    local pkgs
    pkgs=$(_dns_get_array '.install.apt' | tr '\n' ' ')
    [ -z "$pkgs" ] && return 1
    if ! is_debian_family || ! is_apt_available; then
        log_warn "[$DNS_ID] apt not available -- skipping apt install"
        return 1
    fi
    log_info "[$DNS_ID] apt-get install: $pkgs"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if sudo apt-get install -y $pkgs; then
        log_ok "[$DNS_ID] apt install OK"
        return 0
    fi
    log_err "[$DNS_ID] apt install FAILED for: $pkgs"
    return 1
}

_dns_install_snap() {
    local snap; snap=$(_dns_get '.install.snap')
    [ -z "$snap" ] && return 1
    is_snap_available || { log_warn "[$DNS_ID] snap not available"; return 1; }
    log_info "[$DNS_ID] snap install: $snap"
    if sudo snap install "$snap" 2>/dev/null; then
        log_ok "[$DNS_ID] snap install OK"; return 0
    fi
    log_err "[$DNS_ID] snap install FAILED for: $snap"; return 1
}

_dns_install_binary() {
    local url dest
    url=$(_dns_get  '.install.binary.url')
    dest=$(_dns_get '.install.binary.dest')
    [ -z "$url" ] || [ -z "$dest" ] && return 1
    has_curl || { log_warn "[$DNS_ID] curl missing -- cannot fetch binary"; return 1; }
    log_info "[$DNS_ID] downloading: $url -> $dest"
    local tmp; tmp=$(mktemp)
    if ! curl -fsSL -o "$tmp" "$url"; then
        log_file_error "$url" "binary download failed (curl exit non-zero)"
        rm -f "$tmp"; return 1
    fi
    sudo install -m 0755 "$tmp" "$dest" 2>/dev/null \
        || { log_file_error "$dest" "install of binary failed"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    log_ok "[$DNS_ID] installed binary: $dest"
}

_dns_write_config() {
    local port="$1" listen="$2" forwarders="$3"
    local drop tmpl
    drop=$(_dns_get '.configDropPath')
    tmpl=$(_dns_get '.configTemplate')
    if [ -z "$drop" ] || [ -z "$tmpl" ]; then
        log_info "[$DNS_ID] no configDropPath/configTemplate in config.json -- leaving defaults intact"
        return 0
    fi
    if [ -f "$drop" ]; then
        local bak="$drop.bak.$(date +%Y%m%d-%H%M%S)"
        if ! sudo cp -p "$drop" "$bak" 2>/dev/null; then
            log_file_error "$bak" "backup of existing drop-in failed"
            return 1
        fi
        log_ok "[$DNS_ID] backup -> $bak"
    fi
    sudo install -d -m 0755 "$(dirname "$drop")" 2>/dev/null || true
    local rendered="${tmpl//\{PORT\}/$port}"
    rendered="${rendered//\{LISTEN\}/$listen}"
    rendered="${rendered//\{FORWARDERS\}/$forwarders}"
    if ! printf '%s\n' "$rendered" | sudo tee "$drop" >/dev/null; then
        log_file_error "$drop" "failed to write DNS config drop-in"
        return 1
    fi
    log_ok "[$DNS_ID] wrote config: $drop"
    local unit; unit=$(_dns_get '.systemdUnit')
    if [ -n "$unit" ]; then
        sudo systemctl restart "$unit" 2>/dev/null \
            && log_ok "[$DNS_ID] restarted $unit" \
            || log_warn "[$DNS_ID] $unit restart failed (check journalctl -u $unit)"
    fi
}

dns_verb_install() {
    local interactive="$1" no_config="$2" cli_port="$3" cli_listen="$4" cli_fwd="$5"
    log_info "[$DNS_ID] starting $DNS_NAME installer"
    if _dns_verify; then
        log_ok "[$DNS_ID] $DNS_NAME already installed"
    else
        _dns_install_apt || _dns_install_snap || _dns_install_binary || {
            log_err "[$DNS_ID] all install methods failed"; return 1; }
    fi
    mkdir -p "$(dirname "$DNS_INSTALLED_MARK")"; touch "$DNS_INSTALLED_MARK"

    [ "$no_config" = "1" ] && { log_info "[$DNS_ID] --no-config: skipping config write"; return 0; }

    local def_port def_listen def_fwd
    def_port=$(_dns_get   '.defaults.port')
    def_listen=$(_dns_get '.defaults.listen')
    def_fwd=$(_dns_get_array '.defaults.forwarders' | paste -sd, -)
    [ -n "$cli_port" ]   && def_port="$cli_port"
    [ -n "$cli_listen" ] && def_listen="$cli_listen"
    [ -n "$cli_fwd" ]    && def_fwd="$cli_fwd"

    if [ "$interactive" = "1" ]; then
        local _root; _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        . "$_root/_shared/interactive.sh"
        def_port=$(prompt_with_default   "$DNS_NAME listen port"     "${def_port:-53}" validate_port)
        def_listen=$(prompt_with_default "$DNS_NAME listen address"  "${def_listen:-0.0.0.0}")
        # Forwarders are only meaningful for recursive resolvers, but the
        # template silently ignores {FORWARDERS} when not used.
        def_fwd=$(prompt_with_default    "Upstream forwarders (csv)" "${def_fwd:-1.1.1.1,9.9.9.9}")
    fi

    _dns_write_config "${def_port:-53}" "${def_listen:-0.0.0.0}" "${def_fwd:-}"
}

dns_verb_check() {
    if _dns_verify; then log_ok "[$DNS_ID] verify OK"; return 0; fi
    log_warn "[$DNS_ID] verify FAILED"; return 1
}

dns_verb_repair() {
    rm -f "$DNS_INSTALLED_MARK"
    dns_verb_install "$@"
}

dns_verb_uninstall() {
    local pkgs
    pkgs=$(_dns_get_array '.install.apt' | tr '\n' ' ')
    if [ -n "$pkgs" ] && is_apt_available; then
        sudo apt-get remove -y $pkgs >/dev/null 2>&1 || true
        log_ok "[$DNS_ID] removed apt packages: $pkgs"
    fi
    local snap; snap=$(_dns_get '.install.snap')
    [ -n "$snap" ] && is_snap_available && sudo snap remove "$snap" >/dev/null 2>&1 || true
    rm -f "$DNS_INSTALLED_MARK"
    log_ok "[$DNS_ID] uninstall complete"
}

# Public entry point. Caller invokes:  dns_run "$@"
dns_run() {
    [ -f "$DNS_CONFIG_JSON" ] || {
        log_file_error "$DNS_CONFIG_JSON" "config.json missing for $DNS_ID-install-dns-*"
        return 1; }
    local VERB="" INTERACTIVE=0 NO_CONFIG=0 CLI_PORT="" CLI_LISTEN="" CLI_FWD=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)             _dns_help; return 0 ;;
            -i|--interactive)      INTERACTIVE=1; shift ;;
            --no-config)           NO_CONFIG=1; shift ;;
            --port)                CLI_PORT="$2"; shift 2 ;;
            --port=*)              CLI_PORT="${1#--port=}"; shift ;;
            --listen)              CLI_LISTEN="$2"; shift 2 ;;
            --listen=*)            CLI_LISTEN="${1#--listen=}"; shift ;;
            --forwarders)          CLI_FWD="$2"; shift 2 ;;
            --forwarders=*)        CLI_FWD="${1#--forwarders=}"; shift ;;
            install|check|repair|uninstall) VERB="$1"; shift ;;
            *) log_warn "[$DNS_ID] ignoring unknown arg: $1"; shift ;;
        esac
    done
    VERB="${VERB:-install}"
    case "$VERB" in
        install)   dns_verb_install   "$INTERACTIVE" "$NO_CONFIG" "$CLI_PORT" "$CLI_LISTEN" "$CLI_FWD" ;;
        check)     dns_verb_check ;;
        repair)    dns_verb_repair    "$INTERACTIVE" "$NO_CONFIG" "$CLI_PORT" "$CLI_LISTEN" "$CLI_FWD" ;;
        uninstall) dns_verb_uninstall ;;
        *)         log_err "[$DNS_ID] unknown verb: $VERB"; return 2 ;;
    esac
}