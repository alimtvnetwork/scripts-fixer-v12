#!/usr/bin/env bash
# scripts-linux/109-install-dns-menu/run.sh
# Interactive menu for the 100-108 DNS installer family.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="109"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

write_install_paths \
    --tool   "DNS Install Menu (100-108 dispatcher)" \
    --source "$SCRIPT_DIR/run.sh" \
    --temp   "(none -- pure dispatcher)" \
    --target "scripts-linux/10[0-8]-install-dns-*/run.sh" \
    --action "Configure" || true

declare -a SERVERS=(
    "100|BIND9 (auth + recursive)   |100-install-dns-bind9"
    "101|Unbound (recursive cache)  |101-install-dns-unbound"
    "102|PowerDNS Authoritative     |102-install-dns-powerdns-auth"
    "103|PowerDNS Recursor          |103-install-dns-powerdns-recursor"
    "104|dnsmasq (light + DHCP)     |104-install-dns-dnsmasq"
    "105|Knot DNS (authoritative)   |105-install-dns-knot"
    "106|Knot Resolver              |106-install-dns-knot-resolver"
    "107|CoreDNS (plugin-based)     |107-install-dns-coredns"
    "108|NSD (authoritative-only)   |108-install-dns-nsd"
)

show_help() {
    cat <<HELP
scripts-linux/109-install-dns-menu/run.sh -- interactive DNS-install menu.

Usage:
    run.sh                 Show interactive menu (defaults to install + interactive)
    run.sh <id> [args...]  Run one server directly
                           (e.g. 'run.sh 101 install --port 5353')
    run.sh --list          List supported DNS servers
    run.sh -h, --help      Show this help

Forwards every arg after <id> to scripts-linux/<NN>-install-dns-*/run.sh.
HELP
}

list_servers() {
    printf '\n  Supported DNS servers:\n' >&2
    local row id name folder
    for row in "${SERVERS[@]}"; do
        IFS='|' read -r id name folder <<<"$row"
        printf '    [%s] %-30s -> %s\n' "$id" "$name" "$folder" >&2
    done
    printf '\n' >&2
}

dispatch() {
    local id="$1"; shift
    local row found_folder=""
    for row in "${SERVERS[@]}"; do
        local rid rname rfolder
        IFS='|' read -r rid rname rfolder <<<"$row"
        if [ "$rid" = "$id" ]; then found_folder="$rfolder"; break; fi
    done
    if [ -z "$found_folder" ]; then
        log_err "[109] unknown DNS server id: $id"; list_servers; return 2
    fi
    local target="$ROOT/$found_folder/run.sh"
    if [ ! -x "$target" ]; then
        log_file_error "$target" "child script missing or not executable"; return 1
    fi
    log_info "[109] -> $target $*"
    bash "$target" "$@"
}

case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    --list)    list_servers; exit 0 ;;
    "")
        list_servers
        printf '  Pick DNS id [101]: ' >&2
        reply=""
        if [ -r /dev/tty ]; then IFS= read -r reply </dev/tty; else IFS= read -r reply; fi
        [ -z "$reply" ] && reply="101"
        dispatch "$reply" install --interactive
        ;;
    *)  dispatch "$@" ;;
esac
