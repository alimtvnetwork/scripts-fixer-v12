#!/usr/bin/env bash
# 68-user-mgmt/add-user-from-json.sh -- bulk user creation from JSON.
#
# Input shapes (auto-detected):
#   1) Single object:  { "name": "alice", "password": "...", "groups": ["sudo"] }
#   2) Array:          [ { ... }, { ... }, ... ]
#   3) Wrapped:        { "users": [ ... ] }   <- also accepted for convenience
#
# Each record is dispatched to add-user.sh so we get identical idempotency,
# password masking, and CODE RED file/path error reporting for free.
#
# Usage:
#   ./add-user-from-json.sh <file.json> [--dry-run]

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"
. "$SCRIPT_DIR/helpers/_schema.sh"

# --- Strict JSON-schema validation (added v0.170.0) ----------------------
# Allowed top-level fields per record. Anything outside this set triggers
# a "schemaUnknownField" warning (typo guard) but does NOT reject the
# record on its own -- the user can still opt in to strict-mode rejection
# via UM_STRICT_UNKNOWN=1.
UM_ALLOWED_FIELDS="name password passwordFile uid shell home comment primaryGroup groups sudo system sshKeys sshKeyFiles sshKeyUrls sshKeyUrlTimeout sshKeyUrlMaxBytes sshKeyUrlAllowlist allowInsecureSshKeyUrl"

# Schema (consumed by helpers/_schema.sh; see that file for the rule DSL).
UM_SCHEMA_REQUIRED="name"
UM_SCHEMA_FIELDS="name:nestr password:nestr passwordFile:nestr shell:nestr home:nestr comment:str primaryGroup:nestr uid:uid sudo:bool system:bool groups:nestrarr sshKeys:nestrarr sshKeyFiles:nestrarr sshKeyUrls:nestrarr sshKeyUrlTimeout:uid sshKeyUrlMaxBytes:uid sshKeyUrlAllowlist:nestr allowInsecureSshKeyUrl:bool"

um_usage() {
  cat <<EOF
# add-user-json -- bulk users from JSON; see readme.md for record schema.
Usage: add-user-from-json.sh <file.json> [--dry-run]

Accepts a JSON file containing a single object **or** array -- auto-detected.
Three accepted shapes (mirrors readme.md "JSON examples"):
  - single object : { "name": "dan", "password": "...", "groups": ["sudo"] }
  - array         : [ { "name": "alice", ... }, { "name": "bob", ... } ]
  - wrapped       : { "users": [ ... ] }
Each record fans out to add-user.sh.

User record fields (verbatim from readme.md "User record fields"):
  name          string    REQUIRED
  password      string    plain text (never logged; masked in console)
  passwordFile  string    path to a 0600/0400 file containing the password (preferred)
  uid           number    explicit UID (auto-allocated on macOS if omitted)
  primaryGroup  string    primary group; created if missing on Linux
  groups        string[]  supplementary groups
  shell         string    login shell (default: /bin/bash Linux, /bin/zsh macOS)
  home          string    home dir (default: /home/<name> or /Users/<name>)
  comment       string    GECOS / RealName
  sudo          bool      also add to 'sudo' (Linux) or 'admin' (macOS)
  system        bool      system account (Linux only; ignored on macOS)
  sshKeys       string[]  inline OpenSSH public keys to install in ~/.ssh/authorized_keys
  sshKeyFiles   string[]  host paths to .pub files (one or many keys per file; comments ok)

SSH-key install behaviour (verbatim from readme.md):
  - Dir/file perms enforced: ~/.ssh -> 0700, authorized_keys -> 0600,
    both chown'd to the new user + their primary group.
  - Existing authorized_keys content is preserved; new keys are appended
    and the merged file is de-duplicated.
  - Each key is sanity-checked for an OpenSSH algo prefix (ssh-rsa,
    ssh-ed25519, ecdsa-sha2-*, sk-*, ssh-dss); malformed lines are
    warn-logged and skipped.
  - Key bodies are NEVER written to logs -- only a SHA-256 fingerprint
    per installed key.
  - Both fields can be combined; both flags (--ssh-key, --ssh-key-file)
    are repeatable on the CLI.
EOF
}

