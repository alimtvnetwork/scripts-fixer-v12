#!/usr/bin/env bash
# scripts-linux/_shared/port-change.sh
# Shared engine for the 80-90 "change-port" family.
#
# Every per-service script populates a small set of variables and then
# calls `pc_run "$@"`. The engine handles:
#
#   * Argument parsing (--port, --interactive, --yes, --dry-run,
#     --no-restart, --no-firewall, -h)
#   * Default-port pickup from config.json
#   * Backup of every targeted config file (.bak.<ts>)
#   * Sed-based regex rewrite on each (path, pattern, replacement)
#     edit-spec, with a per-file diff printed to stderr
#   * Service-specific config validator (caller-supplied function)
#   * Plan-then-confirm prompt (reuses _shared/confirm.sh)
#   * Optional firewall opener (ufw/firewalld) for the new port,
#     with a clear warning that the OLD port is NOT auto-closed
#   * Optional service restart with rollback on validator failure
#
# CODE RED: every file/path error MUST log exact path + reason via
# log_file_error. Never edit a file that we did not back up first.
#
# Required variables (set by caller before sourcing OR before pc_run):
#   PC_SERVICE_ID         e.g. "80" -- log prefix
#   PC_SERVICE_NAME       e.g. "OpenSSH server"
#   PC_DEFAULT_PORT       e.g. "22"
#   PC_CONFIG_JSON        absolute path to per-script config.json
#   PC_SYSTEMD_UNIT       e.g. "ssh" -- empty string disables restart
#   PC_VALIDATE_CMD       shell snippet that exits 0 on a valid config
#                         (e.g. 'sshd -t'). Empty = no validator.
#   PC_EDIT_SPECS         array of "path|||sed-pattern|||sed-replacement"
#                         tuples. The literal {PORT} token in the
#                         replacement is substituted with the new port.
#   PC_FIREWALL_PROTO     "tcp" (default) or "tcp,udp"
#
# Optional (caller may export before pc_run):
#   PC_OLD_PORT_HINT      pre-detected current port (skip auto-detect)
#   PC_EXTRA_HELP         extra lines shown in --help

: "${PC_FIREWALL_PROTO:=tcp}"

# -- helpers ----------------------------------------------------------------

_pc_ts() { date +%Y%m%d-%H%M%S; }

_pc_backup_file() {
    local path="$1" ts="$2"
    if [ ! -f "$path" ]; then
        log_file_error "$path" "config file missing -- cannot back up before edit"
        return 1
    fi
    local bak="$path.bak.$ts"
    if ! sudo cp -p "$path" "$bak" 2>/dev/null; then
        log_file_error "$bak" "backup copy failed (sudo cp)"
        return 1
    fi
    log_ok "[$PC_SERVICE_ID] backup -> $bak"
    printf '%s\n' "$bak"
}

_pc_apply_edit() {
    # Args: path  sed-pattern  sed-replacement-with-{PORT}  new-port
    local path="$1" pat="$2" repl="$3" port="$4"
    if [ ! -w "$path" ] && ! sudo test -w "$path"; then
        log_file_error "$path" "config file not writable (and sudo cannot write)"
        return 1
    fi
    local final="${repl//\{PORT\}/$port}"
    # `|` as sed delimiter -- avoids clashing with paths/URLs.
    if ! sudo sed -i.tmp "s|$pat|$final|g" "$path" 2>/dev/null; then
        log_file_error "$path" "sed rewrite failed (pattern='$pat')"
        return 1
    fi
    sudo rm -f "$path.tmp" 2>/dev/null || true
    return 0
}

_pc_diff() {
    local bak="$1" cur="$2"
    if command -v diff >/dev/null 2>&1; then
        printf '\n  ----- diff: %s -----\n' "$cur" >&2
        sudo diff -u "$bak" "$cur" | sed 's/^/    /' >&2 || true
    fi
}

