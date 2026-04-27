# 68-user-mgmt/helpers/_schema.sh -- shared strict-JSON-schema validator.
#
# Purpose
# -------
# Deduplicates ~80 lines of identical jq + reporting logic that used to
# live in each of the four `*-from-json.sh` loaders. All four leaves now
# build a one-line field-spec and call into the helpers below.
#
# Public API
# ----------
#   um_schema_normalize_array <file> <wrapper-key> [--allow-strings]
#       Normalises any of {single object, array, wrapped object} into a
#       JSON array on the variable UM_NORMALIZED_JSON. Sets
#       UM_NORMALIZED_COUNT. Returns 2 on parse failure (already logged).
#       --allow-strings converts bare strings in the array to { name: . }
#       (used by remove-user-from-json.sh).
#
#   um_schema_validate_record <rec> <allowed_fields> <required_fields> \
#                             <field_specs> [<mutex_pairs>]
#       Runs the shared jq validator program on the record. Emits TSV
#       rows on stdout: ERROR<TAB>field<TAB>reason  /  WARN<TAB>...
#
#       <allowed_fields>  : space-separated whitelist (typo guard).
#       <required_fields> : space-separated required field names.
#       <field_specs>     : space-separated `field:rule` items. Rules:
#                             nestr     non-empty string
#                             str       string (may be empty)
#                             bool      boolean
#                             uid       non-negative integer or numeric string
#                             nestrarr  array of non-empty strings
#       <mutex_pairs>     : OPTIONAL space-separated `a,b` pairs. Both
#                           true => ERROR on field 'a'.
#
#   um_schema_report <i> <file> <validation_out> [<mode>]
#       Walks the TSV from um_schema_validate_record, logs each row using
#       the right um_msg template, and sets UM_SCHEMA_ERR_COUNT. <mode>
#       is "rich" (default; uses schemaFieldType / schemaArrayItemType /
#       schemaFieldEmpty / jsonRecordBad templates) or "plain" (single
#       generic line per error -- used by edit/remove loaders that don't
#       have the rich templates wired into their log-messages.json).
#
#   um_schema_record_name <rec>
#       Echoes .name, "<missing>", or "<not-an-object>". Never errors.
#
# CODE RED
# --------
# Every failure path includes the exact JSON path under inspection so the
# operator can grep their input file. The wrapping templates already
# include the file path; this helper supplies the record index + field.

