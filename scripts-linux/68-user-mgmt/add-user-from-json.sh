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

# --- Strict JSON-schema validation (added v0.170.0) ----------------------
# Allowed top-level fields per record. Anything outside this set triggers
# a "schemaUnknownField" warning (typo guard) but does NOT reject the
# record on its own -- the user can still opt in to strict-mode rejection
# via UM_STRICT_UNKNOWN=1.
UM_ALLOWED_FIELDS="name password passwordFile uid shell home comment primaryGroup groups sudo system sshKeys sshKeyFiles sshKeyUrls sshKeyUrlTimeout sshKeyUrlMaxBytes sshKeyUrlAllowlist allowInsecureSshKeyUrl"

# Validate one record's schema. Emits TSV error rows on stdout:
#   ERROR<TAB>field<TAB>reason
#   WARN <TAB>field<TAB>reason
# Caller counts ERROR rows; >0 => reject the record.
#
# Type rules (jq's type names: string|number|boolean|array|object|null):
#   name           REQUIRED string non-empty
#   password       OPTIONAL string non-empty (if present)
#   passwordFile   OPTIONAL string non-empty
#   uid            OPTIONAL number OR numeric-string
#   shell          OPTIONAL string non-empty
#   home           OPTIONAL string non-empty
#   comment        OPTIONAL string (may be empty)
#   primaryGroup   OPTIONAL string non-empty
#   groups         OPTIONAL array of non-empty strings
#   sudo           OPTIONAL boolean
#   system         OPTIONAL boolean
#   sshKeys        OPTIONAL array of non-empty strings
#   sshKeyFiles    OPTIONAL array of non-empty strings
_validate_user_record() {
    local rec="$1"
    # Top-level shape.
    local toptype
    toptype=$(jq -r 'type' <<< "$rec")
    if [ "$toptype" != "object" ]; then
        printf 'ERROR\t<root>\tnot an object (got %s)\n' "$toptype"
        return 0
    fi

    # Single jq pass that emits one TSV row per problem found.
    # Using a jq program (not multiple invocations) so a 50-record file
    # validates in ~50 jq calls instead of ~600.
    jq -r --arg allowed "$UM_ALLOWED_FIELDS" '
        def expect(field; want):
            if has(field) then
                (.[field] | type) as $t
                | if $t != want then
                      "ERROR\t\(field)\twrong type: expected \(want), got \($t)"
                  else empty end
            else empty end;

        def expect_nonempty_string(field):
            if has(field) then
                (.[field]) as $v | ($v | type) as $t
                | if $t == "null" then
                      "ERROR\t\(field)\tnull value"
                  elif $t != "string" then
                      "ERROR\t\(field)\twrong type: expected string, got \($t)"
                  elif ($v | length) == 0 then
                      "ERROR\t\(field)\tempty string"
                  else empty end
            else empty end;

        def expect_uid(field):
            if has(field) then
                (.[field]) as $v | ($v | type) as $t
                | if $t == "number" then
                      if ($v | floor) != $v or $v < 0 then
                          "ERROR\t\(field)\tnot a non-negative integer (\($v))"
                      else empty end
                  elif $t == "string" then
                      if ($v | test("^[0-9]+$")) then empty
                      else "ERROR\t\(field)\tstring is not numeric (\($v))" end
                  else
                      "ERROR\t\(field)\twrong type: expected integer or numeric string, got \($t)"
                  end
            else empty end;

        def expect_str_array(field):
            if has(field) then
                (.[field]) as $arr | ($arr | type) as $t
                | if $t != "array" then
                      "ERROR\t\(field)\twrong type: expected array, got \($t) -- did you forget the [...] brackets?"
                  else
                      $arr
                      | to_entries
                      | map(
                          (.value | type) as $vt
                          | if $vt != "string" then
                                "ERROR\t\(field)[\(.key)]\twrong type: expected non-empty string, got \($vt) (value=\(.value | tostring | .[0:80]))"
                            elif (.value | length) == 0 then
                                "ERROR\t\(field)[\(.key)]\tempty string"
                            else empty end
                        )
                      | .[]
                  end
            else empty end;

        # Required: name.
        ( if has("name") | not then
              "ERROR\tname\tmissing required field"
          else empty end ),
        expect_nonempty_string("name"),

        # Optional scalars.
        expect_nonempty_string("password"),
        expect_nonempty_string("passwordFile"),
        expect_nonempty_string("shell"),
        expect_nonempty_string("home"),
        expect("comment"; "string"),
        expect_nonempty_string("primaryGroup"),
        expect_uid("uid"),
        expect("sudo"; "boolean"),
        expect("system"; "boolean"),

        # Arrays.
        expect_str_array("groups"),
        expect_str_array("sshKeys"),
        expect_str_array("sshKeyFiles"),
        expect_str_array("sshKeyUrls"),

        # URL-fetcher knobs.
        expect_uid("sshKeyUrlTimeout"),
        expect_uid("sshKeyUrlMaxBytes"),
        expect_nonempty_string("sshKeyUrlAllowlist"),
        expect("allowInsecureSshKeyUrl"; "boolean"),

        # Unknown-field warnings (typo guard).
        ( ($allowed | split(" ")) as $known
          | keys[]
          | select(. as $k | ($known | index($k)) | not)
          | "WARN\t\(.)\tunknown field (allowed: \($allowed))"
        )
    ' <<< "$rec" 2>/dev/null
}

