#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="12"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/parallel.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"
. "$ROOT/_shared/registry.sh"

CONFIG="$SCRIPT_DIR/config.json"
PROFILES="$SCRIPT_DIR/profiles.json"
[ -f "$CONFIG" ]   || { log_file_error "$CONFIG"   "config.json missing for 12-install-all-dev-tools";   exit 1; }
[ -f "$PROFILES" ] || { log_file_error "$PROFILES" "profiles.json missing for 12-install-all-dev-tools"; exit 1; }
has_jq || { log_err "[12] jq required to read profiles"; exit 1; }

SUMMARY_DIR="$ROOT/.summary"
mkdir -p "$SUMMARY_DIR" || log_file_error "$SUMMARY_DIR" "summary dir mkdir failed"

# ---------- arg parsing ----------
VERB="install"
PROFILE=$(jq -r '.defaults.profile' "$PROFILES")
PARALLEL=$(jq -r '.defaults.parallel' "$PROFILES")
STOP_ON_FAIL=$(jq -r '.defaults.stopOnFail' "$PROFILES")
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    install|check|repair|uninstall) VERB="$1"; shift ;;
    --profile)         PROFILE="$2"; shift 2 ;;
    --parallel)        PARALLEL="$2"; shift 2 ;;
    --stop-on-fail)    STOP_ON_FAIL=true; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --list-profiles)
      jq -r '.profiles | to_entries[] | "\(.key)\t\(.value.title)\t" + (if (.value.ids|type)=="string" then .value.ids else (.value.ids|join(",")) end)' "$PROFILES" \
        | column -t -s$'\t'
      exit 0 ;;
    -h|--help)
      sed -n '1,100p' "$SCRIPT_DIR/readme.txt"; exit 0 ;;
    *) log_warn "[12] Unknown arg: $1"; shift ;;
  esac
done

# ---------- profile resolution ----------
PROFILE_TITLE=$(jq -r --arg p "$PROFILE" '.profiles[$p].title // ""' "$PROFILES")
if [ -z "$PROFILE_TITLE" ]; then
  log_err "[12] Profile '$PROFILE' not found in profiles.json"; exit 2
fi
RAW_IDS=$(jq -r --arg p "$PROFILE" '.profiles[$p].ids' "$PROFILES")
if [ "$RAW_IDS" = '"*"' ] || [ "$RAW_IDS" = "*" ]; then
  IDS=$(registry_list_ids | grep -v '^12$' | sort -n | tr '\n' ' ')
else
  IDS=$(jq -r --arg p "$PROFILE" '.profiles[$p].ids[]' "$PROFILES" | tr '\n' ' ')
fi
COUNT=$(echo $IDS | wc -w)
write_install_paths \
  --tool   "All-dev-tools orchestrator (profile=$PROFILE)" \
  --source "$PROFILES (resolves to script ids: $(echo $IDS | tr ' ' ','))" \
  --temp   "$ROOT/.logs/12/<TS>" \
  --target "Per-script targets (delegated) + summary at $SUMMARY_JSON / $SUMMARY_MD"
log_info "[12] Orchestrator starting (profile=$PROFILE, parallel=$PARALLEL)"
log_info "[12] Profile '$PROFILE' -> $COUNT scripts: $(echo $IDS | tr ' ' ',')"

if [ "$VERB" = "uninstall" ]; then
  IDS=$(echo $IDS | tr ' ' '\n' | tac | tr '\n' ' ')
  log_info "[12] Uninstall order reversed"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN plan (verb=$VERB):"
  i=0
  for id in $IDS; do
    i=$((i+1))
    folder=$(registry_get_folder "$id")
    echo "  [$i/$COUNT] $id  $folder"
  done
  exit 0
fi

# ---------- runtime state ----------
TS=$(date +%Y%m%d-%H%M%S)
SUMMARY_JSON="$SUMMARY_DIR/run-$TS.json"
SUMMARY_MD="$SUMMARY_DIR/run-$TS.md"
RESULTS_TMP=$(mktemp /tmp/orch-results.XXXXXX) || { log_file_error "/tmp" "mktemp failed"; exit 1; }
trap 'rm -f "$RESULTS_TMP"' EXIT
START_ALL=$(date +%s)