# Guard against double-source.
if [ -n "${UM_SCHEMA_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
UM_SCHEMA_LOADED=1

um_schema_normalize_array() {
  local file="$1" wrapper="$2" allow_strings="${3:-}"
  local tmp_err
  tmp_err=$(mktemp -t 68-schema-jq-err.XXXXXX)

  local prog="
    ( if   type == \"object\" and has(\"$wrapper\") and (.[\"$wrapper\"]|type==\"array\") then .[\"$wrapper\"]
      elif type == \"array\"  then .
      elif type == \"object\" then [ . ]
      else error(\"top-level must be object or array\")
      end
    )"
  if [ "$allow_strings" = "--allow-strings" ]; then
    prog="$prog | map(if type == \"string\" then { name: . } else . end)"
  fi

  UM_NORMALIZED_JSON=$(jq -c "$prog" "$file" 2>"$tmp_err")
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    local err_text
    err_text=$(cat "$tmp_err" 2>/dev/null)
    rm -f "$tmp_err"
    if command -v um_msg >/dev/null 2>&1; then
      log_err "$(um_msg jsonParseFail "$file" "$err_text" 2>/dev/null \
        || echo "JSON parse failed for exact path: '$file' (failure: $err_text)")"
    else
      log_err "JSON parse failed for exact path: '$file' (failure: $err_text)"
    fi
    return 2
  fi
  rm -f "$tmp_err"
  UM_NORMALIZED_COUNT=$(jq 'length' <<< "$UM_NORMALIZED_JSON")
  export UM_NORMALIZED_JSON UM_NORMALIZED_COUNT
  return 0
}

um_schema_record_name() {
  local rec="$1"
  local t
  t=$(jq -r 'type' <<< "$rec" 2>/dev/null)
  if [ "$t" = "object" ]; then
    jq -r '.name // "<missing>"' <<< "$rec"
  else
    echo "<not-an-object>"
  fi
}

# Build the jq validator program from <allowed> <required> <specs> <mutex>.
_um_schema_build_program() {
  local allowed="$1" required="$2" specs="$3" mutex="${4:-}"

  # Common reusable jq defs.
  local prog
  prog='
    def expect(field; want):
        if has(field) then
            (.[field] | type) as $t
            | if $t != want then "ERROR\t\(field)\twrong type: expected \(want), got \($t)"
              else empty end
        else empty end;

    def expect_nonempty_string(field):
        if has(field) then
            (.[field]) as $v | ($v | type) as $t
            | if $t == "null" then "ERROR\t\(field)\tnull value"
              elif $t != "string" then "ERROR\t\(field)\twrong type: expected string, got \($t)"
              elif ($v | length) == 0 then "ERROR\t\(field)\tempty string"
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
            | if $t != "array" then "ERROR\t\(field)\twrong type: expected array, got \($t) -- did you forget the [...] brackets?"
              else
                  $arr | to_entries | map(
                      (.value | type) as $vt
                      | if $vt != "string" then "ERROR\t\(field)[\(.key)]\twrong type: expected non-empty string, got \($vt) (value=\(.value | tostring | .[0:80]))"
                        elif (.value | length) == 0 then "ERROR\t\(field)[\(.key)]\tempty string"
                        else empty end
                  ) | .[]
              end
        else empty end;
  '

  # Required-field checks.
  local clauses="" first=1 r f rule pair a b
  for r in $required; do
    if [ "$first" = "1" ]; then first=0; else clauses="$clauses,"; fi
    clauses="$clauses
        ( if has(\"$r\") | not then \"ERROR\t$r\tmissing required field\" else empty end )"
  done

  # Per-field rule clauses.
  local item
  for item in $specs; do
    f="${item%%:*}"; rule="${item#*:}"
    if [ "$first" = "1" ]; then first=0; else clauses="$clauses,"; fi
    case "$rule" in
      nestr)    clauses="$clauses
        expect_nonempty_string(\"$f\")" ;;
      str)      clauses="$clauses
        expect(\"$f\"; \"string\")" ;;
      bool)     clauses="$clauses
        expect(\"$f\"; \"boolean\")" ;;
      uid)      clauses="$clauses
        expect_uid(\"$f\")" ;;
      nestrarr) clauses="$clauses
        expect_str_array(\"$f\")" ;;
      *) clauses="$clauses
        empty   # unknown rule '$rule' for field '$f' -- ignored" ;;
    esac
  done

  # Mutex clauses.
  if [ -n "$mutex" ]; then
    for pair in $mutex; do
      a="${pair%%,*}"; b="${pair##*,}"
      if [ "$first" = "1" ]; then first=0; else clauses="$clauses,"; fi
      clauses="$clauses
        ( if (.\"$a\" == true) and (.\"$b\" == true) then
              \"ERROR\t$a\tcannot be true while $b is also true\"
          else empty end )"
    done
  fi

  # Unknown-field warnings.
  if [ "$first" = "1" ]; then first=0; else clauses="$clauses,"; fi
  clauses="$clauses
        ( (\$allowed | split(\" \")) as \$known
          | keys[]
          | select(. as \$k | (\$known | index(\$k)) | not)
          | \"WARN\t\(.)\tunknown field (allowed: \(\$allowed))\"
        )"

  printf '%s\n%s\n' "$prog" "$clauses"
}

um_schema_validate_record() {
  local rec="$1" allowed="$2" required="$3" specs="$4" mutex="${5:-}"

  # Top-level shape check first.
  local toptype
  toptype=$(jq -r 'type' <<< "$rec" 2>/dev/null)
  if [ "$toptype" != "object" ]; then
    printf 'ERROR\t<root>\tnot an object (got %s)\n' "$toptype"
    return 0
  fi

  local prog
  prog=$(_um_schema_build_program "$allowed" "$required" "$specs" "$mutex")
  jq -r --arg allowed "$allowed" "$prog" <<< "$rec" 2>/dev/null
}

# Walk validator output, emit log lines, set UM_SCHEMA_ERR_COUNT.
um_schema_report() {
  local i="$1" file="$2" out="$3" mode="${4:-rich}" allowed="${5:-}"
  UM_SCHEMA_ERR_COUNT=0
  [ -z "$out" ] && return 0

  local severity field reason
  while IFS=$'\t' read -r severity field reason; do
    [ -z "$severity" ] && continue
    case "$severity" in
      ERROR)
        UM_SCHEMA_ERR_COUNT=$((UM_SCHEMA_ERR_COUNT + 1))
        if [ "$mode" = "rich" ]; then
          case "$reason" in
            "missing required field")
              log_err "$(um_msg jsonRecordBad "$i" "$file" "$field" 2>/dev/null \
                || echo "JSON record #$i in '$file' field '$field': missing required field")" ;;
            "empty string"|"null value")
              log_err "$(um_msg schemaFieldEmpty "$i" "$file" "$field" 2>/dev/null \
                || echo "JSON record #$i in '$file' field '$field': $reason")" ;;
            wrong\ type:*)
              if printf '%s' "$field" | grep -qE '\[[0-9]+\]$'; then
                local base idx got val
                base="${field%[*}"; idx="${field##*[}"; idx="${idx%]}"
                got=$(printf '%s' "$reason" | sed -nE 's/.*got ([a-z]+).*/\1/p')
                val=$(printf '%s' "$reason" | sed -nE 's/.*value=(.*)\)$/\1/p')
                log_err "$(um_msg schemaArrayItemType "$i" "$file" "$base" "$idx" "$got" "$val" 2>/dev/null \
                  || echo "JSON record #$i in '$file' field '$base'[$idx]: wrong type ($got)")"
              else
                local expected got
                expected=$(printf '%s' "$reason" | sed -nE 's/.*expected ([^,]+),.*/\1/p')
                got=$(printf '%s' "$reason" | sed -nE 's/.*got ([a-z]+).*/\1/p')
                log_err "$(um_msg schemaFieldType "$i" "$file" "$field" "$expected" "$got" 2>/dev/null \
                  || echo "JSON record #$i in '$file' field '$field': expected $expected got $got")"
              fi ;;
            *)
              log_err "JSON record #$i in '$file' field '$field': $reason (failure: rejecting record)"
              ;;
          esac
        else
          log_err "JSON record #$i in '$file' field '$field': $reason (failure: rejecting record)"
        fi
        ;;
      WARN)
        if [ "$mode" = "rich" ] && [ -n "$allowed" ]; then
          log_warn "$(um_msg schemaUnknownField "$i" "$file" "$field" "$allowed" 2>/dev/null \
            || echo "JSON record #$i in '$file' field '$field': unknown field (allowed: $allowed)")"
        else
          log_warn "JSON record #$i in '$file' field '$field': $reason"
        fi
        ;;
    esac
  done <<< "$out"
  export UM_SCHEMA_ERR_COUNT
  return 0
}