#!/usr/bin/env bash
# Root dispatcher for Linux installer toolkit.
# Verbs:
#   install | check | repair | uninstall      (per-script or all)
#   health           system-wide doctor: ok/drift/broken/uninstalled per id + summary
#   repair-all       run install for every id whose health is drift|broken|uninstalled
#                    (skip ok). Honors --only-drift to limit to broken installs.
#   --list           list all registered scripts
#   -I <id>          restrict to a single script id
#   --parallel N     run N installs in parallel (install verb only)
#   --json           (health only) emit machine-readable JSON to stdout
#   --only-drift     (repair-all only) only repair ids with state=drift
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
export DOCTOR_ROOT="$ROOT"
export SCRIPT_ID="root"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/parallel.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/registry.sh"
. "$ROOT/_shared/doctor.sh"

VERB=""; ONLY_ID=""; PARALLEL=1; JSON_OUT=0; ONLY_DRIFT=0

while [ $# -gt 0 ]; do
  case "$1" in
    install|check|repair|uninstall|health|repair-all) VERB="$1"; shift ;;
    --list)        VERB="list"; shift ;;
    -I)            ONLY_ID="$2"; shift 2 ;;
    --parallel)    PARALLEL="$2"; shift 2 ;;
    --json)        JSON_OUT=1; shift ;;
    --only-drift)  ONLY_DRIFT=1; shift ;;
    -h|--help)     VERB="help"; shift ;;
    *) log_warn "Unknown arg: $1"; shift ;;
  esac
done

show_help() {
  cat <<EOF
Linux Installer Toolkit (v0.118.0)

Per-script verbs:
  install              Install
  check                Verify install state
  repair               Re-run install for a single id
  uninstall            Remove

System-wide verbs:
  --list               List all registered scripts
  health               Doctor: report ok | drift | broken | uninstalled per id
                         --json   emit machine-readable JSON
  repair-all           Run install for every id whose health != ok
                         --only-drift   only repair ids in drift state

Flags:
  -I <id>              Restrict to a single script id
  --parallel <N>       Run N installs in parallel (install verb only)
EOF
}

run_one() {
  local id="$1" verb="$2"
  local folder script
  folder=$(registry_get_folder "$id")
  if [ -z "$folder" ]; then log_err "Unknown script id: $id"; return 1; fi
  script="$ROOT/$folder/run.sh"
  if [ ! -f "$script" ]; then
    log_file_error "$script" "script not yet implemented (phase pending)"
    return 0
  fi
  log_info "[$id] $verb -> $folder"
  bash "$script" "$verb"
}

