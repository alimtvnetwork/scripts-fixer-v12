#!/usr/bin/env bash
# scripts-linux/16-install-php/run.sh
# PHP CLI + FPM installer (Debian/Ubuntu).
#
# Verbs:    install (default) | check | repair | uninstall
# Flags:    --interactive | -i    Prompt for the PHP version before install
#                                 (e.g. "PHP version (latest|8.1|8.2|8.3) [latest]: ")
#           --php <ver>           Pin PHP version: latest | 8.1 | 8.2 | 8.3
#           -h | --help           Show help and exit
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="16"

. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/interactive.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 16-install-php"; exit 1; }

INSTALLED_MARK="$ROOT/.installed/16.ok"
VERIFY_CMD='php --version'

# ---- arg parsing -----------------------------------------------------------
PHP_VERSION="${PHP_VERSION:-latest}"
INTERACTIVE=0
VERB=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<HELP
scripts-linux/run.sh 16 [verb] [flags]
  Verbs:  install | check | repair | uninstall   (default: install)
  Flags:
    --interactive, -i      Prompt for PHP version before install
    --php <ver>            Pin PHP version (latest|8.1|8.2|8.3, default: latest)
    -h, --help             Show this help
HELP
            exit 0 ;;
        -i|--interactive)  INTERACTIVE=1; shift ;;
        --php)             PHP_VERSION="${2:-}"; shift 2 ;;
        --php=*)           PHP_VERSION="${1#--php=}"; shift ;;
        install|check|repair|uninstall) VERB="$1"; shift ;;
        *) log_err "[16] Unknown arg: $1"; exit 2 ;;
    esac
done
VERB="${VERB:-install}"

# ---- interactive prompt (only for install/repair, only if requested) -------
if [ "$INTERACTIVE" = "1" ] && { [ "$VERB" = "install" ] || [ "$VERB" = "repair" ]; }; then
    log_info "[16] --interactive: collecting PHP version"
    PHP_VERSION="$(prompt_with_default 'PHP version (latest|8.1|8.2|8.3)' "$PHP_VERSION" validate_php_version)"
    log_info "[16] -> PHP version='$PHP_VERSION'"
fi

# Validate even when not interactive (catches bad --php values).
if ! validate_php_version "$PHP_VERSION"; then
    log_err "[16] Invalid PHP version '$PHP_VERSION' (expected: latest|8.1|8.2|8.3)"
    exit 2
fi

# ---- resolve apt package set from chosen version ---------------------------
if [ "$PHP_VERSION" = "latest" ]; then
    APT_PKG="php-cli php-fpm"
else
    APT_PKG="php${PHP_VERSION}-cli php${PHP_VERSION}-fpm"
fi

verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }

verb_install() {
    write_install_paths \
      --tool   "PHP CLI + FPM ($PHP_VERSION)" \
      --source "apt (Debian/Ubuntu) | ondrej/php PPA for pinned versions" \
      --temp   "/var/cache/apt/archives" \
      --target "/usr/bin/php + /usr/sbin/php-fpm*"
    log_info "[16] Starting PHP CLI + FPM installer (version=$PHP_VERSION, pkgs=$APT_PKG)"
    if verify_installed; then
        log_ok "[16] Already installed"
        mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
        return 0
    fi
    if ! is_debian_family || ! is_apt_available; then
        log_err "[16] apt not available"; return 1
    fi
    log_info "[16] Installing via apt: $APT_PKG"
    sudo apt-get update -y >/dev/null 2>&1 || true
    if sudo apt-get install -y $APT_PKG; then
        log_ok "[16] Installed"
        mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"
        return 0
    fi
    log_err "[16] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[16] Verify OK"; return 0; fi; log_warn "[16] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() { sudo apt-get remove -y $APT_PKG; rm -f "$INSTALLED_MARK"; log_ok "[16] Removed"; }

case "$VERB" in
    install)   verb_install ;;
    check)     verb_check ;;
    repair)    verb_repair ;;
    uninstall) verb_uninstall ;;
    *)         log_err "[16] Unknown verb: $VERB"; exit 2 ;;
esac
