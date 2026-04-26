#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  scripts/os/helpers/mac/clean-vscode-mac.sh
#
#  Removes installed VS Code "integration" entries from a user-selectable
#  subset of macOS surfaces. Does NOT uninstall Code.app itself.
#
#  Surfaces (each is opt-in via flag, default = ALL on):
#    --services        ~/Library/Services/*VSCode*.workflow / *Visual Studio Code*
#    --code-cli        the `code` shell symlink (/usr/local/bin/code,
#                                                /opt/homebrew/bin/code)
#    --launchservices  lsregister -u for com.microsoft.VSCode UTI handlers
#    --loginitems      ~/Library/LaunchAgents/*vscode*.plist + osascript
#                      "delete login item" calls for any item whose path
#                      points at Visual Studio Code.app.
#
#  Scope (Auto-detect, no -Scope flag per user spec):
#    Always sweeps ~/Library  (CurrentUser writes -- no sudo needed).
#    Sweeps /Library          (AllUsers) ONLY when the path is writable
#                              AND we are running as root. Non-root runs
#                              SKIP /Library and log it as an info line --
#                              we never silently fail-and-claim-success.
#
#  Safety: plan-then-prompt
#    1. Build a plan: enumerate every concrete file/symlink/lsregister
#       target that WOULD be removed.
#    2. Print the plan grouped by surface, with absolute paths.
#    3. Prompt y/N (default N). --yes skips the prompt. --dry-run prints
#       the plan and exits 0 without prompting OR deleting.
#    4. Apply: rm -f / unlink / lsregister -u / osascript. Each action
#       writes a JSONL line to the audit log so the operator has a
#       forensic trail (matches the script-54 audit format).
#
#  Audit log: $HOME/Library/Logs/lovable-toolkit/clean-vscode-mac/<ts>.jsonl
#
#  Exit codes:
#    0  -- success (or dry-run)
#    1  -- user aborted at prompt
#    2  -- usage error (bad flag, conflicting flags, not on macOS)
#    3  -- one or more removal actions failed (plan still printed)
#
#  CODE RED logging rule: every file/path error includes the EXACT path
#  and the failure reason (errno text or the failing command's stderr).
# ---------------------------------------------------------------------------

set -u
# Note: do NOT `set -e` -- we want to keep cleaning the next surface even
# if one rm fails; instead each call increments $fail_count.

# ---- OS guard --------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[FAIL] clean-vscode-mac.sh is macOS-only (detected: $(uname -s))." >&2
    echo "       For Windows, use script 54 'vscode-menu-installer uninstall'." >&2
    exit 2
fi

# ---- defaults --------------------------------------------------------------
do_services=1
do_code_cli=1
do_launchservices=1
do_loginitems=1
dry_run=0
assume_yes=0
verbosity="normal"   # quiet | normal | debug -- mirrors script-54 contract

# ---- arg parse -------------------------------------------------------------
# Selective surface flags: passing ANY explicit --<surface> flag turns OFF
# the others (so `--services` alone means "ONLY services"). This matches
# the user's expectation of a precise surgical tool.
explicit_surface=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --services)
            if [[ $explicit_surface -eq 0 ]]; then
                do_services=0; do_code_cli=0; do_launchservices=0; do_loginitems=0
                explicit_surface=1
            fi
            do_services=1 ;;
        --code-cli)
            if [[ $explicit_surface -eq 0 ]]; then
                do_services=0; do_code_cli=0; do_launchservices=0; do_loginitems=0
                explicit_surface=1
            fi
            do_code_cli=1 ;;
        --launchservices)
            if [[ $explicit_surface -eq 0 ]]; then
                do_services=0; do_code_cli=0; do_launchservices=0; do_loginitems=0
                explicit_surface=1
            fi
            do_launchservices=1 ;;
        --loginitems)
            if [[ $explicit_surface -eq 0 ]]; then
                do_services=0; do_code_cli=0; do_launchservices=0; do_loginitems=0
                explicit_surface=1
            fi
            do_loginitems=1 ;;
        --all)
            do_services=1; do_code_cli=1; do_launchservices=1; do_loginitems=1
            explicit_surface=1 ;;
        --dry-run|-n)         dry_run=1 ;;
        --yes|-y)             assume_yes=1 ;;
        --quiet)              verbosity="quiet" ;;
        --debug)              verbosity="debug" ;;
        --help|-h)
            sed -n '2,/^# ----------/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "[FAIL] Unknown flag: '$1' (failure: not in --services|--code-cli|--launchservices|--loginitems|--all|--dry-run|--yes|--quiet|--debug|--help)" >&2
            exit 2 ;;
    esac
    shift