UM_FILE=""
UM_DRY_RUN="${UM_DRY_RUN:-0}"
# Rollback manifest plumbing (v0.172.0). When the operator does NOT pass
# --run-id we generate one here so EVERY user record in this batch lands
# in the same logical run -- one rollback removes the whole batch.
UM_RUN_ID="${UM_RUN_ID:-}"
UM_MANIFEST_DIR="${UM_MANIFEST_DIR:-}"
UM_NO_MANIFEST="${UM_NO_MANIFEST:-0}"
# v0.182.0 -- batch-level summary JSON. Same target semantics as the
# child flag, plus the additional behaviour that per-user JSONs are also
# written so the rollup can aggregate them. Set explicitly via
# --summary-json=<target> or implicitly inherited from the env.
UM_SUMMARY_JSON="${UM_SUMMARY_JSON:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) um_usage; exit 0 ;;
    --dry-run) UM_DRY_RUN=1; shift ;;
    --run-id)        UM_RUN_ID="${2:-}"; shift 2 ;;
    --manifest-dir)  UM_MANIFEST_DIR="${2:-}"; shift 2 ;;
    --no-manifest)   UM_NO_MANIFEST=1; shift ;;
    --summary-json)
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
            UM_SUMMARY_JSON="$2"; shift 2
        else
            UM_SUMMARY_JSON="auto"; shift
        fi
        ;;
    --summary-json=*) UM_SUMMARY_JSON="${1#--summary-json=}"; shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1'"; exit 64 ;;
    *)
      if [ -z "$UM_FILE" ]; then UM_FILE="$1"; shift
      else log_err "unexpected positional: '$1'"; exit 64; fi
      ;;
  esac
done

if [ -z "$UM_FILE" ]; then
  log_err "missing required <file.json> (failure: nothing to read)"
  um_usage; exit 64
fi
if [ ! -f "$UM_FILE" ]; then
  log_file_error "$UM_FILE" "JSON input not found"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  log_err "$(um_msg missingTool "jq")"
  exit 127
fi

um_detect_os || exit $?
um_require_root || exit $?
if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

# Validate JSON + normalise into an array (shared helper).
um_schema_normalize_array "$UM_FILE" "users" || exit 2
normalised="$UM_NORMALIZED_JSON"
count="$UM_NORMALIZED_COUNT"
log_info "loaded $count user record(s) from '$UM_FILE'"

# Generate a single batch run-id up-front (unless the operator opted out
# or supplied one). All add-user.sh children inherit it via env so the
# whole JSON file rolls back as one unit.
if [ "$UM_NO_MANIFEST" != "1" ] && [ -z "$UM_RUN_ID" ]; then
  UM_RUN_ID="batch-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo 00000000-000000)-$$"
fi
if [ "$UM_NO_MANIFEST" != "1" ]; then
  log_info "ssh-key rollback run-id for this batch: '$UM_RUN_ID' (use 'remove-ssh-keys.sh --run-id $UM_RUN_ID' to undo)"
fi
export UM_RUN_ID UM_NO_MANIFEST
[ -n "$UM_MANIFEST_DIR" ] && export UM_MANIFEST_DIR

# v0.182.0 -- batch summary JSON plumbing.
# When the operator asks for a batch summary, force every child into
# "auto" so we can find their per-user summary files later and aggregate
# them into one rollup. This keeps both the per-user docs (canonical
# audit trail) AND a single rollup the operator can grep on.
# UM_BATCH_SUMMARY_TARGET preserves the operator's original choice
# (auto / stdout / explicit path) for the rollup itself.
UM_BATCH_SUMMARY_TARGET="$UM_SUMMARY_JSON"
if [ -n "$UM_SUMMARY_JSON" ]; then
    if [ "$UM_NO_MANIFEST" = "1" ]; then
        log_warn "--summary-json with --no-manifest: per-user summaries fall back to stdout (run-id is required for the auto path); batch rollup will be best-effort"
    fi
    export UM_SUMMARY_JSON="auto"
fi

# Set up a per-batch summary file so we can print a single roll-up.
UM_SUMMARY_FILE="${UM_SUMMARY_FILE:-$(mktemp -t 68-summary.XXXXXX)}"
export UM_SUMMARY_FILE

