#!/usr/bin/env bash
# install-dns.sh -- root-level entry point for the DNS installer toolkit.
# Forwards to scripts-linux/109-install-dns-menu/run.sh, which dispatches
# to the per-server script under scripts-linux/<NN>-install-dns-*/.
#
# Examples:
#   ./install-dns.sh                         # interactive menu
#   ./install-dns.sh bind9                   # install BIND9 with defaults
#   ./install-dns.sh unbound --interactive   # prompt for port/listen/forwarders
#   ./install-dns.sh coredns --port 5353     # CoreDNS on port 5353
#   ./install-dns.sh dnsmasq check           # verify install
#   ./install-dns.sh --list
#
# DNS server aliases (lowercase friendly names):
#   bind bind9 unbound powerdns powerdns-auth pdns-auth
#   powerdns-recursor pdns-recursor recursor
#   dnsmasq knot knot-resolver kresd coredns nsd
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$ROOT/scripts-linux"
MENU="$SCRIPT_DIR/109-install-dns-menu/run.sh"

if [ ! -x "$MENU" ]; then
    echo "FILE-ERROR path='$MENU' reason='install-dns menu missing or not executable'" >&2
    exit 1
fi

alias_to_id() {
    case "$1" in
        100|bind|bind9|named) echo 100 ;;
        101|unbound) echo 101 ;;
        102|powerdns-auth|pdns-auth|powerdns|pdns) echo 102 ;;
        103|powerdns-recursor|pdns-recursor|recursor) echo 103 ;;
        104|dnsmasq) echo 104 ;;
        105|knot|knot-dns) echo 105 ;;
        106|knot-resolver|kresd) echo 106 ;;
        107|coredns) echo 107 ;;
        108|nsd) echo 108 ;;
        *) echo "" ;;
    esac
}

case "${1:-}" in
    ""|-h|--help|--list)
        exec bash "$MENU" "${1:-}"
        ;;
    *)
        id=$(alias_to_id "$1")
        if [ -z "$id" ]; then
            echo "install-dns.sh: unknown DNS server '$1'. Use --list to see supported names." >&2
            exec bash "$MENU" --list
        fi
        shift
        # If no further verb, default to interactive install.
        if [ $# -eq 0 ]; then
            exec bash "$MENU" "$id" install --interactive
        fi
        exec bash "$MENU" "$id" "$@"
        ;;
esac