done

# ---- audit log setup -------------------------------------------------------
ts="$(date +%Y%m%d-%H%M%S)"
audit_dir="${HOME}/Library/Logs/lovable-toolkit/clean-vscode-mac"
if ! mkdir -p "$audit_dir" 2>/dev/null; then
    # Non-fatal: we degrade to /tmp + a loud warning (CODE RED: include
    # the path + the actual mkdir failure reason).
    err="$(mkdir -p "$audit_dir" 2>&1 || true)"
    echo "[WARN] Failed to create audit dir: $audit_dir (failure: ${err:-unknown})" >&2
    audit_dir="/tmp"
fi
audit_path="${audit_dir}/${ts}.jsonl"

# Open the session-start record. echo -E preserves backslashes if any.
if ! printf '%s\n' \
    "{\"event\":\"session-start\",\"action\":\"clean-vscode-mac\",\"ts\":\"${ts}\",\"user\":\"${USER:-unknown}\",\"euid\":$(id -u),\"surfaces\":{\"services\":${do_services},\"code-cli\":${do_code_cli},\"launchservices\":${do_launchservices},\"loginitems\":${do_loginitems}},\"dry_run\":${dry_run}}" \
    > "$audit_path" 2>/dev/null
then
    err="$(printf 'x' > "$audit_path" 2>&1 || true)"
    echo "[WARN] Failed to open audit log at: $audit_path (failure: ${err:-unknown}). Continuing without audit trail." >&2
    audit_path=""
fi

# ---- logging helpers -------------------------------------------------------
log_info()    { [[ "$verbosity" != "quiet" ]] && echo "[INFO] $*"; }
log_debug()   { [[ "$verbosity" == "debug"  ]] && echo "[DEBUG] $*"; }
log_warn()    { echo "[WARN] $*" >&2; }
log_err()     { echo "[FAIL] $*" >&2; }
log_ok()      { [[ "$verbosity" != "quiet" ]] && echo "[ OK ] $*"; }

audit_event() {
    # audit_event <op> <surface> <target> [reason]
    local op="$1" surface="$2" target="$3" reason="${4:-}"
    [[ -z "$audit_path" ]] && return 0
    # Escape backslashes and double quotes in $target / $reason for JSON.
    local t="${target//\\/\\\\}";  t="${t//\"/\\\"}"
    local r="${reason//\\/\\\\}";  r="${r//\"/\\\"}"
    printf '{"op":"%s","surface":"%s","target":"%s","reason":"%s","ts":"%s"}\n' \
        "$op" "$surface" "$t" "$r" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        >> "$audit_path" 2>/dev/null || true
}

# ---- root + scope detection ------------------------------------------------
is_root=0
[[ "$(id -u)" == "0" ]] && is_root=1

# ---- planners (build the list of targets that WOULD be removed) -----------
# Each planner echoes one absolute target per line on stdout. Stderr is
# reserved for warnings (e.g. unreadable directory). No side effects.

plan_services() {
    # User-scope Services (Quick Actions / workflows)
    local d="${HOME}/Library/Services"
    if [[ -d "$d" ]]; then
        # Match common VS Code Service names. Use -iname so case differences
        # in user-installed workflows still match.
        find "$d" -maxdepth 1 -type d \( \
              -iname '*VSCode*.workflow' \
           -o -iname '*Visual Studio Code*.workflow' \
           -o -iname '*Open*Code*.workflow' \
        \) 2>/dev/null
    else
        log_debug "Skip services plan: directory missing -> $d"
    fi
    # Machine-scope: only when root + writable.
    if [[ $is_root -eq 1 ]]; then
        local md="/Library/Services"
        if [[ -d "$md" && -w "$md" ]]; then
            find "$md" -maxdepth 1 -type d \( \
                  -iname '*VSCode*.workflow' \
               -o -iname '*Visual Studio Code*.workflow' \
               -o -iname '*Open*Code*.workflow' \
            \) 2>/dev/null
        fi
    fi
}

