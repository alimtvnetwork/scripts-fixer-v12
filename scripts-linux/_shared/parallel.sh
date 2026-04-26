#!/usr/bin/env bash
# Parallel runner using xargs -P. Falls back to serial if N<=1.

run_parallel() {
  local n="$1"; shift
  local -a items=("$@")
  if [ "${#items[@]}" -eq 0 ]; then return 0; fi
  if [ "$n" -le 1 ]; then
    for item in "${items[@]}"; do
      bash -c "$item" || return $?
    done
    return 0
  fi
  printf '%s\n' "${items[@]}" | xargs -I{} -P "$n" bash -c '{}'
}