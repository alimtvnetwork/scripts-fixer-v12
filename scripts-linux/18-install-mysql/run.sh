#!/usr/bin/env bash
# scripts-linux/18-install-mysql/run.sh
# MySQL Server installer (Debian/Ubuntu).
#
# Verbs:    install (default) | check | repair | uninstall
# Flags:    --interactive | -i    Prompt for MySQL port + data directory
#                                 before install.
#           --port <n>            MySQL listening port  (default: 3306)
#           --datadir <path>      MySQL data directory  (default: /var/lib/mysql)
#           -h | --help           Show help and exit
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="18"

. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/interactive.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 18-install-mysql"; exit 1; }

APT_PKG="mysql-server"
VERIFY_CMD='mysql --version'
INSTALLED_MARK="$ROOT/.installed/18.ok"

# ---- arg parsing -----------------------------------------------------------
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"
INTERACTIVE=0
VERB=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<HELP
scripts-linux/run.sh 18 [verb] [flags]
  Verbs:  install | check | repair | uninstall   (default: install)
  Flags:
    --interactive, -i      Prompt for port + data directory before install
    --port <n>             MySQL listening port (default: 3306)
    --datadir <path>       MySQL data directory (default: /var/lib/mysql)
    -h, --help             Show this help
HELP
            exit 0 ;;
        -i|--interactive)  INTERACTIVE=1; shift ;;
        --port)            MYSQL_PORT="${2:-}"; shift 2 ;;
        --port=*)          MYSQL_PORT="${1#--port=}"; shift ;;
        --datadir)         MYSQL_DATADIR="${2:-}"; shift 2 ;;
        --datadir=*)       MYSQL_DATADIR="${1#--datadir=}"; shift ;;
        install|check|repair|uninstall) VERB="$1"; shift ;;
        *) log_err "[18] Unknown arg: $1"; exit 2 ;;
    esac
done
VERB="${VERB:-install}"

# ---- interactive prompt (only for install/repair) --------------------------
if [ "$INTERACTIVE" = "1" ] && { [ "$VERB" = "install" ] || [ "$VERB" = "repair" ]; }; then
    log_info "[18] --interactive: collecting MySQL port + data dir"
    MYSQL_PORT="$(prompt_with_default 'MySQL port'             "$MYSQL_PORT"    validate_port)"
    MYSQL_DATADIR="$(prompt_with_default 'MySQL data directory' "$MYSQL_DATADIR" validate_path_writable)"
    log_info "[18] -> port='$MYSQL_PORT' datadir='$MYSQL_DATADIR'"
fi

# Validate even when not interactive.
if ! validate_port "$MYSQL_PORT"; then
    log_err "[18] Invalid port '$MYSQL_PORT' (expected 1..65535)"; exit 2
fi
if ! validate_path_writable "$MYSQL_DATADIR"; then
    log_err "[18] Invalid data dir '$MYSQL_DATADIR' (must exist or have an existing parent)"; exit 2
fi

# Export for any helper that wants to honour custom port/datadir.
# The base APT install ignores these (defaults to 3306 + /var/lib/mysql);
# they are wired through the shared override file `/etc/mysql/conf.d/99-script18.cnf`
# only when they differ from defaults, to avoid touching a vanilla install.
write_overrides_if_needed() {
    local needs=0
    if [ "$MYSQL_PORT" != "3306" ];          then needs=1; fi
    if [ "$MYSQL_DATADIR" != "/var/lib/mysql" ]; then needs=1; fi
    [ "$needs" = "0" ] && return 0
    local override="/etc/mysql/conf.d/99-script18.cnf"
    log_info "[18] Writing overrides to $override (port=$MYSQL_PORT, datadir=$MYSQL_DATADIR)"
    sudo install -d -m 0755 /etc/mysql/conf.d 2>/dev/null || true
    if ! sudo bash -c "cat > '$override'" <<EOF
# Written by scripts-linux/18-install-mysql/run.sh
[mysqld]
port     = $MYSQL_PORT
datadir  = $MYSQL_DATADIR
EOF
    then
        log_file_error "$override" "failed to write MySQL override file (sudo write failed)"
        return 1
    fi
    log_ok "[18] Override written: $override"
    sudo systemctl restart mysql 2>/dev/null || true
}

verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }

verb_install() {
    log_info "[18] Starting MySQL Server installer (port=$MYSQL_PORT, datadir=$MYSQL_DATADIR)"
    if verify_installed; then
        log_ok "[18] Already installed"
        mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
        write_overrides_if_needed
        return 0
    fi
    if ! is_debian_family || ! is_apt_available; then
        log_err "[18] apt not available"; return 1
    fi
    log_info "[18] Installing via apt: $APT_PKG"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if sudo apt-get install -y $APT_PKG; then
        log_ok "[18] Installed"
        mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
        write_overrides_if_needed
        return 0
    fi
    log_err "[18] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[18] Verify OK"; return 0; fi; log_warn "[18] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y $APT_PKG; rm -f "$INSTALLED_MARK"; log_ok "[18] Removed"; }

case "$VERB" in
    install)   verb_install ;;
    check)     verb_check ;;
    repair)    verb_repair ;;
    uninstall) verb_uninstall ;;
    *)         log_err "[18] Unknown verb: $VERB"; exit 2 ;;
esac
