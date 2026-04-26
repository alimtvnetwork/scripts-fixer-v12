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
# All log levels write to stderr so the planners' stdout (which is parsed
# into the plan array via `mapfile`) stays free of log lines. Only the
# planners themselves echo target paths to stdout.
log_info()    { [[ "$verbosity" != "quiet" ]] && echo "[INFO] $*" >&2; }
log_debug()   { [[ "$verbosity" == "debug"  ]] && echo "[DEBUG] $*" >&2; }
log_warn()    { echo "[WARN] $*" >&2; }
log_err()     { echo "[FAIL] $*" >&2; }
log_ok()      { [[ "$verbosity" != "quiet" ]] && echo "[ OK ] $*" >&2; }

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

# ---- ownership detection (verify-before-plan) ------------------------------
# A candidate is only added to the plan if a positive VS Code-ownership
# signal is found. Rejections are NEVER silent -- they log a [DEBUG] line
# (visible with --debug) AND a [WARN] line (always visible) when a
# user-provided/heuristic match was rejected, so the operator knows why
# something they expected to see is missing from the plan.
#
# Signals (any one is sufficient):
#   * .workflow bundle:    Contents/Info.plist -> CFBundleIdentifier contains
#                          "VSCode" / "vscode" / "microsoft.code"
#                          OR document.wflow references "Visual Studio Code.app"
#   * code CLI symlink:    readlink -f resolves to a path INSIDE a real
#                          Code.app bundle (Contents/Resources/app/bin/code)
#                          OR the symlink is broken AND the basename is "code"
#                          AND the previous link target string mentioned VS Code
#   * Code.app bundle:     Info.plist CFBundleIdentifier == "com.microsoft.VSCode"
#                          (or *.VSCodeInsiders / *.VSCodeExploration)
#   * LaunchAgents .plist: Label or ProgramArguments[0] / Program references
#                          "com.microsoft.VSCode" OR a path containing
#                          "Visual Studio Code.app"
#   * Login item:          Path contains "Visual Studio Code.app"
#                          (already filtered upstream by AppleScript query)
#
# CODE RED: every rejection log includes the EXACT path AND the reason.

_pb() {
    # PlistBuddy wrapper -- echoes value or empty; never aborts the script.
    /usr/libexec/PlistBuddy -c "$1" "$2" 2>/dev/null || true
}

_is_vscode_bundle_id() {
    # Returns 0 if the given CFBundleIdentifier string is VS Code-owned.
    local id="${1:-}"
    [[ -z "$id" ]] && return 1
    case "$id" in
        com.microsoft.VSCode|com.microsoft.VSCodeInsiders|com.microsoft.VSCodeExploration) return 0 ;;
        *vscode*|*VSCode*|*microsoft.code*) return 0 ;;
    esac
    return 1
}

verify_workflow() {
    # verify_workflow <abs path to .workflow bundle>
    local wf="$1"
    if [[ ! -d "$wf" ]]; then
        log_warn "Verification skipped: path is not a directory -> ${wf} (failure: -d test failed)"
        return 1
    fi
    local info="${wf}/Contents/Info.plist"
    if [[ -f "$info" ]]; then
        local id; id="$(_pb 'Print :CFBundleIdentifier' "$info")"
        if _is_vscode_bundle_id "$id"; then
            log_debug "verify ok [services] ${wf} (bundle id: ${id})"
            return 0
        fi
        # Fallback: scan the .wflow document for an explicit Code.app reference.
        local doc="${wf}/Contents/document.wflow"
        if [[ -f "$doc" ]] && grep -qE 'Visual Studio Code\.app|com\.microsoft\.VSCode' "$doc" 2>/dev/null; then
            log_debug "verify ok [services] ${wf} (document.wflow references VS Code)"
            return 0
        fi
        log_warn "Skip ${wf} (failure: not VS Code-owned -- CFBundleIdentifier='${id:-<missing>}', no Code.app reference in document.wflow)"
        return 1
    fi
    # No Info.plist at all -> fall back to filename heuristic but log loudly.
    log_warn "Skip ${wf} (failure: missing Contents/Info.plist -- cannot verify ownership; will not delete on filename match alone)"
    return 1
}

