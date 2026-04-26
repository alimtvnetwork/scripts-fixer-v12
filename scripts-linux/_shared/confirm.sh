#!/usr/bin/env bash
# _shared/confirm.sh -- plan-then-confirm helper used by destructive
# cleanup scripts (65 os-clean, 66 vscode-mac-clean, 67 vscode-cleanup-linux).
#
# Workflow:
#   1. The caller writes one row per planned deletion to a TSV file with
#      the schema:  <bucket>\t<kind>\t<target>\t<detail>
#      where <bucket> is whatever grouping label the caller wants on the
#      tree view (method id for 67, category id for 65/66).
#   2. The caller invokes:
#        confirm_render_plan <plan-tsv> <title>
#        confirm_prompt      <plan-tsv> <assume_yes_flag>
#      Render prints a tree-grouped view AND a flat table to stderr.
#      Prompt reads from /dev/tty and returns 0 on yes, 1 on no.
#   3. If $assume_yes_flag is 1 the prompt is skipped (CI / scripted use).
#   4. If the plan is empty, the prompt is skipped and 0 is returned (no-op).
#
# CODE RED: every file/path error logs the exact path + reason via
# log_file_error so failures are traceable.

# Render the plan as both a grouped tree AND a flat aligned table.
# Args:  <plan-tsv> <title>
confirm_render_plan() {
  local tsv="$1" title="${2:-Planned removals}"
  if [ ! -f "$tsv" ]; then
    log_file_error "$tsv" "plan TSV missing -- nothing to render"
    return 1
  fi
  local total
  total=$(grep -c . "$tsv" 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    printf '\n  %s: nothing to remove (plan is empty).\n\n' "$title" >&2
    return 0
  fi

  # ---------- TREE view (grouped by bucket) -------------------------------
  printf '\n  ===== %s (%d item%s) =====\n' \
    "$title" "$total" "$([ "$total" -eq 1 ] && echo "" || echo s)" >&2
  local bucket prev_bucket="" bucket_count=0
  local kind target detail
  # Sort by bucket so grouping works regardless of insertion order.
  while IFS=$'\t' read -r bucket kind target detail; do
    [ -z "$bucket" ] && continue
    if [ "$bucket" != "$prev_bucket" ]; then
      if [ -n "$prev_bucket" ]; then
        printf '       (%d item%s in this group)\n' "$bucket_count" \
          "$([ "$bucket_count" -eq 1 ] && echo "" || echo s)" >&2
      fi
      printf '\n  [%s]\n' "$bucket" >&2
      prev_bucket="$bucket"
      bucket_count=0
    fi
    bucket_count=$((bucket_count + 1))
    printf '       - %-12s %s\n' "$kind" "$target" >&2
  done < <(sort -t $'\t' -k1,1 "$tsv")
  if [ -n "$prev_bucket" ]; then
    printf '       (%d item%s in this group)\n' "$bucket_count" \
      "$([ "$bucket_count" -eq 1 ] && echo "" || echo s)" >&2
  fi

  # ---------- TABLE view (flat) -------------------------------------------
  printf '\n  ----- flat table -----\n' >&2
  printf '  %-16s  %-12s  %s\n' "GROUP" "KIND" "TARGET" >&2
  printf '  %s\n' "$(printf '%.0s-' {1..90})" >&2
  while IFS=$'\t' read -r bucket kind target detail; do
    [ -z "$bucket" ] && continue
    printf '  %-16s  %-12s  %s\n' "$bucket" "$kind" "$target" >&2
  done < "$tsv"
  printf '  %s\n' "$(printf '%.0s-' {1..90})" >&2
  printf '  TOTAL: %d item%s queued for removal.\n\n' \
    "$total" "$([ "$total" -eq 1 ] && echo "" || echo s)" >&2
  return 0
}

# Prompt the operator. Returns 0 on yes, 1 on no/abort.
# Args:  <plan-tsv> <assume_yes_flag>
confirm_prompt() {
  local tsv="$1" assume_yes="${2:-0}"
  if [ ! -f "$tsv" ]; then
    log_file_error "$tsv" "plan TSV missing -- treating as empty plan"
    return 0
  fi
  local total
  total=$(grep -c . "$tsv" 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    log_info "Plan is empty -- nothing to confirm."
    return 0
  fi
  if [ "$assume_yes" = "1" ]; then
    log_info "Confirmation skipped: --yes / -y supplied (apply $total item(s))."
    return 0
  fi
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    log_warn "No TTY available for confirmation prompt and --yes was not passed."
    log_warn "Aborting to avoid an unattended destructive run. Re-run with --yes for non-interactive use, or --dry-run to preview only."
    return 1
  fi
  printf "  Type 'yes' to apply the %d planned removal(s), anything else to abort: " "$total" >&2
  local reply=""
  if [ -r /dev/tty ]; then
    IFS= read -r reply </dev/tty || reply=""
  else
    IFS= read -r reply || reply=""
  fi
  case "$reply" in
    y|Y|yes|YES|Yes)
      log_ok "Confirmed -- proceeding with apply."
      return 0 ;;
    *)
      log_warn "Aborted by operator (reply='$reply'). No changes made."
      return 1 ;;
  esac
}

# Convenience: append one row to the plan TSV.
# Args: <plan-tsv> <bucket> <kind> <target> [<detail>]
confirm_plan_add() {
  local tsv="$1" bucket="$2" kind="$3" target="$4" detail="${5:-}"
  printf '%s\t%s\t%s\t%s\n' "$bucket" "$kind" "$target" "$detail" >> "$tsv" \
    || log_file_error "$tsv" "failed to append plan row (bucket=$bucket kind=$kind target=$target)"
}