rc_total=0
i=0
while [ "$i" -lt "$count" ]; do
  rec=$(jq -c ".[$i]" <<< "$normalised")

  # ---- Strict schema validation (v0.170.0) ----
  validation_out=$(um_schema_validate_record "$rec" "$UM_ALLOWED_FIELDS" \
    "$UM_SCHEMA_REQUIRED" "$UM_SCHEMA_FIELDS")
  um_schema_report "$i" "$UM_FILE" "$validation_out" "rich" "$UM_ALLOWED_FIELDS"
  name=$(um_schema_record_name "$rec")

  if [ "$UM_SCHEMA_ERR_COUNT" -gt 0 ]; then
    log_err "$(um_msg schemaRecordRejected "$i" "$UM_FILE" "$name" "$UM_SCHEMA_ERR_COUNT")"
    rc_total=1
    i=$((i+1)); continue
  fi

  pw=$(jq -r       '.password // empty'      <<< "$rec")
  pwfile=$(jq -r   '.passwordFile // empty'  <<< "$rec")
  uid=$(jq -r      '.uid // empty'           <<< "$rec")
  shell=$(jq -r    '.shell // empty'         <<< "$rec")
  home=$(jq -r     '.home  // empty'         <<< "$rec")
  comment=$(jq -r  '.comment // empty'       <<< "$rec")
  pgroup=$(jq -r   '.primaryGroup // empty'  <<< "$rec")
  groups=$(jq -r   'if has("groups") and (.groups|type=="array") then (.groups|join(",")) else "" end' <<< "$rec")
  is_sudo=$(jq -r  'if .sudo == true then "1" else "" end'   <<< "$rec")
  is_sys=$(jq -r   'if .system == true then "1" else "" end' <<< "$rec")

  args=("$name")
  [ -n "$pw" ]      && args+=(--password "$pw")
  [ -n "$pwfile" ]  && args+=(--password-file "$pwfile")
  [ -n "$uid" ]     && args+=(--uid "$uid")
  [ -n "$pgroup" ]  && args+=(--primary-group "$pgroup")
  [ -n "$groups" ]  && args+=(--groups "$groups")
  [ -n "$shell" ]   && args+=(--shell "$shell")
  [ -n "$home" ]    && args+=(--home "$home")
  [ -n "$comment" ] && args+=(--comment "$comment")
  [ "$is_sudo" = "1" ] && args+=(--sudo)
  [ "$is_sys"  = "1" ] && args+=(--system)
  [ "$UM_DRY_RUN" = "1" ] && args+=(--dry-run)

  # SSH keys (added in v0.140.0 alongside the root add-user shortcut).
  # Two arrays per record:
  #   sshKeys      : array of inline OpenSSH public-key strings
  #   sshKeyFiles  : array of paths to .pub files on this host
  # Both are optional. Both fan out to repeatable --ssh-key / --ssh-key-file
  # flags. Empty arrays are no-ops (same as omitting the field entirely).
  # NB: type/empty validation already happened above in _validate_user_record;
  # if we got here the arrays (when present) are guaranteed array-of-non-empty-string.
  if jq -e 'has("sshKeys")' <<< "$rec" >/dev/null 2>&1; then
    n=$(jq '.sshKeys | length' <<< "$rec")
    j=0
    while [ "$j" -lt "$n" ]; do
      kv=$(jq -r ".sshKeys[$j]" <<< "$rec")
      args+=(--ssh-key "$kv")
      j=$((j+1))
    done
  fi
  if jq -e 'has("sshKeyFiles")' <<< "$rec" >/dev/null 2>&1; then
    n=$(jq '.sshKeyFiles | length' <<< "$rec")
    j=0
    while [ "$j" -lt "$n" ]; do
      fv=$(jq -r ".sshKeyFiles[$j]" <<< "$rec")
      args+=(--ssh-key-file "$fv")
      j=$((j+1))
    done
  fi
  # URL-sourced ssh keys (v0.171.0). Same array shape as sshKeyFiles;
  # extra knobs map to the matching --ssh-key-url-* CLI flags.
  if jq -e 'has("sshKeyUrls")' <<< "$rec" >/dev/null 2>&1; then
    n=$(jq '.sshKeyUrls | length' <<< "$rec")
    j=0
    while [ "$j" -lt "$n" ]; do
      uv=$(jq -r ".sshKeyUrls[$j]" <<< "$rec")
      args+=(--ssh-key-url "$uv")
      j=$((j+1))
    done
  fi
  url_to=$(jq -r       '.sshKeyUrlTimeout   // empty' <<< "$rec")
  url_mb=$(jq -r       '.sshKeyUrlMaxBytes  // empty' <<< "$rec")
  url_al=$(jq -r       '.sshKeyUrlAllowlist // empty' <<< "$rec")
  url_ins=$(jq -r 'if .allowInsecureSshKeyUrl == true then "1" else "" end' <<< "$rec")
  [ -n "$url_to" ]  && args+=(--ssh-key-url-timeout   "$url_to")
  [ -n "$url_mb" ]  && args+=(--ssh-key-url-max-bytes "$url_mb")
  [ -n "$url_al" ]  && args+=(--ssh-key-url-allowlist "$url_al")
  [ "$url_ins" = "1" ] && args+=(--allow-insecure-url)

  log_info "--- record $((i+1))/$count: user='$name' ---"
  if ! bash "$SCRIPT_DIR/add-user.sh" "${args[@]}"; then
    rc_total=1
  fi
  i=$((i+1))