verify_code_cli() {
    # verify_code_cli <abs path to candidate symlink/file>
    local c="$1"
    if [[ ! -L "$c" && ! -f "$c" ]]; then return 1; fi
    if [[ -L "$c" ]]; then
        # Resolve full chain. readlink -f is GNU-only; macOS readlink lacks -f
        # but `python3 -c 'os.path.realpath'` is always present on macOS 10.15+.
        local resolved=""
        if resolved="$(/usr/bin/python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$c" 2>/dev/null)"; then
            :
        else
            resolved="$(readlink "$c" 2>/dev/null || true)"
        fi
        if [[ -z "$resolved" ]]; then
            log_warn "Skip ${c} (failure: cannot resolve symlink target)"
            return 1
        fi
        # Canonical install path inside the bundle.
        if [[ "$resolved" == *"/Visual Studio Code.app/Contents/Resources/app/bin/code"* ]] \
           || [[ "$resolved" == *"/Code.app/Contents/Resources/app/bin/code"* ]] \
           || [[ "$resolved" == *"VSCode"*"/bin/code"* ]]; then
            log_debug "verify ok [code-cli] ${c} -> ${resolved}"
            return 0
        fi
        # Broken link (target does not exist) -- only accept if the dangling
        # path STILL points at a Code.app location, otherwise we refuse.
        if [[ ! -e "$resolved" ]]; then
            if [[ "$resolved" == *"Visual Studio Code.app"* ]] || [[ "$resolved" == *"VSCode"* ]]; then
                log_debug "verify ok [code-cli] ${c} (broken link, but target string references VS Code: ${resolved})"
                return 0
            fi
            log_warn "Skip ${c} (failure: broken symlink to non-VSCode target -> ${resolved})"
            return 1
        fi
        log_warn "Skip ${c} (failure: resolves to non-VSCode binary -> ${resolved})"
        return 1
    fi
    # Regular file (not a symlink) at /usr/local/bin/code etc. -- could be a
    # custom user script. Refuse unless its first 4KB explicitly mentions VS Code.
    if head -c 4096 "$c" 2>/dev/null | grep -qE 'Visual Studio Code|com\.microsoft\.VSCode|VSCODE_'; then
        log_debug "verify ok [code-cli] ${c} (regular file with VS Code marker)"
        return 0
    fi
    log_warn "Skip ${c} (failure: regular file with no VS Code markers in first 4KB -- refusing to delete)"
    return 1
}

verify_code_app() {
    # verify_code_app <abs path to .app bundle>
    local app="$1"
    [[ -d "$app" ]] || return 1
    local info="${app}/Contents/Info.plist"
    if [[ ! -f "$info" ]]; then
        log_warn "Skip ${app} (failure: missing Contents/Info.plist -- cannot verify bundle identity)"
        return 1
    fi
    local id; id="$(_pb 'Print :CFBundleIdentifier' "$info")"
    if _is_vscode_bundle_id "$id"; then
        log_debug "verify ok [launchservices] ${app} (bundle id: ${id})"
        return 0
    fi
    log_warn "Skip ${app} (failure: bundle id '${id:-<missing>}' is not com.microsoft.VSCode*)"
    return 1
}

verify_launch_agent() {
    # verify_launch_agent <abs path to .plist>
    local p="$1"
    [[ -f "$p" ]] || return 1
    local label prog args0
    label="$(_pb 'Print :Label'              "$p")"
    prog="$(_pb  'Print :Program'            "$p")"
    args0="$(_pb 'Print :ProgramArguments:0' "$p")"
    if _is_vscode_bundle_id "$label" \
       || [[ "$prog"  == *"Visual Studio Code.app"* ]] || [[ "$prog"  == *"VSCode"* ]] \
       || [[ "$args0" == *"Visual Studio Code.app"* ]] || [[ "$args0" == *"VSCode"* ]]; then
        log_debug "verify ok [loginitems] ${p} (label='${label}' program='${prog:-$args0}')"
        return 0
    fi
    log_warn "Skip ${p} (failure: plist not VS Code-owned -- Label='${label:-<missing>}' Program='${prog:-<missing>}' ProgramArguments[0]='${args0:-<missing>}')"
    return 1
}

# ---- planners (build the list of targets that WOULD be removed) -----------
# Each planner echoes one absolute target per line on stdout. Stderr is
# reserved for warnings (e.g. unreadable directory). No side effects.

