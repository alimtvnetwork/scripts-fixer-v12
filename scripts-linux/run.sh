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
    # ---- top-level shortcuts to script 64 (cross-OS startup-add) ----
    startup-list|startup-ls)
        VERB="startup-passthrough"; STARTUP_SUB="list"; shift ;;
    startup-remove|startup-rm|startup-del)
        VERB="startup-passthrough"; STARTUP_SUB="remove"; shift; STARTUP_REST=("$@"); break ;;
    startup-add|startup-app)
        VERB="startup-passthrough"; STARTUP_SUB="app";    shift; STARTUP_REST=("$@"); break ;;
    startup-env)
        VERB="startup-passthrough"; STARTUP_SUB="env";    shift; STARTUP_REST=("$@"); break ;;
    startup-prune|startup-purge)
        VERB="startup-passthrough"; STARTUP_SUB="prune";  shift; STARTUP_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 65 (cross-OS os-clean) ----
    os-clean|clean)
        VERB="osclean-passthrough"; OSCLEAN_SUB="run";              shift; OSCLEAN_REST=("$@"); break ;;
    os-clean-list|clean-list|clean-categories)
        VERB="osclean-passthrough"; OSCLEAN_SUB="list-categories";  shift; OSCLEAN_REST=("$@"); break ;;
    os-clean-help|clean-help)
        VERB="osclean-passthrough"; OSCLEAN_SUB="help";             shift; OSCLEAN_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 66 (macOS VS Code menu cleanup) ----
    vscode-mac-clean|vscode-clean-mac|menu-clean-mac)
        VERB="vscmac-passthrough"; VSCMAC_SUB="run";  shift; VSCMAC_REST=("$@"); break ;;
    vscode-mac-clean-list|menu-clean-mac-list)
        VERB="vscmac-passthrough"; VSCMAC_SUB="list"; shift; VSCMAC_REST=("$@"); break ;;
    vscode-mac-clean-help|menu-clean-mac-help)
        VERB="vscmac-passthrough"; VSCMAC_SUB="help"; shift; VSCMAC_REST=("$@"); break ;;
    *) log_warn "Unknown arg: $1"; shift ;;
  esac
done

show_help() {
  cat <<EOF
Linux Installer Toolkit (v0.128.0)

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

Cross-OS startup management (script 64 shortcuts):
  startup-list                 List startup entries created by this toolkit
  startup-remove <name> [...]  Remove a tool-created entry (alias: startup-rm)
      --method M               Limit to one method (autostart|systemd-user|
                               shell-rc-app|launchagent|login-item|shell-rc-env)
      --all                    Remove from every method that holds it
  startup-add <path> [...]     Register an app to run at login
  startup-env  KEY=VALUE       Persist an env var
  startup-prune                Idempotent sweep: remove ALL tool-tagged entries
      --dry-run                Preview only, no changes
      --yes                    Skip the interactive confirmation prompt

Cross-OS cleanup (script 65 shortcuts):
  os-clean                     Sweep temp/caches/trash/pkg-caches/logs (apply mode)
      --dry-run                Preview only, no deletions
      --only A,B,C             Limit to comma-separated category ids
      --exclude A,B,C          Skip these categories
      --yes                    Pre-approve destructive (trash, logs-system)
      --json                   Emit machine-readable summary on stdout
  os-clean-list                Print all defined cleanup categories

macOS VS Code menu cleanup (script 66 shortcuts; macOS only):
  vscode-mac-clean             Remove Finder Services workflows, LaunchAgents/
                               Daemons, Login Items, code/code-insiders shims,
                               and vscode:// LaunchServices handlers.
      --dry-run                Preview every targeted path/label/handler
      --scope user|system      Default 'auto': system if root, else user
      --only A,B,C             Limit to comma-separated category ids
      --edition stable|insiders Limit to one VS Code edition
  vscode-mac-clean-list        Print all defined cleanup categories

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
  startup-passthrough)
    bash "$ROOT/64-startup-add/run.sh" "$STARTUP_SUB" "${STARTUP_REST[@]:-}"
    ;;
  osclean-passthrough)
    bash "$ROOT/65-os-clean/run.sh" "$OSCLEAN_SUB" "${OSCLEAN_REST[@]:-}"
    ;;
  vscmac-passthrough)
    bash "$ROOT/66-vscode-menu-cleanup-mac/run.sh" "$VSCMAC_SUB" "${VSCMAC_REST[@]:-}"
    ;;
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