done

# v0.182.0 -- assemble the batch rollup if the operator asked for one.
# Slurps every per-user summary file we just wrote (keyed by run-id),
# wraps them in a batch envelope with aggregated counters, and emits
# to the requested target. Failures are non-fatal -- the per-user docs
# stay on disk and are still independently parseable.
if [ -n "$UM_BATCH_SUMMARY_TARGET" ]; then
    sdir="${UM_MANIFEST_DIR:-/var/lib/68-user-mgmt/ssh-key-runs}/summaries"
    shopt -s nullglob
    per_user_files=("$sdir/${UM_RUN_ID}__"*.summary.json)
    shopt -u nullglob
    if [ "${#per_user_files[@]}" -eq 0 ]; then
        log_warn "[68][batch-summary] no per-user summary JSONs found under '$sdir' for run-id '$UM_RUN_ID' (failure: nothing to aggregate -- did any record install ssh keys?)"
    else
        # Aggregate counters across all per-user docs via jq.
        rollup=$(jq -s --arg rid "$UM_RUN_ID" \
                       --arg src "$UM_FILE" \
                       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            {
                summaryVersion: 1,
                kind: "batch",
                writtenAt: $now,
                runId: $rid,
                sourceFile: $src,
                userCount: length,
                aggregate: {
                    sources_requested:  ([.[].summary.sources_requested]  | add // 0),
                    keys_parsed:        ([.[].summary.keys_parsed]        | add // 0),
                    keys_unique:        ([.[].summary.keys_unique]        | add // 0),
                    keys_installed_new: ([.[].summary.keys_installed_new] | add // 0),
                    keys_preserved:     ([.[].summary.keys_preserved]     | add // 0)
                },
                users: .
            }' "${per_user_files[@]}" 2>/dev/null) || rollup=""
        if [ -z "$rollup" ]; then
            log_err "[68][batch-summary] jq failed to build rollup from ${#per_user_files[@]} file(s) under '$sdir' (failure: per-user JSONs may be malformed -- inspect them manually)"
        else
            case "$UM_BATCH_SUMMARY_TARGET" in
                stdout)
                    printf '\n---SSH-SUMMARY-JSON---\n%s\n' "$rollup"
                    log_ok "$(um_msg summaryJsonBatchWritten "<stdout>" "$UM_RUN_ID" "${#per_user_files[@]}")"
                    ;;
                auto)
                    rollup_path="$sdir/${UM_RUN_ID}__BATCH.summary.json"
                    if printf '%s\n' "$rollup" > "$rollup_path.tmp" 2>/dev/null \
                       && mv "$rollup_path.tmp" "$rollup_path" 2>/dev/null; then
                        chmod 0600 "$rollup_path" 2>/dev/null || true
                        log_ok "$(um_msg summaryJsonBatchWritten "$rollup_path" "$UM_RUN_ID" "${#per_user_files[@]}")"
                    else
                        rm -f "$rollup_path.tmp"
                        log_file_error "$rollup_path" "could not write batch summary rollup (failure: write/mv failed -- check ownership of $sdir)"
                    fi
                    ;;
                *)
                    sparent=$(dirname "$UM_BATCH_SUMMARY_TARGET")
                    if [ ! -d "$sparent" ]; then
                        log_file_error "$sparent" "batch summary target parent dir does not exist (failure: create '$sparent' first or use --summary-json=auto)"
                    elif printf '%s\n' "$rollup" > "$UM_BATCH_SUMMARY_TARGET.tmp" 2>/dev/null \
                         && mv "$UM_BATCH_SUMMARY_TARGET.tmp" "$UM_BATCH_SUMMARY_TARGET" 2>/dev/null; then
                        chmod 0600 "$UM_BATCH_SUMMARY_TARGET" 2>/dev/null || true
                        log_ok "$(um_msg summaryJsonBatchWritten "$UM_BATCH_SUMMARY_TARGET" "$UM_RUN_ID" "${#per_user_files[@]}")"
                    else
                        rm -f "$UM_BATCH_SUMMARY_TARGET.tmp"
                        log_file_error "$UM_BATCH_SUMMARY_TARGET" "could not write batch summary rollup (failure: write/mv failed)"
                    fi
                    ;;
            esac
        fi
    fi
fi

um_summary_print
exit "$rc_total"