plan_services() {
    # User-scope Services (Quick Actions / workflows)
    local d="${HOME}/Library/Services"
    if [[ -d "$d" ]]; then
        # Match common VS Code Service names. Use -iname so case differences
        # in user-installed workflows still match.
        local cand
        while IFS= read -r cand; do
            [[ -z "$cand" ]] && continue
            verify_workflow "$cand" && echo "$cand"
        done < <(find "$d" -maxdepth 1 -type d \( \
              -iname '*VSCode*.workflow' \
           -o -iname '*Visual Studio Code*.workflow' \
           -o -iname '*Open*Code*.workflow' \
        \) 2>/dev/null)
    else
        log_debug "Skip services plan: directory missing -> $d"
    fi
    # Machine-scope: only when root + writable.
    if [[ $is_root -eq 1 ]]; then
        local md="/Library/Services"
        if [[ -d "$md" && -w "$md" ]]; then
            local mcand
            while IFS= read -r mcand; do
                [[ -z "$mcand" ]] && continue
                verify_workflow "$mcand" && echo "$mcand"
            done < <(find "$md" -maxdepth 1 -type d \( \
                  -iname '*VSCode*.workflow' \
               -o -iname '*Visual Studio Code*.workflow' \
               -o -iname '*Open*Code*.workflow' \
            \) 2>/dev/null)
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
            verify_code_cli "$c" && echo "$c"
        fi
    done
}

plan_launchservices() {
    # Detect real Code.app bundles whose CFBundleIdentifier proves they are
    # Microsoft VS Code (NOT just any folder named "Visual Studio Code.app").
    local apps=(
        "/Applications/Visual Studio Code.app"
        "${HOME}/Applications/Visual Studio Code.app"
        "/Applications/Visual Studio Code - Insiders.app"
        "${HOME}/Applications/Visual Studio Code - Insiders.app"
    )
    local found=0
    for a in "${apps[@]}"; do
        if [[ -d "$a" ]] && verify_code_app "$a"; then
            echo "lsregister -u :: $a"
            found=1
        fi
    done
    if [[ $found -eq 0 ]]; then
        log_debug "Skip launchservices plan: no verified Code.app bundle found in standard locations"
    fi
}

