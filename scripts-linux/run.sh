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
    # ---- top-level shortcuts to script 67 (Linux VS Code cleanup) ----
    vscode-clean-linux|vscode-linux-clean|vscode-uninstall-linux)
        VERB="vsclin-passthrough"; VSCLIN_SUB="run";    shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-detect|vscode-linux-clean-detect)
        VERB="vsclin-passthrough"; VSCLIN_SUB="detect"; shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-resolve|vscode-linux-clean-resolve|vscode-resolve-linux|vscode-linux-resolve)
        VERB="vsclin-passthrough"; VSCLIN_SUB="resolve"; shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-list|vscode-linux-clean-list)
        VERB="vsclin-passthrough"; VSCLIN_SUB="list";   shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-help|vscode-linux-clean-help)
        VERB="vsclin-passthrough"; VSCLIN_SUB="help";   shift; VSCLIN_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 70 (Ubuntu WordPress installer) ----
    # `./run.sh install wordpress [args...]`  -> full stack install
    # `./run.sh install wp [args...]`         -> alias of 'wordpress'
    # `./run.sh install wp-only [args...]`    -> only the WordPress component
    # `./run.sh wp [args...]` / `./run.sh wordpress [args...]` -> shortcut without 'install'
    wp|wordpress)
        VERB="wp-passthrough"; WP_SUB="install"; WP_COMP=""; shift; WP_REST=("$@"); break ;;
    wp-only)
        VERB="wp-passthrough"; WP_SUB="install"; WP_COMP="wp-only"; shift; WP_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 68 (group creation) ----
    # Two separate shell scripts in 68-user-mgmt/ that the root orchestrator
    # exposes directly so users don't need to remember the folder path:
    #   ./run.sh add-group <name> [--gid N] [--system] [--dry-run]
    #   ./run.sh add-groups-from-json <file.json> [--dry-run]
    # Aliases provided for natural ordering:  group-add / groups-from-json.
    add-group|group-add)
        VERB="grp-passthrough"; GRP_SUB="cli";  shift; GRP_REST=("$@"); break ;;
    add-groups-from-json|groups-from-json|add-group-from-json|group-from-json)
        VERB="grp-passthrough"; GRP_SUB="json"; shift; GRP_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 68 (user creation) ----
    # Mirrors the add-group shortcuts above. The CLI form takes the same
    # flags as 68-user-mgmt/add-user.sh (incl. --ssh-key / --ssh-key-file
    # which can be repeated). The JSON form auto-detects single object,
    # array, or { "users": [...] } shapes and supports per-record
    # sshKeys (array of inline pubkeys) + sshKeyFiles (array of paths).
    add-user|user-add)
        VERB="usr-passthrough"; USR_SUB="cli";  shift; USR_REST=("$@"); break ;;
    add-users-from-json|users-from-json|add-user-from-json|user-from-json)
        VERB="usr-passthrough"; USR_SUB="json"; shift; USR_REST=("$@"); break ;;
    # ---- top-level shortcut: one-page cheat-sheet for the DIRECT CLI ----
    # surface of script 68 (no JSON required). Read-only, no side effects.
    #   ./run.sh useradm-help        -> users + groups + examples
    #   ./run.sh user-help           -> users only
    #   ./run.sh group-help          -> groups only
    useradm-help|usermgmt-help)
        VERB="useradm-help"; USERADM_SUB="all";   shift; break ;;
    user-help|users-help)
        VERB="useradm-help"; USERADM_SUB="user";  shift; break ;;
    group-help|groups-help)
        VERB="useradm-help"; USERADM_SUB="group"; shift; break ;;
    *)
        # `./run.sh install wordpress [args]` lands here AFTER install was consumed.
        # Re-route it through the wp passthrough so the user-friendly form works.
        if [ "$VERB" = "install" ] && { [ "$1" = "wordpress" ] || [ "$1" = "wp" ] || [ "$1" = "wp-only" ]; }; then
            comp=""
            [ "$1" = "wp-only" ] && comp="wp-only"
            VERB="wp-passthrough"; WP_SUB="install"; WP_COMP="$comp"; shift; WP_REST=("$@"); break
        fi
        if [ "$VERB" = "uninstall" ] && { [ "$1" = "wordpress" ] || [ "$1" = "wp" ] || [ "$1" = "wp-only" ]; }; then
            comp=""
            [ "$1" = "wp-only" ] && comp="wp-only"
            VERB="wp-passthrough"; WP_SUB="uninstall"; WP_COMP="$comp"; shift; WP_REST=("$@"); break
        fi
        log_warn "Unknown arg: $1"; shift ;;
  esac
