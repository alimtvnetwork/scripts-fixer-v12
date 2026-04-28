#!/usr/bin/env bash
# scripts-linux/_shared/ensure-summary.sh
# End-of-run summary collector for ensure_tool calls (mirror of
# scripts/shared/ensure-summary.ps1).
#
# Each call to add_ensure_summary records a line. write_ensure_summary prints
# a colored table at the end of the run, optionally also writing JSON to
# .resolved/ensure-summary.json.

# Resolve logger.
__es_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$__es_dir/logger.sh"
fi

# Each entry: "name|friendly|action|version|error"
declare -ga __ENSURE_SUMMARY=()

add_ensure_summary() {
  # Args: --name <n> [--friendly <f>] --action <skipped|installed|upgraded|failed>
  #       [--version <v>] [--error <e>]
  local name="" friendly="" action="" version="" err=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     name="$2"; shift 2 ;;
      --friendly) friendly="$2"; shift 2 ;;
      --action)   action="$2"; shift 2 ;;
      --version)  version="$2"; shift 2 ;;
      --error)    err="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -z "$friendly" ] && friendly="$name"
  __ENSURE_SUMMARY+=("$name|$friendly|$action|$version|$err")
}

clear_ensure_summary() { __ENSURE_SUMMARY=(); }

write_ensure_summary() {
  # Optional flags: --json <path>
  local json_out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ "${#__ENSURE_SUMMARY[@]}" -eq 0 ] && {
    log_info "ensure-summary: nothing to report"
    return 0
  }

  local C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
  local C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_CYAN=$'\033[36m' C_GREY=$'\033[90m'

  local s_skipped=0 s_installed=0 s_upgraded=0 s_failed=0
  local row name friendly action version err color sym
  echo
  printf '%b\n' "${C_BOLD}=== ensure-tool summary ===${C_RESET}"
  printf '%b\n' "${C_GREY}  STATUS    TOOL                          VERSION         NOTE${C_RESET}"
  for row in "${__ENSURE_SUMMARY[@]}"; do
    IFS='|' read -r name friendly action version err <<<"$row"
    case "$action" in
      skipped)   color="$C_GREY";   sym="·"; s_skipped=$((s_skipped+1)) ;;
      installed) color="$C_GREEN";  sym="+"; s_installed=$((s_installed+1)) ;;
      upgraded)  color="$C_CYAN";   sym="↑"; s_upgraded=$((s_upgraded+1)) ;;
      failed)    color="$C_RED";    sym="✗"; s_failed=$((s_failed+1)) ;;
      *)         color="$C_YELLOW"; sym="?" ;;
    esac
    printf '%b  %s %-9s %-29s %-15s %s%b\n' \
      "$color" "$sym" "$action" "$friendly" "${version:-—}" "${err}" "$C_RESET"
  done
  echo
  printf '%b  totals: %s skipped, %s installed, %s upgraded, %s failed%b\n' \
    "$C_BOLD" "$s_skipped" "$s_installed" "$s_upgraded" "$s_failed" "$C_RESET"
  echo

  if [ -n "$json_out" ]; then
    mkdir -p "$(dirname "$json_out")" 2>/dev/null || true
    {
      echo "["
      local i=0 last=$((${#__ENSURE_SUMMARY[@]} - 1))
      for row in "${__ENSURE_SUMMARY[@]}"; do
        IFS='|' read -r name friendly action version err <<<"$row"
        local sep=","; [ "$i" -eq "$last" ] && sep=""
        printf '  {"name":"%s","friendly":"%s","action":"%s","version":"%s","error":"%s"}%s\n' \
          "$name" "$friendly" "$action" "$version" "${err//\"/\\\"}" "$sep"
        i=$((i+1))
      done
      echo "]"
    } > "$json_out" || log_warn "ensure-summary: could not write $json_out"
  fi

  # Non-zero exit when anything failed — mirrors PS behavior so CI catches it.
  [ "$s_failed" -eq 0 ]
}