plan_code_cli() {
    # The `code` symlink dropped by VS Code's "Shell Command: Install
    # 'code' command in PATH" action. Two known sites:
    local candidates=(
        "/usr/local/bin/code"
        "/opt/homebrew/bin/code"
    )
    for c in "${candidates[@]}"; do
        if [[ -L "$c" || -f "$c" ]]; then
            # Only include when its target points back at a Code.app bundle
            # OR when we cannot resolve (broken link -> still ours to clean).
            local target=""
            if [[ -L "$c" ]]; then
                target="$(readlink "$c" 2>/dev/null || true)"
            fi
            if [[ -z "$target" ]] \
               || [[ "$target" == *"Visual Studio Code.app"* ]] \
               || [[ "$target" == *"VSCode"* ]]; then
                echo "$c"
            else
                log_debug "Skip code-cli candidate $c -> not a VS Code symlink (points at: $target)"
            fi
        fi
    done
}

plan_launchservices() {
    # We don't enumerate; lsregister -u just unregisters the bundle's
    # UTI claims. The "plan" line is the bundle ID we'd unregister.
    # Detect Code.app paths so we report what `lsregister -u` will hit.
    local apps=(
        "/Applications/Visual Studio Code.app"
        "${HOME}/Applications/Visual Studio Code.app"
    )
    local found=0
    for a in "${apps[@]}"; do
        if [[ -d "$a" ]]; then
            echo "lsregister -u :: $a"
            found=1
        fi
    done
    if [[ $found -eq 0 ]]; then
        log_debug "Skip launchservices plan: no Code.app bundle found in standard locations"
    fi
}

plan_loginitems() {
    # 1) LaunchAgents plists referencing VS Code
    local d="${HOME}/Library/LaunchAgents"
    if [[ -d "$d" ]]; then
        find "$d" -maxdepth 1 -type f -iname '*vscode*.plist' 2>/dev/null
        find "$d" -maxdepth 1 -type f -iname '*visual*studio*code*.plist' 2>/dev/null
    fi
    if [[ $is_root -eq 1 && -d /Library/LaunchAgents && -w /Library/LaunchAgents ]]; then
        find /Library/LaunchAgents -maxdepth 1 -type f -iname '*vscode*.plist' 2>/dev/null
        find /Library/LaunchAgents -maxdepth 1 -type f -iname '*visual*studio*code*.plist' 2>/dev/null
    fi
    # 2) System Events login items pointing at Code.app
    if command -v osascript >/dev/null 2>&1; then
        local items
        items="$(osascript -e 'tell application "System Events" to get the path of every login item' 2>/dev/null || true)"
        if [[ -n "$items" ]]; then
            # Comma-separated; split + filter for Code.app references.
            IFS=',' read -ra arr <<< "$items"
            for it in "${arr[@]}"; do
                # Trim whitespace
                it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"
                if [[ "$it" == *"Visual Studio Code.app"* ]]; then
                    echo "loginitem :: $it"
                fi
            done
        fi
    else
        log_debug "osascript not available; skipping login-items enumeration"
    fi
}

# ---- collect plan ----------------------------------------------------------
declare -a plan_services_arr=() plan_codecli_arr=() plan_lsreg_arr=() plan_login_arr=()

if [[ $do_services       -eq 1 ]]; then mapfile -t plan_services_arr < <(plan_services);       fi
if [[ $do_code_cli       -eq 1 ]]; then mapfile -t plan_codecli_arr  < <(plan_code_cli);        fi
if [[ $do_launchservices -eq 1 ]]; then mapfile -t plan_lsreg_arr    < <(plan_launchservices);  fi
if [[ $do_loginitems     -eq 1 ]]; then mapfile -t plan_login_arr    < <(plan_loginitems);      fi

