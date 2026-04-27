#!/usr/bin/env bash
# 68-user-mgmt/helpers/_manifest_prune.sh -- v0.181.0
#
# Retention-based cleanup of ssh-key rollback manifests written by
# add-user.sh / add-user-from-json.sh (see feature memory
# .lovable/memory/features/17-script-68-ssh-key-rollback.md).
#
# Sourced by:
#   - remove-ssh-keys.sh   (--prune verb, operator-driven retention pass)
#   - add-user.sh          (best-effort auto-prune after a manifest write
#                           so the dir self-maintains and never grows
#                           unboundedly between operator visits)
#
# CODE RED:
#   - Every file delete logs the exact path + reason.
#   - Every parse / scan failure logs the exact path + reason.
#   - Auto-prune NEVER fails the calling script: errors are warned and
#     the caller continues. The operator can always re-run
#     `remove-ssh-keys.sh --prune` manually to retry.
#
# Inputs (env vars or args):
#   UM_PRUNE_DIR              manifest dir (default: $UM_MANIFEST_DIR or
#                             /var/lib/68-user-mgmt/ssh-key-runs)
#   UM_PRUNE_OLDER_THAN_DAYS  delete manifests older than N days (0 = off)
#   UM_PRUNE_KEEP_LAST        keep only the most recent N PER USER (0 = off)
#   UM_PRUNE_MAX_TOTAL        cap total manifests in dir; oldest evicted (0 = off)
#   UM_PRUNE_DRY_RUN          1 = report only, never delete
#   UM_PRUNE_QUIET            1 = suppress per-candidate info lines (still
#                             logs the summary + failures); used by
#                             auto-prune so the install log stays calm.
#
# Returns 0 on success even when nothing matched. Returns non-zero only
# when scanning the dir itself failed (CODE RED file error already logged).

