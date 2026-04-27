#!/usr/bin/env bash
# 68-user-mgmt/remove-ssh-keys.sh -- roll back ssh keys installed by a
# tracked add-user.sh / add-user-from-json.sh run.
#
# Reads the per-run manifest written by add-user.sh under
# /var/lib/68-user-mgmt/ssh-key-runs/<run-id>__<user>.json, finds each
# tracked key in the user's authorized_keys (by fingerprint, with a
# literal-line fallback), and removes ONLY those lines. Pre-existing
# keys, manually-added keys, and keys from OTHER tracked runs are left
# alone.
#
# Usage:
#   ./remove-ssh-keys.sh --list
#   ./remove-ssh-keys.sh --run-id <id> [--dry-run] [--manifest-dir DIR]
#                                      [--keep-manifest]
#   ./remove-ssh-keys.sh --manifest <path> [--dry-run] [--keep-manifest]
#   ./remove-ssh-keys.sh --prune [--older-than DAYS] [--keep-last N]
#                                [--max-total N] [--dry-run]
#                                [--manifest-dir DIR]
#
# Exit codes:
#   0  success (or dry-run completed cleanly)
#   2  manifest / file path error (CODE RED -- exact path logged)
#  64  bad CLI usage
# 127  required tool (jq) missing

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"
. "$SCRIPT_DIR/helpers/_manifest_prune.sh"

um_usage() {
  cat <<EOF
# revoke-key -- remove keys by --fingerprint, --comment, --key, or --all;
# see readme.md "SSH key lifecycle" for the cross-OS contract.
Usage:
  remove-ssh-keys.sh --list [--manifest-dir DIR]
      Show every tracked run on this host (run-id, timestamp, user, key
      count, source). Read-only, never edits anything.

  remove-ssh-keys.sh --run-id <id> [--dry-run] [--manifest-dir DIR]
                                   [--keep-manifest]
      Roll back every key installed under <id>. If the run touched
      multiple users, all of their authorized_keys files are processed.

  remove-ssh-keys.sh --manifest <path> [--dry-run] [--keep-manifest]
      Roll back from a specific manifest file (useful when the manifest
      lives outside the default dir, e.g. on a backup volume).

  remove-ssh-keys.sh --prune [--older-than DAYS] [--keep-last N]
                              [--max-total N] [--dry-run]
                              [--manifest-dir DIR]
      Retention-based cleanup of the manifest dir. All three policies
      are OR-combined; pass 0 to disable a specific one. Defaults come
      from config.json (manifestRetention.*).
        --older-than DAYS    delete manifests with mtime older than DAYS
        --keep-last N        keep only the N most recent PER USER
        --max-total N        cap the total file count in the dir
      Corrupt manifests are SKIPPED, never deleted (forensics preserved).

Options:
  --dry-run         Show what would be removed; touch nothing.
  --keep-manifest   Do NOT delete the manifest after a successful
                    rollback. By default the manifest is removed so
                    --list stays accurate.
  --manifest-dir D  Override the default manifest dir
                    (/var/lib/68-user-mgmt/ssh-key-runs).

Safety:
  - authorized_keys is backed up to <file>.bak.<timestamp> before edit.
  - Keys are matched by fingerprint first, literal line second. Keys
    not found in authorized_keys are reported as "already missing"
    (warning, not error -- safe to re-run).
  - Pre-existing or hand-added keys are NEVER touched.
EOF
}

