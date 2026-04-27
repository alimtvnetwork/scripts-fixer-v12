#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/firewall.sh
# Optional UFW (Uncomplicated Firewall) rules for the chosen WordPress port.
# Only runs when WP_FIREWALL=1 (set via --firewall on the orchestrator).
# Idempotent: re-running with the same port is a no-op; changing the port
# removes the previously-opened port first.
set -u

_fw_state_file() { echo "$ROOT/.installed/70-firewall.port"; }

component_firewall_verify() {
    [ "${WP_FIREWALL:-0}" = "1" ] || return 0   # not requested -> trivially OK
    command -v ufw >/dev/null 2>&1 || return 1
    local port="${WP_SITE_PORT:-80}"
    sudo ufw status 2>/dev/null | grep -qE "^${port}/tcp[[:space:]]+ALLOW" || return 1
    return 0
}

component_firewall_install() {
    if [ "${WP_FIREWALL:-0}" != "1" ]; then
        log_info "[70][firewall] skipped (--firewall not set; pass --firewall to open WP_SITE_PORT in UFW)"
        return 0
    fi

    local port="${WP_SITE_PORT:-80}"
    log_info "[70][firewall] requested -- opening port ${port}/tcp via UFW"

    if ! command -v ufw >/dev/null 2>&1; then
        log_info "[70][firewall] 'ufw' not present -- installing"
        sudo apt-get update -y >/dev/null 2>&1 || true
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw; then
            log_err "[70][firewall] apt-get install ufw failed"
            return 1
        fi
    fi

    # If a previous run opened a different port, close it first.
    local state; state="$(_fw_state_file)"
    if [ -f "$state" ]; then
        local prev; prev="$(cat "$state" 2>/dev/null || echo '')"
        if [ -n "$prev" ] && [ "$prev" != "$port" ]; then
            log_info "[70][firewall] previously opened ${prev}/tcp -- removing before opening ${port}/tcp"
            sudo ufw delete allow "${prev}/tcp" >/dev/null 2>&1 || true
        fi
    fi

    # Don't enable UFW if the operator hasn't enabled it themselves -- that
    # would silently lock SSH out of fresh hosts. We just add the rule; the
    # operator is responsible for `ufw enable`.
    local active; active="$(sudo ufw status 2>/dev/null | head -1 || echo '')"
    if ! echo "$active" | grep -qi 'active'; then
        log_warn "[70][firewall] UFW is INACTIVE on this host. The 'allow ${port}/tcp' rule will be added but takes no effect until you run: sudo ufw enable"
    fi

    if ! sudo ufw allow "${port}/tcp" >/dev/null 2>&1; then
        log_err "[70][firewall] 'ufw allow ${port}/tcp' failed"
        return 1
    fi

    mkdir -p "$ROOT/.installed"
    if ! echo "$port" | sudo tee "$state" >/dev/null; then
        log_file_error "$state" "tee failed while saving firewall port state"
        return 1
    fi
    log_ok "[70][firewall] opened ${port}/tcp (state file: $state)"
    return 0
}

component_firewall_uninstall() {
    [ -f "$(_fw_state_file)" ] || return 0
    local prev; prev="$(cat "$(_fw_state_file)" 2>/dev/null || echo '')"
    if [ -n "$prev" ] && command -v ufw >/dev/null 2>&1; then
        sudo ufw delete allow "${prev}/tcp" >/dev/null 2>&1 || true
        log_ok "[70][firewall] closed ${prev}/tcp"
    fi
    rm -f "$(_fw_state_file)"
}