# A manifest is removable if it matches ANY enabled policy (OR-combined).
# `keepLastPerUser` and `maxTotal` are evaluated AFTER `olderThanDays` so
# the kept set already excludes stale files -- this keeps the math
# intuitive ("keep the 20 most recent NON-stale ones per user").
um_manifest_prune() {
    local dir="${UM_PRUNE_DIR:-${UM_MANIFEST_DIR:-/var/lib/68-user-mgmt/ssh-key-runs}}"
    local older_days="${UM_PRUNE_OLDER_THAN_DAYS:-0}"
    local keep_last="${UM_PRUNE_KEEP_LAST:-0}"
    local max_total="${UM_PRUNE_MAX_TOTAL:-0}"
    local dry_run="${UM_PRUNE_DRY_RUN:-0}"
    local quiet="${UM_PRUNE_QUIET:-0}"

    # Sanity: numeric, non-negative
    case "$older_days$keep_last$max_total" in
        *[!0-9]*)
            log_err "manifest prune: non-numeric policy values (olderThanDays='$older_days' keepLastPerUser='$keep_last' maxTotal='$max_total') -- aborting prune to avoid surprise deletions"
            return 2 ;;
    esac

    if [ "$quiet" != "1" ]; then
        log_info "$(um_msg manifestPruneHeader "$dir" "$older_days" "$keep_last" "$max_total" "$dry_run")"
    fi

    if [ ! -d "$dir" ]; then
        # Not an error: nothing to prune. Auto-prune hits this on first run.
        if [ "$quiet" != "1" ]; then
            log_info "$(um_msg manifestListEmpty "$dir")"
        fi
        return 0
    fi

    # Collect candidate files. Use a glob (manifests are *.json by spec).
    shopt -s nullglob
    local files=("$dir"/*.json)
    shopt -u nullglob
    local total=${#files[@]}
    if [ "$total" -eq 0 ]; then
        if [ "$quiet" != "1" ]; then
            log_info "$(um_msg manifestPruneNothing "$dir")"
        fi
        return 0
    fi

    # Build a TSV index: epoch_mtime \t path \t user \t age_days
    # mtime is the source of truth for "age" -- writtenAt inside the JSON
    # could drift if the manifest was hand-edited, but mtime survives the
    # mv-from-tmp step in _um_write_manifest so it's accurate.
    local now_epoch
    now_epoch=$(date -u +%s 2>/dev/null) || now_epoch=0
    local idx
    idx=$(mktemp -t 68-prune-idx.XXXXXX) || {
        log_err "$(um_msg manifestPruneScanFail "$dir" "mktemp failed")"
        return 2
    }

    local f mtime user age
    local n_skipped=0
    for f in "${files[@]}"; do
        # mtime: GNU stat first, BSD/macOS fallback.
        mtime=$(stat -c %Y "$f" 2>/dev/null) \
            || mtime=$(stat -f %m "$f" 2>/dev/null) \
            || mtime=""
        if [ -z "$mtime" ]; then
            log_warn "$(um_msg manifestPruneSkipParse "$f" "could not stat() mtime")"
            n_skipped=$((n_skipped+1))
            continue
        fi
        # Pull user from the JSON. If JSON is unparseable we SKIP (do NOT
        # delete) -- a corrupt manifest may still be needed for forensics.
        if command -v jq >/dev/null 2>&1; then
            if ! user=$(jq -re '.user // empty' "$f" 2>/dev/null); then
                log_warn "$(um_msg manifestPruneSkipParse "$f" "jq could not extract .user")"
                n_skipped=$((n_skipped+1))
                continue
            fi
        else
            # Fall back to the filename convention: <run-id>__<user>.json
            user=$(basename "$f" .json)
            user="${user##*__}"
            [ -z "$user" ] && user="(unknown)"
        fi
        if [ "$now_epoch" -gt 0 ]; then
            age=$(( (now_epoch - mtime) / 86400 ))
        else
            age=0
        fi
        printf '%s\t%s\t%s\t%s\n' "$mtime" "$f" "$user" "$age" >> "$idx"
    done

    # Sort newest-first so "keep last N per user" is easy.
    local sorted
    sorted=$(mktemp -t 68-prune-sort.XXXXXX) || {
        rm -f "$idx"
        log_err "$(um_msg manifestPruneScanFail "$dir" "mktemp(sorted) failed")"
        return 2
    }
    sort -nr -k1,1 "$idx" > "$sorted"

    # Decide each file's fate.
    declare -A per_user_kept=()
    local kept_total=0
    local plan
    plan=$(mktemp -t 68-prune-plan.XXXXXX) || {
        rm -f "$idx" "$sorted"
        log_err "$(um_msg manifestPruneScanFail "$dir" "mktemp(plan) failed")"
        return 2
    }

    local mt path usr ag reason
    while IFS=$'\t' read -r mt path usr ag; do
        reason=""
        # Policy 1: olderThanDays
        if [ "$older_days" -gt 0 ] && [ "$ag" -ge "$older_days" ]; then
            reason="age>=${older_days}d"
        fi
        # Policy 2: keepLastPerUser (only count NON-stale files toward kept)
        if [ -z "$reason" ] && [ "$keep_last" -gt 0 ]; then
            local cnt="${per_user_kept[$usr]:-0}"
            if [ "$cnt" -ge "$keep_last" ]; then
                reason="user-rotation>=${keep_last}"
            fi
        fi
        # Policy 3: maxTotal -- only counts files we are otherwise keeping.
        if [ -z "$reason" ] && [ "$max_total" -gt 0 ] && [ "$kept_total" -ge "$max_total" ]; then
            reason="dir-cap>=${max_total}"
        fi

        if [ -n "$reason" ]; then
            printf 'REMOVE\t%s\t%s\t%s\t%s\n' "$path" "$usr" "$ag" "$reason" >> "$plan"
        else
            printf 'KEEP\t%s\t%s\t%s\n' "$path" "$usr" "$ag" >> "$plan"
            per_user_kept[$usr]=$(( ${per_user_kept[$usr]:-0} + 1 ))
            kept_total=$((kept_total+1))
        fi
    done < "$sorted"

    # Execute the plan.
    local n_kept=0 n_removed=0 n_failed=0
    local action rest
    while IFS=$'\t' read -r action rest; do
        case "$action" in
            KEEP)
                n_kept=$((n_kept+1))
                ;;
            REMOVE)
                IFS=$'\t' read -r path usr ag reason <<<"$rest"
                if [ "$quiet" != "1" ]; then
                    log_info "$(um_msg manifestPruneCandidate "$path" "$usr" "$ag" "$reason")"
                fi
                if [ "$dry_run" = "1" ]; then
                    n_removed=$((n_removed+1))
                    log_info "$(um_msg manifestPruneRemoved "$path" "$reason" "1")"
                else
                    if rm -f "$path" 2>/dev/null; then
                        n_removed=$((n_removed+1))
                        log_ok "$(um_msg manifestPruneRemoved "$path" "$reason" "0")"
                    else
                        n_failed=$((n_failed+1))
                        # CODE RED: exact path + reason. We use $? + a stat
                        # probe so the message tells the operator whether
                        # this was permission, mount-ro, or already-gone.
                        local why="rm failed (rc=$?)"
                        [ ! -e "$path" ] && why="file vanished mid-prune (race condition?)"
                        [ -e "$path" ] && [ ! -w "$dir" ] && why="manifest dir '$dir' not writable by current user (need sudo)"
                        log_file_error "$path" "$(um_msg manifestPruneRemoveFail "$path" "$why" | sed 's/^[[:alpha:]]*: //')"
                    fi
                fi
                ;;
        esac
    done < "$plan"

    log_info "$(um_msg manifestPruneSummary "$total" "$n_kept" "$n_removed" "$n_failed" "$n_skipped" "$dir" "$dry_run")"

    rm -f "$idx" "$sorted" "$plan"
    if [ "$n_failed" -gt 0 ]; then
        return 1
    fi
    return 0
}