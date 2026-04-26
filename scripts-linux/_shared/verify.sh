#!/usr/bin/env bash
# _shared/verify.sh -- post-cleanup verification helper.
#
# After a destructive run (scripts 65 / 66 / 67), call verify_run with the
# rows TSV the script just produced. For every row that the run claims it
# REMOVED (or that it WOULD have removed in dry-run), this helper re-probes
# the underlying target (file, dir, symlink, package, snap, login-item, or
# launchctl plist) and emits one verification row per check:
#
#   <result>\t<bucket>\t<kind>\t<target>\t<probe-detail>
#
# where <result> is one of:
#   pass       -- target is gone (verification confirms removal)
#   fail       -- target STILL EXISTS (cleanup did not work)
#   skip-dryrun-> the run was a dry-run; nothing was removed, verification skipped
#   skip-failed-> the row was already 'failed' or 'skipped'; nothing to verify
#   skip-other -> the row's kind is not verifiable on this host
#
# Then verify_render prints a clear pass/fail report (table + summary). The
# manifest writer in each script reads $VERIFY_TSV and embeds the rows under
# manifest.verification.{rows,totals}.
#
# Why a separate helper? Cleanup helpers themselves can lie (e.g. apt-get
# returns 0 even when a package's file is left behind by a postrm script).
# An independent re-probe gives the operator a second-source confirmation,
# and the pass/fail report is the user-visible "did it actually work?" line.
#
# CODE RED: every file/path failure logs the exact path + reason via
# log_file_error so verification failures are traceable.

: "${VERIFY_TSV:=/tmp/cleanup-verify.tsv}"

# Internal: append a verification row.
# Args: <result> <bucket> <kind> <target> <detail>
_verify_emit() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$VERIFY_TSV" \
    || log_file_error "$VERIFY_TSV" "failed to append verification row (result=$1 target=$4)"
}

# Probe a single target. Returns 0 = gone (pass), 1 = present (fail),
# 2 = unverifiable on this host. Echoes a probe-detail string on stdout.
# Args: <kind> <target>
verify_probe_target() {
  local kind="$1" target="$2"

  # Path-shaped kinds: re-check filesystem.
  case "$kind" in
    rm-file|rm-shim|shim|workflow|rm-dir|launchctl)
      if [ -e "$target" ] || [ -L "$target" ]; then
        local detail="exists"
        if   [ -L "$target" ]; then detail="symlink -> $(readlink "$target" 2>/dev/null || echo '?')"
        elif [ -d "$target" ]; then detail="directory still on disk"
        elif [ -f "$target" ]; then detail="regular file still on disk"
        fi
        printf '%s' "$detail"
        return 1
      fi
      printf 'absent on filesystem'
      return 0
      ;;
  esac

  # Package-shaped kinds: re-query package manager.
  case "$kind" in
    apt-purge|dpkg-remove)
      if ! command -v dpkg >/dev/null 2>&1; then
        printf 'dpkg not on PATH; cannot verify'
        return 2
      fi
      if dpkg -s "$target" >/dev/null 2>&1; then
        local ver
        ver=$(dpkg-query -W -f='${Version}' "$target" 2>/dev/null || echo unknown)
        printf 'dpkg still reports installed (version=%s)' "$ver"
        return 1
      fi
      printf 'dpkg reports not installed'
      return 0
      ;;
    snap-remove)
      if ! command -v snap >/dev/null 2>&1; then
        printf 'snap not on PATH; cannot verify'
        return 2
      fi
      if snap list "$target" >/dev/null 2>&1; then
        printf 'snap list still reports installed'
        return 1
      fi
      printf 'snap reports not installed'
      return 0
      ;;
  esac

  # Login-items: query System Events (macOS only).
  if [ "$kind" = "loginitem" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
      printf 'osascript not on PATH; cannot verify'
      return 2
    fi
    local found
    found=$(osascript -e "tell application \"System Events\" to get name of every login item whose name is \"$target\"" 2>/dev/null || true)
    if [ -n "$found" ]; then
      printf 'login item still present (name=%s)' "$found"
      return 1
    fi
    printf 'no login item with this name'
    return 0
  fi

  # LaunchServices URL handlers: re-dump and grep for the bundle/path.
  if [ "$kind" = "lsregister" ]; then
    local lsr="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [ ! -x "$lsr" ]; then
      printf 'lsregister missing at expected path; cannot verify'
      return 2
    fi
    if "$lsr" -dump 2>/dev/null | grep -Fq -- "$target"; then
      printf 'lsregister -dump still references this app path'
      return 1
    fi
    printf 'lsregister -dump no longer references this path'
    return 0
  fi

  # apt-update / informational kinds: nothing to re-probe.
  case "$kind" in
    apt-update|filter|sudo|mode|dir)
      printf 'kind=%s is informational; no re-probe defined' "$kind"
      return 2 ;;
  esac

  printf 'kind=%s has no verifier; treated as unverifiable' "$kind"
  return 2
}