done

show_help() {
  cat <<EOF
Linux Installer Toolkit (v0.129.0)

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

Linux VS Code uninstaller (script 67 shortcuts; Linux only):
  vscode-clean-linux           Detect install method (apt|snap|deb|tarball|
                               binary|user-config) and remove ONLY the matching
                               packages, files, and configuration.
      --dry-run                Preview every targeted package/path
      --scope user|system      Default 'auto': system if root, else user
      --only A,B,C             Limit to comma-separated method ids
      --skip-detect            Run --only methods without re-probing
  vscode-clean-linux-detect    Detect-only: print which install methods are
                               present, no changes
  vscode-resolve-linux         Detect-only, print SINGLE classification line:
                                 method=<apt|snap|deb|tarball|binary|user-config|none>
                                 edition=<stable|insiders|both>  detail='...'
                               Exit codes: 0=single method, 1=multiple, 2=none.
  vscode-clean-linux-list      Print catalog of methods + probes + steps

Ubuntu WordPress installer (script 70 shortcuts; Ubuntu/Debian only):
  install wordpress            Install full LEMP stack + latest WordPress
      -i, --interactive        Prompt for port / data dir / PHP version /
                               install path / DB name / user / password
      --db mysql|mariadb       Pick DB engine (default: mysql)
      --php 8.1|8.2|8.3|latest Pin PHP version (default: latest)
      --port <n>               MySQL port (default: 3306)
      --datadir <path>         MySQL data directory (default: /var/lib/mysql)
      --path <path>            WordPress install path (default: /var/www/wordpress)
      --site-port <n>          nginx HTTP port (default: 80)
  install wp                   Alias of 'install wordpress'
  install wp-only              Only the WordPress component (assumes prereqs)
  uninstall wordpress          Remove WordPress + nginx vhost (keeps PHP / MySQL)

Group management (script 68 shortcuts; Linux + macOS):
  add-group <name> [opts]      Create one local group via direct CLI args
      --gid N                  Pin numeric GID (auto-assigned if omitted)
      --system                 System group (Linux only; ignored on macOS)
      --dry-run                Print what would happen, change nothing
      Aliases: group-add
  add-groups-from-json <file>  Bulk-create groups from a JSON file. Accepts:
                                 single object  : { "name": "devs", "gid": 2000 }
                                 array          : [ { ... }, { ... } ]
                                 wrapped object : { "groups": [ ... ] }
      --dry-run                Preview every record, change nothing
      Aliases: groups-from-json, add-group-from-json

User management (script 68 shortcuts; Linux + macOS):
  add-user <name> [opts]       Create one local user via direct CLI args
      --password PW            Plain-text password (logged masked only)
      --password-file FILE     Read password from a 0600 file
      --uid N                  Pin numeric UID
      --primary-group G        Primary group (created if missing on Linux)
      --groups g1,g2,...       Supplementary groups (comma-separated)
      --shell PATH             Login shell (default /bin/bash | /bin/zsh)
      --home  PATH             Home dir (default /home/<n> | /Users/<n>)
      --comment "..."          GECOS / RealName
      --sudo                   Add to sudo (Linux) / admin (macOS) group
      --system                 System account (Linux only)
      --ssh-key "<line>"       Inline OpenSSH public key. Repeatable.
      --ssh-key-file <path>    Read keys from a file (one per line, '#'
                               and blanks ignored). Repeatable.
                               Installed to <home>/.ssh/authorized_keys
                               (mode 0600, dir 0700, owner=<user>:<pgroup>).
                               Existing keys preserved, duplicates merged.
                               Key contents NEVER logged -- only fingerprints.
      --dry-run                Print what would happen, change nothing
      Aliases: user-add
  add-users-from-json <file>   Bulk-create users from a JSON file. Accepts:
                                 single object  : { "name": "alice", ... }
                                 array          : [ { ... }, { ... } ]
                                 wrapped object : { "users": [ ... ] }
                               Per-record fields: name, password, passwordFile,
                                 uid, primaryGroup, groups[], shell, home,
                                 comment, sudo, system, sshKeys[], sshKeyFiles[]
      --dry-run                Preview every record, change nothing
      Aliases: users-from-json, add-user-from-json
  useradm-help                 One-page cheat-sheet for the direct-CLI flags
                               (no JSON required). Filtered variants:
                                 user-help    users only
                                 group-help   groups only

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
  vsclin-passthrough)
    # Filter out a stray empty element that some bash versions add when "$@"
    # was empty at the time VSCLIN_REST=("$@") was set.
    _vsclin_filtered=()
    for _a in "${VSCLIN_REST[@]:-}"; do [ -n "$_a" ] && _vsclin_filtered+=("$_a"); done
    if [ "${#_vsclin_filtered[@]}" -gt 0 ]; then
      bash "$ROOT/67-vscode-cleanup-linux/run.sh" "$VSCLIN_SUB" "${_vsclin_filtered[@]}"
    else
      bash "$ROOT/67-vscode-cleanup-linux/run.sh" "$VSCLIN_SUB"
    fi
    ;;
  wp-passthrough)
    _wp_filtered=()
    for _a in "${WP_REST[@]:-}"; do [ -n "$_a" ] && _wp_filtered+=("$_a"); done
    if [ -n "$WP_COMP" ]; then
      bash "$ROOT/70-install-wordpress-ubuntu/run.sh" "$WP_SUB" "$WP_COMP" "${_wp_filtered[@]}"
    else
      bash "$ROOT/70-install-wordpress-ubuntu/run.sh" "$WP_SUB" "${_wp_filtered[@]}"
    fi
    ;;
  grp-passthrough)
    # Filter empties (some bash versions add a stray "" when "$@" was empty
    # at capture time -- same dance as vsclin/wp passthroughs above).
    _grp_filtered=()
    for _a in "${GRP_REST[@]:-}"; do [ -n "$_a" ] && _grp_filtered+=("$_a"); done
    case "$GRP_SUB" in
      cli)
        if [ "${#_grp_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-group.sh" "${_grp_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-group.sh"
        fi
        ;;
      json)
        if [ "${#_grp_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-group-from-json.sh" "${_grp_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-group-from-json.sh"
        fi
        ;;
      *)
        log_err "internal: unknown grp sub '$GRP_SUB'"; exit 64 ;;
    esac
    ;;
  usr-passthrough)
    # Same empty-arg-filter dance as grp/vsclin/wp passthroughs.
    _usr_filtered=()
    for _a in "${USR_REST[@]:-}"; do [ -n "$_a" ] && _usr_filtered+=("$_a"); done
    case "$USR_SUB" in
      cli)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-user.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-user.sh"
        fi
        ;;
      json)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-user-from-json.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-user-from-json.sh"
        fi
        ;;
      *)
        log_err "internal: unknown usr sub '$USR_SUB'"; exit 64 ;;
    esac
    ;;
  useradm-help)
    # One-page cheat-sheet for the direct-CLI surface of script 68.
    # Pure stdout dump -- no helpers loaded, no root required.
    bash "$ROOT/68-user-mgmt/cli-cheatsheet.sh" "${USERADM_SUB:-all}"
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
