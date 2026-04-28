#!/usr/bin/env bash
# scripts-linux/91-change-port-menu/run.sh
# Interactive menu for the 80-90 change-port family.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="91"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

declare -a SERVICES=(
    "80|OpenSSH server          |80-change-port-ssh"
    "81|MySQL server            |81-change-port-mysql"
    "82|PostgreSQL              |82-change-port-postgresql"
    "83|vsftpd FTP              |83-change-port-ftp"
    "84|Redis                   |84-change-port-redis"
    "85|MongoDB                 |85-change-port-mongodb"
    "86|nginx                   |86-change-port-nginx"
    "87|Apache (apache2)        |87-change-port-apache"
    "88|Docker daemon           |88-change-port-docker"
    "89|RabbitMQ                |89-change-port-rabbitmq"
    "90|Postfix SMTP (read-only)|90-change-port-smtp"
)

show_help() {
    cat <<HELP
scripts-linux/91-change-port-menu/run.sh -- interactive change-port menu.

Usage:
    run.sh                 Show interactive menu
    run.sh <id> [args...]  Run one service directly (e.g. 'run.sh 80 --port 2222')
    run.sh --list          List supported services
    run.sh -h, --help      Show this help

Forwards every arg after <id> to the matching scripts-linux/<NN>-change-port-*/run.sh.
HELP
}

list_services() {
    printf '\n  Supported services:\n' >&2
    local row id name folder
    for row in "${SERVICES[@]}"; do
        IFS='|' read -r id name folder <<<"$row"
        printf '    [%s] %-25s -> %s\n' "$id" "$name" "$folder" >&2
    done
    printf '\n' >&2
}

dispatch() {
    local id="$1"; shift
    local row found_folder=""
    for row in "${SERVICES[@]}"; do
        local rid rname rfolder
        IFS='|' read -r rid rname rfolder <<<"$row"
        if [ "$rid" = "$id" ]; then found_folder="$rfolder"; break; fi
    done
    if [ -z "$found_folder" ]; then
        log_err "[91] unknown service id: $id"; list_services; return 2
    fi
    local target="$ROOT/$found_folder/run.sh"
    if [ ! -x "$target" ]; then
        log_file_error "$target" "child script missing or not executable"; return 1
    fi
    write_install_paths \
      --tool   "Change-port menu (dispatch id=$id)" \
      --source "$SCRIPT_DIR/run.sh SERVICES table -> $found_folder" \
      --temp   "(delegated to child script)" \
      --target "$target $*"
    log_info "[91] -> $target $*"
    bash "$target" "$@"
}

case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    --list)    list_services; exit 0 ;;
    "")
        list_services
        printf '  Pick service id [80]: ' >&2
        reply=""
        if [ -r /dev/tty ]; then IFS= read -r reply </dev/tty; else IFS= read -r reply; fi
        [ -z "$reply" ] && reply="80"
        dispatch "$reply" --interactive
        ;;
    *)  dispatch "$@" ;;
esac