# Run verification over a rows TSV produced by a destructive script.
# Args: <rows-tsv> <verify-tsv> <mode-label>
#   rows-tsv schema:    <status>\t<bucket>\t<kind>\t<target>\t<detail>
#   mode-label:         "apply" | "dry-run" | "aborted"
# Writes one verification row per processed input row to $VERIFY_TSV.
# Returns the number of FAIL rows via the global $VERIFY_FAILS (so the
# caller can decide exit code without re-parsing the file).
verify_run() {
  local rows="$1" out="$2" mode="$3"
  VERIFY_TSV="$out"
  if [ ! -f "$rows" ]; then
    log_file_error "$rows" "rows TSV missing -- cannot verify"
    VERIFY_FAILS=0; VERIFY_PASSES=0; VERIFY_SKIPS=0
    return 1
  fi
  : > "$VERIFY_TSV" || log_file_error "$VERIFY_TSV" "failed to truncate verify TSV"

  local passes=0 fails=0 skips=0
  local status bucket kind target detail
  local probe_rc probe_detail

  while IFS=$'\t' read -r status bucket kind target detail; do
    [ -z "$status" ] && continue

    # Verify only rows that claim a removal happened (apply: 'removed';
    # dry-run: 'would' so the operator sees the would-be result).
    case "$status" in
      removed)
        : ;;
      would)
        if [ "$mode" = "dry-run" ]; then
          _verify_emit "skip-dryrun" "$bucket" "$kind" "$target" "dry-run: nothing was actually removed"
          skips=$((skips+1))
          continue
        fi
        # In apply mode a 'would' row is a logic bug; verify anyway.
        ;;
      missing)
        # Already absent before the run -- still treat as pass (target is gone).
        probe_detail=$(verify_probe_target "$kind" "$target") ; probe_rc=$?
        if [ "$probe_rc" -eq 0 ]; then
          _verify_emit "pass" "$bucket" "$kind" "$target" "was already absent: $probe_detail"
          passes=$((passes+1))
        elif [ "$probe_rc" -eq 1 ]; then
          _verify_emit "fail" "$bucket" "$kind" "$target" "was reported missing but probe says: $probe_detail"
          fails=$((fails+1))
        else
          _verify_emit "skip-other" "$bucket" "$kind" "$target" "$probe_detail"
          skips=$((skips+1))
        fi
        continue ;;
      failed|skipped)
        _verify_emit "skip-failed" "$bucket" "$kind" "$target" "row was '$status' in apply phase: $detail"
        skips=$((skips+1))
        continue ;;
      *)
        _verify_emit "skip-other" "$bucket" "$kind" "$target" "unknown row status '$status'"
        skips=$((skips+1))
        continue ;;
    esac

    probe_detail=$(verify_probe_target "$kind" "$target") ; probe_rc=$?
    case "$probe_rc" in
      0) _verify_emit "pass" "$bucket" "$kind" "$target" "$probe_detail"; passes=$((passes+1)) ;;
      1)
        _verify_emit "fail" "$bucket" "$kind" "$target" "$probe_detail"
        log_file_error "$target" "post-cleanup verification FAILED ($kind): $probe_detail"
        fails=$((fails+1)) ;;
      *) _verify_emit "skip-other" "$bucket" "$kind" "$target" "$probe_detail"; skips=$((skips+1)) ;;
    esac
  done < "$rows"

  VERIFY_PASSES="$passes"
  VERIFY_FAILS="$fails"
  VERIFY_SKIPS="$skips"
  return 0
}

# Render the verification report to stderr.
# Args: <verify-tsv> <title>
verify_render() {
  local tsv="$1" title="${2:-Cleanup verification}"
  if [ ! -f "$tsv" ]; then
    log_file_error "$tsv" "verify TSV missing -- cannot render report"
    return 1
  fi
  local total
  total=$(grep -c . "$tsv" 2>/dev/null || echo 0)
  printf '\n  ===== %s =====\n' "$title" >&2
  if [ "$total" -eq 0 ]; then
    printf '  (no removal rows to verify -- nothing was applied this run)\n\n' >&2
    return 0
  fi

  printf '  %-12s  %-16s  %-12s  %s\n' "RESULT" "BUCKET" "KIND" "TARGET (probe-detail)" >&2
  printf '  %s\n' "$(printf '%.0s-' {1..100})" >&2

  local result bucket kind target detail
  while IFS=$'\t' read -r result bucket kind target detail; do
    [ -z "$result" ] && continue
    printf '  %-12s  %-16s  %-12s  %s  (%s)\n' \
      "$result" "$bucket" "$kind" "$target" "$detail" >&2
  done < "$tsv"
  printf '  %s\n' "$(printf '%.0s-' {1..100})" >&2

  local p="${VERIFY_PASSES:-0}" f="${VERIFY_FAILS:-0}" s="${VERIFY_SKIPS:-0}"
  printf '  TOTALS: pass=%d  fail=%d  skipped=%d  (of %d rows checked)\n' \
    "$p" "$f" "$s" "$total" >&2
  if [ "$f" -gt 0 ]; then
    printf '\n  VERIFICATION VERDICT: ❌ FAIL -- %d target(s) still present after cleanup. See FILE-ERROR lines above for paths.\n\n' "$f" >&2
  else
    printf '\n  VERIFICATION VERDICT: ✅ PASS -- every checked target is gone.\n\n' >&2
  fi
  return 0
}