verb_health() {
  local rows
  rows=$(doctor_run_all)
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local out_json="$ROOT/.summary/health-$ts.json"
  local out_md="$ROOT/.summary/health-$ts.md"
  mkdir -p "$ROOT/.summary" || log_file_error "$ROOT/.summary" "mkdir failed"

  local ok_n=0 drift_n=0 broken_n=0 uninst_n=0 miss_n=0
  while IFS=$'\t' read -r id folder state age detail; do
    case "$state" in
      ok)             ok_n=$((ok_n+1)) ;;
      drift)          drift_n=$((drift_n+1)) ;;
      broken)         broken_n=$((broken_n+1)) ;;
      uninstalled)    uninst_n=$((uninst_n+1)) ;;
      missing_script) miss_n=$((miss_n+1)) ;;
    esac
  done <<< "$rows"

  if [ "$JSON_OUT" -eq 1 ]; then
    {
      echo "{"
      echo "  \"timestamp\": \"$ts\","
      echo "  \"summary\": {\"ok\":$ok_n,\"drift\":$drift_n,\"broken\":$broken_n,\"uninstalled\":$uninst_n,\"missing_script\":$miss_n},"
      echo "  \"results\": ["
      local first=1
      while IFS=$'\t' read -r id folder state age detail; do
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {"id":"%s","folder":"%s","state":"%s","markerAgeSeconds":%s,"detail":"%s"}' \
          "$id" "$folder" "$state" "$([ "$age" = "-" ] && echo null || echo "$age")" "$detail"
      done <<< "$rows"
      echo
      echo "  ]"
      echo "}"
    } | tee "$out_json"
    log_info "Health JSON written: $out_json"
    return 0
  fi

  # human table
  printf '\n%-4s %-32s %-13s %-10s %s\n' "ID" "FOLDER" "STATE" "AGE" "DETAIL"
  printf '%s\n' "------------------------------------------------------------------------------------------------"
  while IFS=$'\t' read -r id folder state age detail; do
    local color age_h
    age_h=$(doctor_age_human "$age")
    case "$state" in
      ok)             color="\033[32m" ;;
      drift)          color="\033[31m" ;;
      broken)         color="\033[33m" ;;
      uninstalled)    color="\033[2m"  ;;
      missing_script) color="\033[35m" ;;
      *)              color=""         ;;
    esac
    printf "${color}%-4s %-32s %-13s %-10s %s\033[0m\n" "$id" "$folder" "$state" "$age_h" "$detail"
  done <<< "$rows"
  printf '\n'
  printf 'Summary: ok=%d  drift=%d  broken=%d  uninstalled=%d  missing_script=%d\n' \
    "$ok_n" "$drift_n" "$broken_n" "$uninst_n" "$miss_n"

  # write markdown
  {
    echo "# Health Report — $ts"
    echo ""
    echo "**Summary:** ok=$ok_n  drift=$drift_n  broken=$broken_n  uninstalled=$uninst_n  missing_script=$miss_n"
    echo ""
    echo "| ID | Folder | State | Marker Age | Detail |"
    echo "|----|--------|-------|------------|--------|"
    while IFS=$'\t' read -r id folder state age detail; do
      printf "| %s | %s | %s | %s | %s |\n" "$id" "$folder" "$state" "$(doctor_age_human "$age")" "$detail"
    done <<< "$rows"
  } > "$out_md" || log_file_error "$out_md" "health markdown write failed"
  log_info "Health report written: $out_md"

  # exit non-zero if anything is in drift or missing_script (CI signal)
  [ "$drift_n" -eq 0 ] && [ "$miss_n" -eq 0 ]
}

verb_repair_all() {
  local rows
  rows=$(doctor_run_all)
  local targets=() id folder state age detail
  while IFS=$'\t' read -r id folder state age detail; do
    if [ "$ONLY_DRIFT" -eq 1 ]; then
      [ "$state" = "drift" ] && targets+=("$id")
    else
      case "$state" in drift|broken|uninstalled) targets+=("$id") ;; esac
    fi
  done <<< "$rows"

  if [ "${#targets[@]}" -eq 0 ]; then
    log_ok "Nothing to repair (all healthy)"
    return 0
  fi
  log_info "repair-all: ${#targets[@]} target(s): ${targets[*]}"
  local rc_total=0
  for id in "${targets[@]}"; do
    run_one "$id" install || { log_warn "[$id] repair-all: install failed"; rc_total=1; }
  done
  return "$rc_total"
}

case "${VERB:-help}" in
  help) show_help ;;
  list) registry_list_all | column -t -s$'\t' ;;
  health)      verb_health ;;
  repair-all)  verb_repair_all ;;
  install|check|repair|uninstall)
    if [ -n "$ONLY_ID" ]; then
      run_one "$ONLY_ID" "$VERB"
    else
      ids=$(registry_list_ids)
      if [ "$VERB" = "install" ] && [ "$PARALLEL" -gt 1 ]; then
        log_info "Running install in parallel (N=$PARALLEL)"
        cmds=()
        for id in $ids; do cmds+=("bash '$ROOT/run.sh' install -I $id"); done
        run_parallel "$PARALLEL" "${cmds[@]}"
      else
        for id in $ids; do
          run_one "$id" "$VERB" || log_warn "[$id] returned non-zero"
        done
      fi
    fi
    ;;
  *) show_help ;;
esac
