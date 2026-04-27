#!/usr/bin/env bash
# scripts-linux/_shared/interactive.sh
# Cross-script "prompt with default" helpers. Mirrors the _prompt helper
# already in 70-install-wordpress-ubuntu/run.sh so 16/18/70 give a uniform
# UX:    "MySQL port [3306]: "    -- Enter accepts the default.
#
# Public API:
#   interactive_is_enabled "$@"          # echoes 1 if --interactive|-i in argv, else 0
#   interactive_strip_flag "$@"          # echoes args with --interactive/-i removed
#   prompt_with_default LABEL DEFAULT [VALIDATOR_FN]
#       -> echoes the user's reply (or DEFAULT on empty/EOF). If VALIDATOR_FN is
#          provided, the prompt loops until VALIDATOR_FN <reply> returns 0.
#   validate_port REPLY                  # 1..65535
#   validate_php_version REPLY           # latest | <major>.<minor>[.<patch>]
#   validate_path_writable REPLY         # exists OR parent is writable

interactive_is_enabled() {
    local a
    for a in "$@"; do
        case "$a" in
            -i|--interactive) echo 1; return 0 ;;
        esac
    done
    echo 0
}

interactive_strip_flag() {
    local out=()
    local a
    for a in "$@"; do
        case "$a" in
            -i|--interactive) ;;
            *) out+=("$a") ;;
        esac
    done
    printf '%s\n' "${out[@]}"
}

# prompt_with_default LABEL DEFAULT [VALIDATOR_FN]
prompt_with_default() {
    local label="$1"
    local default="$2"
    local validator="${3:-}"
    local reply
    while :; do
        # Prompt to STDERR so command substitution captures only the reply.
        if [ -n "$default" ]; then
            printf '  %s [%s]: ' "$label" "$default" >&2
        else
            printf '  %s: ' "$label" >&2
        fi
        # Read from /dev/tty so this works even when stdin is piped.
        if ! IFS= read -r reply < /dev/tty 2>/dev/null; then
            reply=""
        fi
        if [ -z "$reply" ]; then reply="$default"; fi
        if [ -z "$validator" ]; then
            printf '%s\n' "$reply"
            return 0
        fi
        if "$validator" "$reply"; then
            printf '%s\n' "$reply"
            return 0
        fi
        printf '  -> invalid value, please try again.\n' >&2
    done
}

validate_port() {
    local v="$1"
    case "$v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$v" -ge 1 ] && [ "$v" -le 65535 ]
}

validate_php_version() {
    local v="$1"
    case "$v" in
        latest) return 0 ;;
        [5-9].[0-9]|[5-9].[0-9].[0-9]|[5-9].[0-9].[0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

validate_path_writable() {
    local p="$1"
    [ -z "$p" ] && return 1
    if [ -d "$p" ]; then return 0; fi
    local parent
    parent="$(dirname -- "$p")"
    [ -d "$parent" ]    # creatable iff parent exists
}