run_one_capture() {
  local id="$1"
  local i="$2"
  local folder rc started elapsed status
  folder=$(registry_get_folder "$id")
  log_info "[12] Running id=$id ($i/$COUNT) verb=$VERB"
  started=$(date +%s)
  if bash "$ROOT/run.sh" -I "$id" "$VERB" >> "$ROOT/.logs/orch-$TS.log" 2>&1; then
    rc=0; status="ok"
  else
    rc=$?; status="failed"
  fi
  elapsed=$(( $(date +%s) - started ))
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$folder" "$status" "$rc" "$elapsed" >> "$RESULTS_TMP"
  if [ "$status" = "ok" ]; then
    log_ok "[12] [$id] OK (${elapsed}s)"
  else
    log_warn "[12] [$id] FAILED rc=$rc (${elapsed}s)"
    if [ "$STOP_ON_FAIL" = "true" ]; then
      log_err "[12] --stop-on-fail set, aborting orchestrator"
      return 99
    fi
  fi
  return 0
}

# ---------- execution ----------
i=0
if [ "$VERB" = "install" ] && [ "$PARALLEL" -gt 1 ]; then
  log_info "[12] Parallel install (N=$PARALLEL) — order preserved per chunk, summary still aggregated"
  cmds=()
  for id in $IDS; do
    i=$((i+1))
    cmds+=("export SCRIPT_ID=12; source '$ROOT/_shared/logger.sh'; bash '$ROOT/run.sh' -I '$id' install >> '$ROOT/.logs/orch-$TS.log' 2>&1; rc=\$?; echo -e '$id\t$(registry_get_folder "$id")\t'\$( [ \$rc -eq 0 ] && echo ok || echo failed )'\t'\$rc'\t0' >> '$RESULTS_TMP'")
  done
  run_parallel "$PARALLEL" "${cmds[@]}" || true
else
  for id in $IDS; do
    i=$((i+1))
    run_one_capture "$id" "$i" || break
  done
fi

# ---------- summary ----------
END_ALL=$(date +%s)
TOTAL_ELAPSED=$(( END_ALL - START_ALL ))
OK_COUNT=$(awk -F'\t' '$3=="ok"{c++} END{print c+0}' "$RESULTS_TMP")
FAIL_COUNT=$(awk -F'\t' '$3=="failed"{c++} END{print c+0}' "$RESULTS_TMP")
SKIP_COUNT=0  # reserved (would require parsing per-script "Already installed" output)

# JSON summary
{
  echo "{"
  echo "  \"timestamp\":     \"$TS\","
  echo "  \"profile\":       \"$PROFILE\","
  echo "  \"profileTitle\":  \"$PROFILE_TITLE\","
  echo "  \"verb\":          \"$VERB\","
  echo "  \"parallel\":      $PARALLEL,"
  echo "  \"totalScripts\":  $COUNT,"
  echo "  \"ok\":            $OK_COUNT,"
  echo "  \"failed\":        $FAIL_COUNT,"
  echo "  \"skipped\":       $SKIP_COUNT,"
  echo "  \"elapsedSeconds\":$TOTAL_ELAPSED,"
  echo "  \"results\": ["
  awk -F'\t' 'BEGIN{first=1} {
    if(!first) print ",";
    first=0;
    printf "    {\"id\":\"%s\",\"folder\":\"%s\",\"status\":\"%s\",\"rc\":%s,\"elapsedSeconds\":%s}", $1,$2,$3,$4,$5
  } END{print ""}' "$RESULTS_TMP"
  echo "  ]"
  echo "}"
} > "$SUMMARY_JSON" || log_file_error "$SUMMARY_JSON" "JSON summary write failed"

# Markdown summary
{
  echo "# Orchestrator Summary — $TS"
  echo ""
  echo "- **Profile**: \`$PROFILE\` — $PROFILE_TITLE"
  echo "- **Verb**: \`$VERB\`"
  echo "- **Parallel**: $PARALLEL"
  echo "- **Total**: $COUNT  |  **OK**: $OK_COUNT  |  **Failed**: $FAIL_COUNT  |  **Elapsed**: ${TOTAL_ELAPSED}s"
  echo ""
  echo "| ID | Folder | Status | RC | Elapsed |"
  echo "|----|--------|--------|----|---------|"
  awk -F'\t' '{printf "| %s | %s | %s | %s | %ss |\n", $1,$2,$3,$4,$5}' "$RESULTS_TMP"
} > "$SUMMARY_MD" || log_file_error "$SUMMARY_MD" "Markdown summary write failed"

log_info "[12] Summary written: $SUMMARY_JSON"
log_info "[12] Summary written: $SUMMARY_MD"
log_ok   "[12] Done: ok=$OK_COUNT failed=$FAIL_COUNT skipped=$SKIP_COUNT total_elapsed=${TOTAL_ELAPSED}s"

# Exit code: 0 if all ok, 1 if any failed
[ "$FAIL_COUNT" -eq 0 ]