plan_loginitems() {
    # 1) LaunchAgents plists referencing VS Code
    local d="${HOME}/Library/LaunchAgents"
    if [[ -d "$d" ]]; then
        local p
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            verify_launch_agent "$p" && echo "$p"
        done < <(find "$d" -maxdepth 1 -type f \( -iname '*vscode*.plist' -o -iname '*visual*studio*code*.plist' \) 2>/dev/null)
    fi
    if [[ $is_root -eq 1 && -d /Library/LaunchAgents && -w /Library/LaunchAgents ]]; then
        local mp
        while IFS= read -r mp; do
            [[ -z "$mp" ]] && continue
            verify_launch_agent "$mp" && echo "$mp"
        done < <(find /Library/LaunchAgents -maxdepth 1 -type f \( -iname '*vscode*.plist' -o -iname '*visual*studio*code*.plist' \) 2>/dev/null)
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
                if [[ "$it" == *"Visual Studio Code.app"* ]] || [[ "$it" == *"Visual Studio Code - Insiders.app"* ]]; then
                    echo "loginitem :: $it"
                elif [[ -n "$it" ]]; then
                    log_debug "Skip login item: ${it} (failure: path does not contain Visual Studio Code.app)"
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
# ---- post-cleanup verification --------------------------------------------
# Re-runs the SAME planners against the live system and reports anything
# the cleanup left behind. Surfaces are checked only when they were
# enabled for this run -- we never assert on a surface the operator
# excluded via --services / --code-cli / etc.
#
# Special case: launchservices. `lsregister -u` unregisters UTI/handler
# claims but leaves Code.app on disk -- the planner would still re-find
# the bundle. Verification therefore queries `lsregister -dump` for the
# bundle id and reports it as "remaining" only if it still appears in
# the LaunchServices database. If `lsregister` is unavailable, we fall
# back to a clear UNKNOWN line (never silent).

declare -a remaining_services_arr=() remaining_codecli_arr=() remaining_lsreg_arr=() remaining_login_arr=()
remaining_total=0
verify_unknown=0   # incremented when a check could not be performed

if [[ $do_services -eq 1 ]]; then
    mapfile -t remaining_services_arr < <(plan_services)
fi
if [[ $do_code_cli -eq 1 ]]; then
    mapfile -t remaining_codecli_arr < <(plan_code_cli)
fi
if [[ $do_loginitems -eq 1 ]]; then
    mapfile -t remaining_login_arr < <(plan_loginitems)
fi
if [[ $do_launchservices -eq 1 ]]; then
    # For each bundle that was in the original plan, query the
    # LaunchServices database to confirm its registrations are gone.
    lsreg_v="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [[ -x "$lsreg_v" ]]; then
        # `lsregister -dump` is slow; cache once.
        ls_dump="$("$lsreg_v" -dump 2>/dev/null || true)"
        for entry in "${plan_lsreg_arr[@]}"; do
            [[ -z "$entry" ]] && continue
            bundle="${entry#lsregister -u :: }"
            # Pull the bundle id from Info.plist (already verified earlier).
            id="$(_pb 'Print :CFBundleIdentifier' "${bundle}/Contents/Info.plist")"
            if [[ -z "$id" ]]; then
                log_warn "Verify launchservices: cannot read CFBundleIdentifier for ${bundle} (failure: PlistBuddy returned empty)"
                verify_unknown=$(( verify_unknown + 1 ))
                remaining_lsreg_arr+=("UNKNOWN :: ${bundle}")
                continue
            fi
            # Match `bundle id: <id>` AND `path: <bundle>` in the dump.
            if printf '%s' "$ls_dump" | grep -F -q "bundle id:        ${id}" 2>/dev/null \
               || printf '%s' "$ls_dump" | grep -F -q "${bundle}" 2>/dev/null; then
                remaining_lsreg_arr+=("${id} still registered :: ${bundle}")
            fi
        done
    else
        log_warn "Verify launchservices: lsregister not executable at ${lsreg_v} (failure: cannot query LaunchServices DB; cannot confirm unregistration)"
        verify_unknown=$(( verify_unknown + 1 ))
    fi
fi

remaining_total=$(( ${#remaining_services_arr[@]} + ${#remaining_codecli_arr[@]} + ${#remaining_lsreg_arr[@]} + ${#remaining_login_arr[@]} ))

echo ""
echo "============================================================"
echo " macOS VS Code integration cleanup -- VERIFY"
echo "============================================================"
printf "  remaining : %d entry(ies) on enabled surfaces\n" "$remaining_total"
printf "  unknown   : %d check(s) could not be performed\n"  "$verify_unknown"
echo "------------------------------------------------------------"

_print_verify_group() {
    local title="$1"; shift
    local enabled="$1"; shift
    local -a items=("$@")
    if [[ "$enabled" -eq 0 ]]; then
        printf "  %-16s : (skipped -- surface not selected)\n" "$title"
        return
    fi
    if [[ ${#items[@]} -eq 0 || ( ${#items[@]} -eq 1 && -z "${items[0]}" ) ]]; then
        printf "  %-16s : OK (none remaining)\n" "$title"
    else
        printf "  %-16s : %d remaining\n" "$title" "${#items[@]}"
        for it in "${items[@]}"; do
            [[ -z "$it" ]] && continue
            printf "      ! %s\n" "$it"
            audit_event "remaining" "${title,,}" "$it" "post-cleanup re-check found this entry"
        done
    fi
}

_print_verify_group "Services"          "$do_services"       "${remaining_services_arr[@]}"
_print_verify_group "code CLI symlink"  "$do_code_cli"       "${remaining_codecli_arr[@]}"
_print_verify_group "LaunchServices"    "$do_launchservices" "${remaining_lsreg_arr[@]}"
_print_verify_group "Login items"       "$do_loginitems"     "${remaining_login_arr[@]}"
echo "============================================================"

audit_event "verify-end" "all" "" "remaining=${remaining_total} unknown=${verify_unknown}"

echo ""
echo "============================================================"
echo " macOS VS Code integration cleanup -- SUMMARY"
echo "============================================================"
printf "  removed : %d\n" "$removed_count"
printf "  failed  : %d\n" "$fail_count"
printf "  remaining (post-cleanup verify) : %d\n" "$remaining_total"
printf "  verify-unknown                  : %d\n" "$verify_unknown"
printf "  audit   : %s\n" "${audit_path:-<disabled>}"
echo "============================================================"
audit_event "session-end" "all" "" "removed=${removed_count} failed=${fail_count}"

if [[ $fail_count -gt 0 ]] || [[ $remaining_total -gt 0 ]]; then
    if [[ $remaining_total -gt 0 ]]; then
        log_warn "Post-cleanup verification found ${remaining_total} remaining entry(ies). See VERIFY block above + audit log for exact paths."
    fi
    if [[ $fail_count -gt 0 ]]; then
    log_warn "Completed with ${fail_count} failure(s). Review the audit log above for exact paths + reasons."
    fi
    exit 3
fi
if [[ $verify_unknown -gt 0 ]]; then
    log_warn "Post-cleanup verification completed with ${verify_unknown} check(s) marked UNKNOWN. Cleanup itself succeeded -- but at least one surface could not be re-checked. See VERIFY block above."
fi
exit 0