#!/usr/bin/env bash
# change-port.sh -- root-level entry point for the change-port toolkit.
# Forwards to scripts-linux/91-change-port-menu/run.sh, which dispatches
# to the per-service script under scripts-linux/<NN>-change-port-*/.
#
# Examples:
#   ./change-port.sh                       # interactive menu
#   ./change-port.sh ssh --port 2222       # change SSH to 2222 (with prompt)
#   ./change-port.sh ssh --port 2222 --yes # non-interactive
#   ./change-port.sh mysql --interactive   # prompt for MySQL port
#   ./change-port.sh --list                # list supported services
#
# Service aliases supported (lowercase friendly names):
#   ssh mysql postgres postgresql pg ftp vsftpd redis mongo mongodb
#   nginx apache httpd docker rabbitmq rabbit smtp postfix
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$ROOT/scripts-linux"
MENU="$SCRIPT_DIR/91-change-port-menu/run.sh"

if [ ! -x "$MENU" ]; then
    echo "FILE-ERROR path='$MENU' reason='change-port menu missing or not executable'" >&2
    exit 1
fi

# Translate friendly name -> numeric id, then defer to the menu.
alias_to_id() {
    case "$1" in
        80|ssh|sshd) echo 80 ;;
        81|mysql)    echo 81 ;;
        82|postgres|postgresql|pg) echo 82 ;;
        83|ftp|vsftpd) echo 83 ;;
        84|redis) echo 84 ;;
        85|mongo|mongodb) echo 85 ;;
        86|nginx) echo 86 ;;
        87|apache|httpd|apache2) echo 87 ;;
        88|docker) echo 88 ;;
        89|rabbitmq|rabbit) echo 89 ;;
        90|smtp|postfix) echo 90 ;;
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
            echo "change-port.sh: unknown service '$1'. Use --list to see supported names." >&2
            exec bash "$MENU" --list
        fi
        shift
        exec bash "$MENU" "$id" "$@"
        ;;
esac