total_targets=$(( ${#plan_services_arr[@]} + ${#plan_codecli_arr[@]} + ${#plan_lsreg_arr[@]} + ${#plan_login_arr[@]} ))

# ---- print plan ------------------------------------------------------------
echo ""
echo "============================================================"
echo " macOS VS Code integration cleanup -- PLAN"
echo "============================================================"
printf "  user        : %s (euid=%s, root=%s)\n" "${USER:-unknown}" "$(id -u)" "$is_root"
printf "  surfaces    : services=%s code-cli=%s launchservices=%s loginitems=%s\n" \
    "$do_services" "$do_code_cli" "$do_launchservices" "$do_loginitems"
printf "  scope sweep : ~/Library always; /Library only when root (root=%s)\n" "$is_root"
printf "  audit log   : %s\n" "${audit_path:-<disabled>}"
printf "  total plan  : %s target(s)\n" "$total_targets"
echo "------------------------------------------------------------"

print_group() {
    local title="$1"; shift
    local -a items=("$@")
    if [[ ${#items[@]} -eq 0 || ( ${#items[@]} -eq 1 && -z "${items[0]}" ) ]]; then
        printf "  %-16s : (none)\n" "$title"
    else
        printf "  %-16s : %d\n" "$title" "${#items[@]}"
        for it in "${items[@]}"; do
            [[ -z "$it" ]] && continue
            printf "      - %s\n" "$it"
        done
    fi
}

[[ $do_services       -eq 1 ]] && print_group "Services"          "${plan_services_arr[@]}"
[[ $do_code_cli       -eq 1 ]] && print_group "code CLI symlink"  "${plan_codecli_arr[@]}"
[[ $do_launchservices -eq 1 ]] && print_group "LaunchServices"    "${plan_lsreg_arr[@]}"
[[ $do_loginitems     -eq 1 ]] && print_group "Login items"       "${plan_login_arr[@]}"
echo "============================================================"

if [[ $total_targets -eq 0 ]]; then
    log_info "Nothing to clean -- no matching targets on the selected surfaces."
    audit_event "no-op" "all" "(plan empty)" ""
    exit 0
fi

# ---- dry-run? --------------------------------------------------------------
if [[ $dry_run -eq 1 ]]; then
    log_info "Dry-run mode: no deletions performed. Re-run without --dry-run (and answer 'y' at the prompt) to apply."
    audit_event "dry-run-end" "all" "" ""
    exit 0
fi

# ---- prompt ----------------------------------------------------------------
if [[ $assume_yes -eq 0 ]]; then
    # Read from /dev/tty so the prompt works even when stdin is a pipe.
    printf "Proceed with deletion? [y/N]: " > /dev/tty
    reply=""
    if ! read -r reply < /dev/tty; then
        echo ""
        log_warn "Could not read from /dev/tty (failure: stdin not interactive). Aborting -- pass --yes to skip the prompt."
        audit_event "abort" "all" "(no tty)" "interactive prompt unreadable"
        exit 1
    fi
    if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        log_info "Aborted by user (reply: '${reply}'). No changes made."
        audit_event "abort" "all" "(user said no)" "reply=${reply}"
        exit 1
    fi
fi

# ---- apply -----------------------------------------------------------------
removed_count=0
fail_count=0

remove_path() {
    # remove_path <surface> <path>
    local surface="$1" target="$2"
    if [[ -z "$target" ]]; then return 0; fi
    local err=""
    if [[ -d "$target" && ! -L "$target" ]]; then
        err="$(rm -rf -- "$target" 2>&1 || true)"
    else
        err="$(rm -f -- "$target" 2>&1 || true)"
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        # Still there -> count as failure with exact path + reason.
        log_err "Failed to remove ${surface} target: ${target} (failure: ${err:-still present after rm})"
        audit_event "fail" "$surface" "$target" "${err:-still present after rm}"
        fail_count=$(( fail_count + 1 ))
    else
        log_ok "removed [${surface}] ${target}"
        audit_event "remove" "$surface" "$target" ""
        removed_count=$(( removed_count + 1 ))
    fi
}

# Services
for p in "${plan_services_arr[@]}"; do
    [[ -z "$p" ]] && continue
    remove_path "services" "$p"
done

# code CLI symlink
for p in "${plan_codecli_arr[@]}"; do
    [[ -z "$p" ]] && continue
    # /usr/local/bin and /opt/homebrew/bin require root for non-owners.
    if [[ ! -w "$(dirname "$p")" ]]; then
        log_warn "Cannot write to $(dirname "$p") (failure: not writable by uid=$(id -u)). Skipping ${p} -- re-run with sudo to remove."
        audit_event "skip" "code-cli" "$p" "directory not writable by current uid"
        fail_count=$(( fail_count + 1 ))
        continue
    fi
    remove_path "code-cli" "$p"
done

# LaunchServices: lsregister -u <bundle path>
if [[ ${#plan_lsreg_arr[@]} -gt 0 && -n "${plan_lsreg_arr[0]}" ]]; then
    lsreg="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [[ ! -x "$lsreg" ]]; then
        log_warn "lsregister not found at expected path: ${lsreg} (failure: binary missing or not executable). Skipping LaunchServices unregistration."
        audit_event "fail" "launchservices" "$lsreg" "lsregister binary missing"
        fail_count=$(( fail_count + 1 ))
    else
        for entry in "${plan_lsreg_arr[@]}"; do
            [[ -z "$entry" ]] && continue
            # entry format: "lsregister -u :: <bundle path>"
            bundle="${entry#lsregister -u :: }"
            err="$("$lsreg" -u "$bundle" 2>&1 || true)"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                log_err "lsregister -u failed for: ${bundle} (failure: rc=${rc}, stderr=${err:-<empty>})"
                audit_event "fail" "launchservices" "$bundle" "rc=${rc} ${err}"
                fail_count=$(( fail_count + 1 ))
            else
                log_ok "lsregister -u  ${bundle}"
                audit_event "remove" "launchservices" "$bundle" ""
                removed_count=$(( removed_count + 1 ))
            fi
        done
    fi
fi

# Login items + LaunchAgents
for entry in "${plan_login_arr[@]}"; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == loginitem\ ::* ]]; then
        path="${entry#loginitem :: }"
        # Use display name = basename without .app for the System Events query.
        name="$(basename "$path")"
        # AppleScript wants the literal name as it appears in login items,
        # which is usually the .app's display name.
        err="$(osascript -e "tell application \"System Events\" to delete login item \"${name%.app}\"" 2>&1 || true)"
        rc=$?
        if [[ $rc -ne 0 ]] || [[ "$err" == *"error"* && "$err" != *"doesn't exist"* ]]; then
            log_err "Failed to remove login item: ${path} (failure: rc=${rc}, ${err:-<no stderr>})"
            audit_event "fail" "loginitems" "$path" "rc=${rc} ${err}"
            fail_count=$(( fail_count + 1 ))
        else
            log_ok "removed login item: ${path}"
            audit_event "remove" "loginitems" "$path" ""
            removed_count=$(( removed_count + 1 ))
        fi
    else
        # Plain LaunchAgent .plist -- unload first (best-effort) then delete.
        if command -v launchctl >/dev/null 2>&1; then
            launchctl unload "$entry" >/dev/null 2>&1 || true
        fi
        remove_path "loginitems" "$entry"
    fi
done

# ---- summary ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " macOS VS Code integration cleanup -- SUMMARY"
echo "============================================================"
printf "  removed : %d\n" "$removed_count"
printf "  failed  : %d\n" "$fail_count"
printf "  audit   : %s\n" "${audit_path:-<disabled>}"
echo "============================================================"
audit_event "session-end" "all" "" "removed=${removed_count} failed=${fail_count}"

if [[ $fail_count -gt 0 ]]; then
    log_warn "Completed with ${fail_count} failure(s). Review the audit log above for exact paths + reasons."
    exit 3
fi
exit 0