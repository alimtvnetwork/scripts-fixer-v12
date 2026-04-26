#!/usr/bin/env bash
# 68-user-mgmt/cli-cheatsheet.sh -- one-page reference for the DIRECT CLI
# (no JSON) surface of user + group creation. Prints to stdout. Read-only.
#
# Invoked by root shortcuts:
#   ./run.sh useradm-help        full cheat-sheet (users + groups + examples)
#   ./run.sh user-help           users only
#   ./run.sh group-help          groups only
#
# Pass an optional filter as $1: "user" | "group" | "all" (default).
# This script intentionally has NO side effects -- it does not source the
# main helpers, does not require root, and never touches the filesystem.

set -u

CHEAT_FILTER="${1:-all}"
case "$CHEAT_FILTER" in
  user|users)   CHEAT_FILTER="user"  ;;
  group|groups) CHEAT_FILTER="group" ;;
  all|"")       CHEAT_FILTER="all"   ;;
  -h|--help)
    cat <<EOF
Usage: cli-cheatsheet.sh [user|group|all]

Prints a copy-pasteable reference of the direct-CLI flags for creating
local users and/or groups. No flags = print everything.
EOF
    exit 0 ;;
  *)
    printf 'unknown filter: %s (use: user | group | all)\n' "$CHEAT_FILTER" >&2
    exit 64 ;;
esac

_print_groups() {
  cat <<'EOF'
================================================================================
 GROUP creation -- direct CLI (no JSON required)
================================================================================

 Command:
   ./run.sh add-group <name> [options]      (alias: group-add)

 Required:
   <name>                  Group name (positional)

 Options:
   --gid N                 Pin a numeric GID. Auto-assigned if omitted.
   --system                Create as a system group (Linux only; ignored on macOS).
   --dry-run               Print what would happen, change nothing.
   -h | --help             Per-script help.

 Idempotent: re-running on an existing group is a no-op (logged as 'skip').

 Examples:
   # Minimal -- auto-assigned GID
   sudo ./run.sh add-group devs

   # Pin a GID, mark as system
   sudo ./run.sh add-group docker --gid 999 --system

   # Preview only
   ./run.sh add-group qa --gid 2100 --dry-run

EOF
}

_print_users() {
  cat <<'EOF'
================================================================================
 USER creation -- direct CLI (no JSON required)
================================================================================

 Command:
   ./run.sh add-user <name> [options]       (alias: user-add)

 Required:
   <name>                       Login name (positional)

 Password (pick at most one):
   --password PW                Plain text. Logged MASKED only; visible in
                                shell history -- prefer --password-file in CI.
   --password-file FILE         Read from file. File mode must be 0600.

 Identity:
   --uid N                      Pin numeric UID.
   --primary-group G            Primary group. Created if missing on Linux;
                                must already exist on macOS (or use 'staff').
   --groups g1,g2,...           Supplementary groups (comma-separated, no spaces).
   --shell PATH                 Login shell. Default: /bin/bash | /bin/zsh.
   --home PATH                  Home dir.    Default: /home/<n> | /Users/<n>.
   --comment "..."              GECOS field / RealName.

 Privileges:
   --sudo                       Add to 'sudo' (Linux) or 'admin' (macOS).
   --system                     System account (Linux only; ignored on macOS).

 SSH authorized_keys (repeatable; both flags may be combined):
   --ssh-key "<key-line>"       Inline OpenSSH public key (single line).
                                Pass multiple times for multiple keys.
   --ssh-key-file <path>        Read keys from a file (one per line; '#'
                                comments and blanks ignored). Repeatable.

   Installed to <home>/.ssh/authorized_keys with mode 0600 (dir 0700) and
   owner=<user>:<primary-group>. Existing entries preserved. Duplicates
   merged. Key bodies NEVER logged -- only SHA-256 fingerprints.

 Misc:
   --dry-run                    Print what would happen, change nothing.
   -h | --help                  Per-script help.

 Idempotent: re-running on an existing user only adjusts group membership
 + password; the create step is skipped.

 Examples:

   # Minimal interactive admin
   sudo ./run.sh add-user alice --password 'Hunter2!' --sudo

   # Service account, pinned UID, no shell
   sudo ./run.sh add-user buildbot \
       --uid 1500 --shell /usr/sbin/nologin \
       --comment "CI build agent" --system

   # Developer with multiple groups + password from file
   sudo ./run.sh add-user bob \
       --password-file /root/secrets/bob.pw \
       --primary-group bob --groups docker,devs,sudo \
       --shell /bin/bash

   # Same user with two SSH keys (one inline, one from a file)
   sudo ./run.sh add-user carol \
       --password 'TempPass1!' --sudo \
       --ssh-key "ssh-ed25519 AAAA...laptop carol@laptop" \
       --ssh-key-file /root/keys/carol-extra.pub

   # Preview the whole thing first
   ./run.sh add-user dave --password 'x' --groups sudo --dry-run

EOF
}

_print_footer() {
  cat <<'EOF'
================================================================================
 Notes
================================================================================

 * All commands above also work without './run.sh' by invoking the leaf
   scripts directly:
       sudo bash scripts-linux/68-user-mgmt/add-user.sh  <args>
       sudo bash scripts-linux/68-user-mgmt/add-group.sh <args>

 * For bulk operations from a JSON spec, use:
       ./run.sh add-users-from-json  examples/users.json
       ./run.sh add-groups-from-json examples/groups.json
   See: scripts-linux/68-user-mgmt/readme.md

 * Every destructive command supports --dry-run. Use it first.

EOF
}

case "$CHEAT_FILTER" in
  group) _print_groups ;;
  user)  _print_users ;;
  all)   _print_groups; _print_users; _print_footer ;;
esac