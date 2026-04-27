#!/usr/bin/env bash
# Controller-side helper: read a saved orchestrator log file (or stdin),
# extract every ---FANOUT-LEDGER-JSON--- line, decode the per-host
# snapshots, and emit a merged JSON document on stdout.
#
# Usage:
#   ./merge-ledgers.sh path/to/audit.log    > merged.json
#   ./run.sh playbook ssh-keys-fanout ... | ./merge-ledgers.sh -
set -u
src="${1:--}"
if [ "$src" = "-" ]; then input=$(cat); else
  if [ ! -f "$src" ]; then
    echo "[FILE-ERROR] path=$src reason=audit log not found" >&2
    exit 2
  fi
  input=$(cat "$src")
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[FILE-ERROR] path=jq reason=jq not installed (required for merge)" >&2
  exit 127
fi

# Pull every JSON object after the marker, decode snapshot_b64,
# tag with source host, concatenate entries.
echo "$input" \
  | grep -- '---FANOUT-LEDGER-JSON---' \
  | sed 's/.*---FANOUT-LEDGER-JSON--- //' \
  | jq -s '
      [ .[]
        | . as $line
        | (.snapshot_b64 // "" | @base64d | try fromjson catch null) as $snap
        | if $snap == null then empty
          else $snap.entries // []
               | map(. + {sourceHost: $line.host, sourceUser: $line.user})
          end
      ]
      | flatten
      | { mergedAt: now | todate, totalEntries: length, entries: . }
    '