_pc_open_firewall() {
    local port="$1"
    local opened=0
    if command -v ufw >/dev/null 2>&1; then
        local proto
        for proto in ${PC_FIREWALL_PROTO//,/ }; do
            if sudo ufw allow "$port/$proto" >/dev/null 2>&1; then
                log_ok "[$PC_SERVICE_ID] ufw allow $port/$proto"
                opened=1
            else
                log_warn "[$PC_SERVICE_ID] ufw allow $port/$proto failed (ufw may be inactive)"
            fi
        done
    elif command -v firewall-cmd >/dev/null 2>&1; then
        local proto
        for proto in ${PC_FIREWALL_PROTO//,/ }; do
            if sudo firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1; then
                log_ok "[$PC_SERVICE_ID] firewalld add-port $port/$proto"
                opened=1
            fi
        done
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    else
        log_info "[$PC_SERVICE_ID] no ufw/firewalld detected -- skipping firewall step"
        return 0
    fi
    if [ "$opened" = "1" ]; then
        log_warn "[$PC_SERVICE_ID] NEW port $port opened; OLD port is NOT auto-closed -- review manually."
    fi
}

_pc_validate_config() {
    [ -z "${PC_VALIDATE_CMD:-}" ] && return 0
    log_info "[$PC_SERVICE_ID] validating config: $PC_VALIDATE_CMD"
    if bash -c "$PC_VALIDATE_CMD" >/dev/null 2>&1; then
        log_ok "[$PC_SERVICE_ID] config validator passed"
        return 0
    fi
    log_err "[$PC_SERVICE_ID] config validator FAILED -- not restarting service"
    return 1
}

_pc_restart_service() {
    [ -z "${PC_SYSTEMD_UNIT:-}" ] && {
        log_info "[$PC_SERVICE_ID] no systemd unit configured -- skipping restart"
        return 0
    }
    log_info "[$PC_SERVICE_ID] restarting unit: $PC_SYSTEMD_UNIT"
    if sudo systemctl restart "$PC_SYSTEMD_UNIT" 2>/dev/null; then
        log_ok "[$PC_SERVICE_ID] $PC_SYSTEMD_UNIT restarted"
        sudo systemctl --no-pager --lines=0 status "$PC_SYSTEMD_UNIT" 2>/dev/null | head -3
        return 0
    fi
    log_err "[$PC_SERVICE_ID] systemctl restart $PC_SYSTEMD_UNIT FAILED"
    return 1
}

_pc_rollback() {
    # Args: list of "current|||backup" pairs
    log_warn "[$PC_SERVICE_ID] rolling back edits..."
    local pair cur bak
    for pair in "$@"; do
        cur="${pair%%|||*}"; bak="${pair##*|||}"
        if sudo cp -p "$bak" "$cur" 2>/dev/null; then
            log_ok "[$PC_SERVICE_ID] restored $cur from $bak"
        else
            log_file_error "$cur" "rollback failed -- backup at $bak"
        fi
    done
}

_pc_help() {
    cat <<EOF
scripts-linux/$PC_SERVICE_ID-change-port-* — change the listening port for $PC_SERVICE_NAME.

Usage:
    run.sh [--port <n>] [--interactive] [--yes] [--dry-run]
           [--no-restart] [--no-firewall] [-h|--help]

Flags:
    --port <n>       New listening port (1..65535). Default from config.json: $PC_DEFAULT_PORT
    --interactive    Prompt for the port (current value pre-filled when detectable)
    --yes            Skip the confirmation prompt; still does backup + validate
    --dry-run        Show planned edits and diffs only; touch nothing
    --no-restart     Skip the systemctl restart step
    --no-firewall    Skip the ufw/firewalld port-open step
    -h, --help       Show this help and exit

Safety:
    * Every targeted config file is backed up to <path>.bak.<timestamp> before any edit.
    * The service's own config validator is run after the edit; on failure the script
      rolls every file back from its backup and refuses to restart.
    * The OLD port is NEVER auto-closed in the firewall — review manually.
${PC_EXTRA_HELP:-}
EOF
}

# Public entry point. Caller invokes:  pc_run "$@"
pc_run() {
    local PORT="" INTERACTIVE=0 ASSUME_YES=0 DRY_RUN=0 NO_RESTART=0 NO_FW=0
    if [ -f "$PC_CONFIG_JSON" ] && command -v jq >/dev/null 2>&1; then
        local cfg_port
        cfg_port=$(jq -r '.defaultPort // empty' "$PC_CONFIG_JSON" 2>/dev/null)
        [ -n "$cfg_port" ] && PC_DEFAULT_PORT="$cfg_port"
    fi
    PORT="$PC_DEFAULT_PORT"

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)        _pc_help; return 0 ;;
            --port)           PORT="${2:-}"; shift 2 ;;
            --port=*)         PORT="${1#--port=}"; shift ;;
            -i|--interactive) INTERACTIVE=1; shift ;;
            -y|--yes)         ASSUME_YES=1; shift ;;
            --dry-run)        DRY_RUN=1; shift ;;
            --no-restart)     NO_RESTART=1; shift ;;
            --no-firewall)    NO_FW=1; shift ;;
            *)                log_warn "[$PC_SERVICE_ID] ignoring unknown arg: $1"; shift ;;
        esac
    done

    if [ "$INTERACTIVE" = "1" ]; then
        # Source interactive helpers lazily (caller's ROOT path).
        local _root; _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        . "$_root/_shared/interactive.sh"
        PORT="$(prompt_with_default "$PC_SERVICE_NAME new port" "$PORT" validate_port)"
    fi

    case "$PORT" in
        ''|*[!0-9]*) log_err "[$PC_SERVICE_ID] invalid port '$PORT' (expected 1..65535)"; return 2 ;;
    esac
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || {
        log_err "[$PC_SERVICE_ID] port out of range: $PORT"; return 2; }

    log_info "[$PC_SERVICE_ID] $PC_SERVICE_NAME -> port $PORT (dry-run=$DRY_RUN restart=$([ $NO_RESTART = 1 ] && echo no || echo yes) fw=$([ $NO_FW = 1 ] && echo no || echo yes))"

    # Pre-flight: every targeted file must exist.
    local spec path missing=0
    for spec in "${PC_EDIT_SPECS[@]}"; do
        path="${spec%%|||*}"
        if [ ! -f "$path" ]; then
            log_file_error "$path" "config file missing -- is $PC_SERVICE_NAME installed?"
            missing=1
        fi
    done
    [ "$missing" = "1" ] && return 1

    # Render plan
    printf '\n  ===== %s -- planned edits =====\n' "$PC_SERVICE_NAME" >&2
    printf '  %-50s  ->  port = %s\n' "$path" "$PORT" >&2
    for spec in "${PC_EDIT_SPECS[@]}"; do
        path="${spec%%|||*}"
        printf '  edit: %s\n' "$path" >&2
    done
    [ -n "${PC_VALIDATE_CMD:-}" ]    && printf '  validate: %s\n' "$PC_VALIDATE_CMD" >&2
    [ -n "${PC_SYSTEMD_UNIT:-}" ] && [ "$NO_RESTART" = "0" ] && printf '  restart : systemctl restart %s\n' "$PC_SYSTEMD_UNIT" >&2
    [ "$NO_FW" = "0" ] && printf '  firewall: open %s/%s (ufw or firewalld)\n' "$PORT" "$PC_FIREWALL_PROTO" >&2
    printf '\n' >&2

    if [ "$DRY_RUN" = "1" ]; then
        log_ok "[$PC_SERVICE_ID] dry-run: no changes made"
        return 0
    fi

    if [ "$ASSUME_YES" != "1" ]; then
        if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
            log_err "[$PC_SERVICE_ID] no TTY and --yes not given -- aborting"; return 1
        fi
        printf "  Type 'yes' to apply, anything else to abort: " >&2
        local reply=""
        if [ -r /dev/tty ]; then IFS= read -r reply </dev/tty; else IFS= read -r reply; fi
        case "$reply" in y|Y|yes|YES|Yes) : ;; *) log_warn "[$PC_SERVICE_ID] aborted by operator"; return 1 ;; esac
    fi

    # Backup + edit
    local ts; ts=$(_pc_ts)
    local pairs=() pat repl
    for spec in "${PC_EDIT_SPECS[@]}"; do
        path="${spec%%|||*}"
        local rest="${spec#*|||}"
        pat="${rest%%|||*}"
        repl="${rest#*|||}"
        local bak; bak=$(_pc_backup_file "$path" "$ts") || { _pc_rollback "${pairs[@]}"; return 1; }
        if ! _pc_apply_edit "$path" "$pat" "$repl" "$PORT"; then
            _pc_rollback "${pairs[@]}" "$path|||$bak"
            return 1
        fi
        pairs+=("$path|||$bak")
        _pc_diff "$bak" "$path"
    done

    if ! _pc_validate_config; then
        _pc_rollback "${pairs[@]}"
        return 1
    fi

    [ "$NO_FW" = "0" ] && _pc_open_firewall "$PORT"

    if [ "$NO_RESTART" = "0" ]; then
        if ! _pc_restart_service; then
            log_err "[$PC_SERVICE_ID] restart failed -- config is on disk; rolling back."
            _pc_rollback "${pairs[@]}"
            return 1
        fi
    else
        log_warn "[$PC_SERVICE_ID] --no-restart given; service still running on the OLD port until you restart it manually."
    fi

    log_ok "[$PC_SERVICE_ID] $PC_SERVICE_NAME now configured for port $PORT"
    return 0
}