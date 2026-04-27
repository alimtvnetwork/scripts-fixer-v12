#!/usr/bin/env bash
# 68-user-mgmt -- root dispatcher for cross-OS user/group management.
#
# This script is a PURE PASS-THROUGH: it parses the subverb, picks the
# matching leaf script, and forwards every remaining argument unchanged.
# All real work happens in the leaves, which can also be invoked directly.
#
# Subverbs:
#   add-user        <name> [options]            -> add-user.sh
#   add-group       <name> [options]            -> add-group.sh
#   add-user-json   <file.json> [--dry-run]     -> add-user-from-json.sh
#   add-group-json  <file.json> [--dry-run]     -> add-group-from-json.sh
#   bootstrap       [...orchestrator flags...]  -> orchestrate.sh
#                                                  (parse-only root: groups
#                                                   first, then users; shared
#                                                   summary; supports unified
#                                                   --spec, separate --*-json,
#                                                   and inline --group/--user)
#
# Run any subverb with --help for full options.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

usage() {
  cat <<EOF
Usage: ./run.sh -I 68 -- <subverb> [args]
   or: bash scripts-linux/68-user-mgmt/run.sh <subverb> [args]

Subverbs:
  add-user        <name> [options]          create one local user
  add-group       <name> [options]          create one local group
  add-user-json   <file.json> [--dry-run]   bulk users from JSON (object/array)
  add-group-json  <file.json> [--dry-run]   bulk groups from JSON (object/array)
  bootstrap       [orchestrator flags]      parse-only orchestrator: runs all
                                            four leaves in correct order with
                                            a shared summary. See:
                                              bash run.sh bootstrap --help
  verify          [verify.sh flags]         READ-ONLY pass/fail check of the
                                            current user/group state. See:
                                              bash run.sh verify --help
  verify-summary  [verify-summary.sh flags] validate ssh-key install summary
                                            JSON files (schema, required
                                            fields, numeric counters). See:
                                              bash run.sh verify-summary --help

Common flags:
  --dry-run       print what would happen, change nothing
  -h | --help     show this message (or per-subverb help)

Examples:
  bash run.sh add-user alice --password 'P@ss' --groups sudo,docker
  bash run.sh add-group devs --gid 2000
  bash run.sh add-user-json examples/users.json --dry-run
  bash run.sh add-group-json examples/groups.json

Each subverb has its own --help with the full option list.
The subverbs map 1:1 to standalone leaf scripts in this folder; you can
invoke them directly if you'd rather skip the dispatcher.
EOF
}

if [ $# -eq 0 ]; then usage; exit 0; fi

SUBVERB="$1"; shift

case "$SUBVERB" in
  -h|--help|help)
    usage; exit 0 ;;
  add-user)
    exec bash "$SCRIPT_DIR/add-user.sh" "$@" ;;
  add-group)
    exec bash "$SCRIPT_DIR/add-group.sh" "$@" ;;
  add-user-json|add-users-json|user-json)
    exec bash "$SCRIPT_DIR/add-user-from-json.sh" "$@" ;;
  add-group-json|add-groups-json|group-json)
    exec bash "$SCRIPT_DIR/add-group-from-json.sh" "$@" ;;
  bootstrap|orchestrate|all)
    exec bash "$SCRIPT_DIR/orchestrate.sh" "$@" ;;
  verify|check|verify-state)
    exec bash "$SCRIPT_DIR/verify.sh" "$@" ;;
  verify-summary|check-summary|verify-ssh-summary)
    exec bash "$SCRIPT_DIR/verify-summary.sh" "$@" ;;
  *)
    log_err "unknown subverb: '$SUBVERB' (failure: see --help for the list)"
    usage
    exit 64
    ;;
esac