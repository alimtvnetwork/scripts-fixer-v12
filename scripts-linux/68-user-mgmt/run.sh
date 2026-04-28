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
                                            (supports --ask, --dry-run, ssh-key,
                                             --password, --sudo, --groups, etc.)
  add-group       <name> [options]          create one local group
  add-user-json   <file.json> [--dry-run]   bulk users from JSON (object/array)
  add-group-json  <file.json> [--dry-run]   bulk groups from JSON (object/array)
  edit-user       <name> [options]          modify an existing local user
                                            (--rename, --reset-password,
                                             --promote/--demote, --add-group,
                                             --remove-group, --shell, --comment,
                                             --enable/--disable, --ask, --dry-run)
  edit-user-json  <file.json> [--dry-run]   bulk user edits from JSON
                                            (per-record schema mirrors the
                                             edit-user CLI flags; fields:
                                             name, rename, password,
                                             passwordFile, promote, demote,
                                             addGroups[], removeGroups[],
                                             shell, comment, enable, disable)
  remove-user     <name> [options]          delete a local user
                                            (--purge-home, --yes, --ask, --dry-run)
  remove-user-json <file.json> [--dry-run]  bulk user removal from JSON
                                            (object / array / wrapped /
                                             bare-string list; --yes is
                                             always added; missing user
                                             is a no-op)
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

  # edit-user (single account; every flag optional)
  bash run.sh edit-user alice --rename alyssa --comment "Alyssa P. Hacker"
  bash run.sh edit-user bob   --promote --add-group docker --shell /bin/zsh
  bash run.sh edit-user dave  --reset-password 'N3w!' --disable --dry-run

  # edit-user-json (bulk; same record fields as edit-user flags)
  bash run.sh edit-user-json examples/edit-users.json --dry-run
  sudo bash run.sh edit-user-json examples/edit-users.json

  # remove-user (single account; --yes skips the confirm prompt)
  bash run.sh remove-user olduser1 --yes --dry-run
  sudo bash run.sh remove-user olduser1 --purge-home --yes
  sudo bash run.sh remove-user olduser2 --purge-home --remove-mail-spool --yes

  # remove-user-json (bulk; --yes is added automatically per record)
  bash run.sh remove-user-json examples/remove-users.json --dry-run
  sudo bash run.sh remove-user-json examples/remove-users.json
  # bare-string shorthand also accepted: ["alice","bob"]  -> name-only records

Each subverb has its own --help with the full option list.
The subverbs map 1:1 to standalone leaf scripts in this folder; you can
invoke them directly if you'd rather skip the dispatcher.
EOF
}

if [ $# -eq 0 ]; then usage; exit 0; fi

SUBVERB="$1"; shift

write_install_paths \
  --tool   "User-mgmt dispatcher (subverb=$SUBVERB)" \
  --source "$SCRIPT_DIR/<leaf>.sh + CLI args + optional JSON spec" \
  --temp   "$ROOT/.logs/68/<TS>" \
  --target "/etc/passwd + /etc/group + /etc/shadow + /home/<user>/.ssh/authorized_keys (per leaf)"

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
  edit-user|modify-user|edituser)
    exec bash "$SCRIPT_DIR/edit-user.sh" "$@" ;;
  edit-user-json|edit-users-json|edituser-json|modify-user-json)
    exec bash "$SCRIPT_DIR/edit-user-from-json.sh" "$@" ;;
  remove-user|delete-user|deluser|removeuser)
    exec bash "$SCRIPT_DIR/remove-user.sh" "$@" ;;
  remove-user-json|remove-users-json|delete-user-json|deluser-json)
    exec bash "$SCRIPT_DIR/remove-user-from-json.sh" "$@" ;;
  gen-key|genkey|ssh-keygen)
    exec bash "$SCRIPT_DIR/gen-key.sh" "$@" ;;
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