um_usage() {
  cat <<EOF
Usage: add-user-from-json.sh <file.json> [--dry-run]

Accepts a JSON file containing one user object, an array of user objects,
or { "users": [ ... ] }. Each record fans out to add-user.sh.
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
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) um_usage; exit 0 ;;
    --dry-run) UM_DRY_RUN=1; shift ;;
    --run-id)        UM_RUN_ID="${2:-}"; shift 2 ;;
    --manifest-dir)  UM_MANIFEST_DIR="${2:-}"; shift 2 ;;
    --no-manifest)   UM_NO_MANIFEST=1; shift ;;
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

# Validate JSON + normalize into an array on stdout.
#  - bare object with .users  -> .users
#  - bare array               -> as is
#  - bare object              -> [ . ]
#  - anything else            -> error
normalised=$(jq -c '
  if type == "object" and has("users") and (.users|type=="array") then .users
  elif type == "array" then .
  elif type == "object" then [ . ]
  else error("top-level must be object or array")
  end
' "$UM_FILE" 2>/tmp/68-jq-err.$$)
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  err_text=$(cat /tmp/68-jq-err.$$ 2>/dev/null); rm -f /tmp/68-jq-err.$$
  log_err "$(um_msg jsonParseFail "$UM_FILE" "$err_text")"
  exit 2
fi
rm -f /tmp/68-jq-err.$$

count=$(jq 'length' <<< "$normalised")
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

# Set up a per-batch summary file so we can print a single roll-up.
UM_SUMMARY_FILE="${UM_SUMMARY_FILE:-$(mktemp -t 68-summary.XXXXXX)}"
export UM_SUMMARY_FILE

rc_total=0
i=0
while [ "$i" -lt "$count" ]; do
  rec=$(jq -c ".[$i]" <<< "$normalised")

  # ---- Strict schema validation (v0.170.0) ----
  # Run validator, capture all error/warn rows, then report each one
  # with a properly-templated log line. No silent skips.
  validation_out=$(_validate_user_record "$rec")
  err_count=0
  if [ -n "$validation_out" ]; then
    while IFS=$'\t' read -r severity field reason; do
      [ -z "$severity" ] && continue
      case "$severity" in
        ERROR)
          err_count=$((err_count+1))
          # Disambiguate empty/missing/type/array errors into the right template.
          case "$reason" in
            "missing required field")
              log_err "$(um_msg jsonRecordBad "$i" "$UM_FILE" "$field")" ;;
            "empty string"|"null value")
              log_err "$(um_msg schemaFieldEmpty "$i" "$UM_FILE" "$field")" ;;
            wrong\ type:*)
              # reason format: "wrong type: expected X, got Y" or "...(value=...)".
              # For array-item errors the field already contains "name[idx]".
              if printf '%s' "$field" | grep -qE '\[[0-9]+\]$'; then
                base="${field%[*}"; idx="${field##*[}"; idx="${idx%]}"
                got=$(printf '%s' "$reason" | sed -nE 's/.*got ([a-z]+).*/\1/p')
                val=$(printf '%s' "$reason" | sed -nE 's/.*value=(.*)\)$/\1/p')
                log_err "$(um_msg schemaArrayItemType "$i" "$UM_FILE" "$base" "$idx" "$got" "$val")"
              else
                expected=$(printf '%s' "$reason" | sed -nE 's/.*expected ([^,]+),.*/\1/p')
                got=$(printf '%s'      "$reason" | sed -nE 's/.*got ([a-z]+).*/\1/p')
                log_err "$(um_msg schemaFieldType "$i" "$UM_FILE" "$field" "$expected" "$got")"
              fi ;;
            *)
              # Generic fall-through for messages like "not a non-negative integer (X)"
              # or "string is not numeric (X)".
              log_err "JSON record #$i in '$UM_FILE' field '$field': $reason (failure: rejecting record)"
              ;;
          esac
          ;;
        WARN)
          log_warn "$(um_msg schemaUnknownField "$i" "$UM_FILE" "$field" "$UM_ALLOWED_FIELDS")"
          ;;
      esac
    done <<< "$validation_out"
  fi

  # name is needed for the rejection summary line; pull it AFTER validation
  # so we don't crash on records missing the field. Guard against records
  # that aren't objects at all (e.g. bare strings/numbers) -- jq can't
  # .name a string.
  if [ "$(jq -r 'type' <<< "$rec")" = "object" ]; then
    name=$(jq -r '.name // "<missing>"' <<< "$rec")
  else
    name="<not-an-object>"
  fi

  if [ "$err_count" -gt 0 ]; then
    log_err "$(um_msg schemaRecordRejected "$i" "$UM_FILE" "$name" "$err_count")"
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

um_summary_print
exit "$rc_total"