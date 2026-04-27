#!/usr/bin/env bash
# scripts-linux/90-change-port-smtp/run.sh
# READ-ONLY SMTP port inspector. Changing port 25 breaks mail delivery
# (every other MTA on the internet hard-codes 25 for inbound SMTP), so
# this script DELIBERATELY refuses to modify Postfix configuration and
# instead reports the current state with a clear warning.
#
# To run a Postfix submission listener on a different port (587/465),
# edit /etc/postfix/master.cf manually -- this script will not do it.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="90"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/file-error.sh"

show_help() {
    cat <<HELP
scripts-linux/90-change-port-smtp/run.sh -- READ-ONLY SMTP port inspector.

    Changing the inbound SMTP port (25) breaks mail delivery from every
    other MTA on the internet. This script REFUSES to modify Postfix
    config and only reports the current listener state.

    Use ports 465 (smtps) or 587 (submission) for client/MUA traffic.
    Edit /etc/postfix/master.cf by hand if you need a non-standard
    submission port.

Verbs:  check (default) | install (alias of check) | repair | uninstall
        All verbs are read-only. --port / --interactive are accepted
        but ignored, with a warning.

Flags:  -h, --help        Show this help
HELP
}

for a in "$@"; do
    case "$a" in
        -h|--help) show_help; exit 0 ;;
        --port|--port=*|-i|--interactive|--yes|--dry-run|--no-restart|--no-firewall)
            log_warn "[90] '$a' ignored -- SMTP port changes are intentionally disabled"
            ;;
    esac
done

log_warn "[90] SMTP port (25) is fixed for inbound mail -- this script is read-only."
log_info "[90] Reporting current Postfix listeners:"
if command -v postconf >/dev/null 2>&1; then
    postconf -n | grep -E '^(inet_interfaces|smtpd_listen|master_service_disable)' || true
    if [ -r /etc/postfix/master.cf ]; then
        log_info "[90] master.cf entries listening on a TCP port:"
        grep -E '^[a-z0-9_-]+[[:space:]]+inet[[:space:]]' /etc/postfix/master.cf | sed 's/^/    /'
    else
        log_file_error "/etc/postfix/master.cf" "missing -- is Postfix installed?"
    fi
else
    log_warn "[90] postconf not found -- Postfix is probably not installed"
fi
log_ok "[90] done (no changes made)."
exit 0