UM_DRY_RUN="${UM_DRY_RUN:-0}"
UM_MANIFEST_DIR="${UM_MANIFEST_DIR:-/var/lib/68-user-mgmt/ssh-key-runs}"
UM_RUN_ID=""
UM_MANIFEST_PATH=""
UM_LIST=0
UM_KEEP_MANIFEST=0
UM_PRUNE=0
# Empty = "use config.json default". Numeric = explicit override.
UM_PRUNE_OLDER_THAN_DAYS_CLI=""
UM_PRUNE_KEEP_LAST_CLI=""
UM_PRUNE_MAX_TOTAL_CLI=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)        um_usage; exit 0 ;;
    --list)           UM_LIST=1; shift ;;
    --prune)          UM_PRUNE=1; shift ;;
    --older-than)     UM_PRUNE_OLDER_THAN_DAYS_CLI="${2:-}"; shift 2 ;;
    --keep-last)      UM_PRUNE_KEEP_LAST_CLI="${2:-}"; shift 2 ;;
    --max-total)      UM_PRUNE_MAX_TOTAL_CLI="${2:-}"; shift 2 ;;
    --run-id)         UM_RUN_ID="${2:-}"; shift 2 ;;
    --manifest)       UM_MANIFEST_PATH="${2:-}"; shift 2 ;;
    --manifest-dir)   UM_MANIFEST_DIR="${2:-}"; shift 2 ;;
    --dry-run)        UM_DRY_RUN=1; shift ;;
    --keep-manifest)  UM_KEEP_MANIFEST=1; shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1' (failure: see --help)"; exit 64 ;;
    *)  log_err "unexpected positional: '$1' (failure: nothing positional accepted)"; exit 64 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  log_err "$(um_msg missingTool "jq")"
  exit 127
fi

um_detect_os || exit $?

# ---- helpers ---------------------------------------------------------------

# _fp_of_line <key-line>  -> echoes "SHA256:..." or "literal-only".
# Mirrors the fingerprinter in add-user.sh so manifest entries match.
_fp_of_line() {
    local line="$1" fp=""
    if command -v ssh-keygen >/dev/null 2>&1; then
        fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$fp" ] && command -v sha256sum >/dev/null 2>&1; then
        fp="sha256:"$(printf '%s' "$line" | sha256sum | awk '{print $1}')
    fi
    [ -z "$fp" ] && fp="literal-only"
    printf '%s' "$fp"
}

# ---- --prune mode ----------------------------------------------------------
# Resolves policy from CLI overrides on top of config.json defaults, then
# delegates to um_manifest_prune (helpers/_manifest_prune.sh). Needs root
# to actually delete manifests (dir is 0700 root); dry-run runs unprivileged.
if [ "$UM_PRUNE" = "1" ]; then
  cfg="$SCRIPT_DIR/config.json"
  cfg_older=90
  cfg_keep=20
  cfg_max=500
  if [ -r "$cfg" ]; then
    cfg_older=$(jq -r '.manifestRetention.olderThanDays   // 90'  "$cfg" 2>/dev/null) || cfg_older=90
    cfg_keep=$( jq -r '.manifestRetention.keepLastPerUser // 20'  "$cfg" 2>/dev/null) || cfg_keep=20
    cfg_max=$(  jq -r '.manifestRetention.maxTotal        // 500' "$cfg" 2>/dev/null) || cfg_max=500
  else
    log_warn "config.json not readable at '$cfg' (failure: using built-in defaults olderThanDays=90 keepLastPerUser=20 maxTotal=500)"
  fi

  export UM_PRUNE_DIR="$UM_MANIFEST_DIR"
  export UM_PRUNE_OLDER_THAN_DAYS="${UM_PRUNE_OLDER_THAN_DAYS_CLI:-$cfg_older}"
  export UM_PRUNE_KEEP_LAST="${UM_PRUNE_KEEP_LAST_CLI:-$cfg_keep}"
  export UM_PRUNE_MAX_TOTAL="${UM_PRUNE_MAX_TOTAL_CLI:-$cfg_max}"
  export UM_PRUNE_DRY_RUN="$UM_DRY_RUN"
  export UM_PRUNE_QUIET=0

  if [ "$UM_DRY_RUN" != "1" ]; then um_require_root || exit $?; fi
  if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi
  um_manifest_prune
  exit $?
fi

# ---- --list mode -----------------------------------------------------------
if [ "$UM_LIST" = "1" ]; then
  if [ ! -d "$UM_MANIFEST_DIR" ]; then
    log_warn "$(um_msg manifestListEmpty "$UM_MANIFEST_DIR")"
    exit 0
  fi
  shopt -s nullglob
  files=("$UM_MANIFEST_DIR"/*.json)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    log_warn "$(um_msg manifestListEmpty "$UM_MANIFEST_DIR")"
    exit 0
  fi
  log_info "$(um_msg manifestListHeader "$UM_MANIFEST_DIR")"
  # Sort for stable output regardless of FS readdir order.
  IFS=$'\n' files_sorted=($(printf '%s\n' "${files[@]}" | sort))
  unset IFS
  for mf in "${files_sorted[@]}"; do
    if ! jq -e . "$mf" >/dev/null 2>&1; then
      log_warn "$(um_msg manifestParseFail "$mf" "skipped in list output")"
      continue
    fi
    rid=$(jq  -r '.runId        // "?"' "$mf")
    when=$(jq -r '.writtenAt    // "?"' "$mf")
    usr=$(jq  -r '.user         // "?"' "$mf")
    nkeys=$(jq -r '.keys | length' "$mf")
    # Source summary: "github + 1 file" style.
    srcs=$(jq -r '[.keys[].source] | unique | join(",")' "$mf")
    log_info "$(um_msg manifestListRow "$rid" "$when" "$usr" "$nkeys" "$srcs")"
  done
  exit 0
fi

# ---- resolve manifest paths ------------------------------------------------
if [ -z "$UM_RUN_ID" ] && [ -z "$UM_MANIFEST_PATH" ]; then
  log_err "must pass exactly one of --list / --run-id / --manifest (failure: nothing to do)"
  um_usage; exit 64
fi
if [ -n "$UM_RUN_ID" ] && [ -n "$UM_MANIFEST_PATH" ]; then
  log_err "--run-id and --manifest are mutually exclusive (failure: pick one)"
  exit 64
fi

# Need root for any real edit (manifests are 0600 root, authorized_keys is
# owned by the target user). Dry-run is allowed unprivileged so operators
# can preview from a non-root shell.
if [ "$UM_DRY_RUN" != "1" ]; then um_require_root || exit $?; fi
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

manifests=()
if [ -n "$UM_MANIFEST_PATH" ]; then
  if [ ! -f "$UM_MANIFEST_PATH" ]; then
    log_file_error "$UM_MANIFEST_PATH" "manifest file not found"
    exit 2
  fi
  manifests=("$UM_MANIFEST_PATH")
else
  if [ ! -d "$UM_MANIFEST_DIR" ]; then
    log_err "$(um_msg manifestNotFound "$UM_RUN_ID" "$UM_MANIFEST_DIR")"
    exit 2
  fi
  shopt -s nullglob
  manifests=("$UM_MANIFEST_DIR/${UM_RUN_ID}__"*.json)
  shopt -u nullglob
  if [ "${#manifests[@]}" -eq 0 ]; then
    log_err "$(um_msg manifestNotFound "$UM_RUN_ID" "$UM_MANIFEST_DIR")"
    exit 2
  fi
fi

rc_total=0

for mf in "${manifests[@]}"; do
  if ! jq -e . "$mf" >/dev/null 2>&1; then
    err=$(jq . "$mf" 2>&1 | head -c 200 | tr '\n' ' ')
    log_err "$(um_msg manifestParseFail "$mf" "${err:-jq parse failed}")"
    rc_total=2; continue
  fi

  user=$(jq        -r '.user               // ""' "$mf")
  auth_path=$(jq   -r '.authorizedKeysFile // ""' "$mf")
  rid=$(jq         -r '.runId              // ""' "$mf")
  tracked_n=$(jq   -r '.keys | length'             "$mf")

  if [ -z "$user" ] || [ -z "$auth_path" ]; then
    log_err "$(um_msg manifestParseFail "$mf" "missing required fields user/authorizedKeysFile")"
    rc_total=2; continue
  fi

  if ! um_user_exists "$user"; then
    log_warn "$(um_msg removeNoUser "$user")"
    # Still continue -- the keys file may exist as an orphan.
  fi

  if [ ! -f "$auth_path" ]; then
    log_warn "$(um_msg removeNoAuthKeys "$auth_path" "$user")"
    # Treat as already-clean: archive the manifest and move on.
    if [ "$UM_DRY_RUN" != "1" ] && [ "$UM_KEEP_MANIFEST" != "1" ]; then
      rm -f "$mf" 2>/dev/null || log_warn "could not delete consumed manifest '$mf'"
    fi
    continue
  fi

  # Collect target fingerprints + literal lines from manifest.
  # We index BOTH so a key whose fingerprint format drifted between
  # install and rollback still matches via literal.
  declare -A target_fp=()
  declare -A target_line=()
  declare -A source_for_fp=()
  while IFS=$'\t' read -r fp line src; do
    [ -z "$fp" ] && continue
    target_fp["$fp"]=1
    target_line["$line"]=1
    source_for_fp["$fp"]="$src"
  done < <(jq -r '.keys[] | [.fingerprint, .line, .source] | @tsv' "$mf")

  # Walk authorized_keys, dropping any line whose fingerprint OR literal
  # body matches the manifest. Track per-fp status for the summary.
  declare -A removed_fp=()
  kept=$(mktemp -t 68-keep.XXXXXX)
  while IFS= read -r line || [ -n "$line" ]; do
    # Comments + blanks: keep verbatim, never count as a match.
    if [ -z "$line" ] || [ "${line:0:1}" = "#" ]; then
      printf '%s\n' "$line" >> "$kept"
      continue
    fi
    fp=$(_fp_of_line "$line")
    if [ -n "${target_fp[$fp]:-}" ] || [ -n "${target_line[$line]:-}" ]; then
      removed_fp["$fp"]=1
      log_info "$(um_msg removeKeyDropped "$fp" "$auth_path" "${source_for_fp[$fp]:-literal-match}")"
      continue   # drop
    fi
    printf '%s\n' "$line" >> "$kept"
  done < "$auth_path"

  # Report fingerprints that the manifest expected but we didn't find.
  missing=0
  for fp in "${!target_fp[@]}"; do
    if [ -z "${removed_fp[$fp]:-}" ]; then
      log_warn "$(um_msg removeKeyMissing "$fp" "$auth_path")"
      missing=$((missing+1))
    fi
  done
  removed_n=${#removed_fp[@]}

  if [ "$UM_DRY_RUN" = "1" ]; then
    log_info "$(um_msg removeSummary "$rid" "$tracked_n" "$removed_n" "$missing" "$auth_path")"
    rm -f "$kept"
    continue
  fi

  # Backup, then atomic-replace authorized_keys.
  ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
  bak="${auth_path}.bak.${ts}"
  if ! cp -p "$auth_path" "$bak" 2>/dev/null; then
    log_file_error "$bak" "could not write backup before rollback"
    rm -f "$kept"
    rc_total=2; continue
  fi
  log_info "$(um_msg removeBackupMade "$auth_path" "$bak" "$bak" "$auth_path")"

  # Preserve original mode/ownership.
  if ! cat "$kept" > "$auth_path" 2>/dev/null; then
    log_err "$(um_msg removeWriteFail "$auth_path" "could not rewrite" "$auth_path" "$ts")"
    rm -f "$kept"
    rc_total=2; continue
  fi
  chmod 0600 "$auth_path" 2>/dev/null || true
  # Re-chown only if the user still exists.
  if um_user_exists "$user"; then
    chown "$user:" "$auth_path" 2>/dev/null || true
  fi
  rm -f "$kept"

  log_ok "$(um_msg removeSummary "$rid" "$tracked_n" "$removed_n" "$missing" "$auth_path")"

  if [ "$UM_KEEP_MANIFEST" != "1" ]; then
    rm -f "$mf" 2>/dev/null || log_warn "could not delete consumed manifest '$mf'"
  fi

  unset target_fp target_line source_for_fp removed_fp
done

exit "$rc_total"