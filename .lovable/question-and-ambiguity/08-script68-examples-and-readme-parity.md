# 08 — Script 68 example files + README parity

**Spec reference:** "Create missing example files for script 68
(users/groups JSON variants) and ensure the README examples match the
exact CLI flags and JSON field names."

## Point of confusion

"Missing example files" wasn't enumerated in the spec. An audit of
`scripts-linux/68-user-mgmt/examples/` showed the existing four files
covered:

- `groups.json`           — array of groups
- `users.json`            — array of users (mixed)
- `users-wrapped.json`    — `{ "users": [...] }`
- `user-single.json`      — single object

The leaves and orchestrator support more shapes than that:

- **`group-single.json`** (single-object groups variant — parity with
  `user-single.json`)
- **`groups-wrapped.json`** (`{ "groups": [...] }` — parity with
  `users-wrapped.json`)
- **`users-with-keyfiles.json`** (currently the `sshKeyFiles` field is
  buried as one record inside `users.json`; users browsing the folder
  miss it)
- **`full-bootstrap.json`** (the unified `--spec` shape consumed by
  `orchestrate.sh` — even referenced by name in `orchestrate.sh`'s
  own header comment but the file didn't exist)

Two interpretations of "match the exact CLI flags and JSON field names":

- **Option A — only fix README drift if found.** _Pro:_ minimum diff.
  _Con:_ I audited and the README field names already match the
  loaders 1:1 (`passwordFile`, `primaryGroup`, `sshKeys`, `sshKeyFiles`,
  `system`, `gid`, etc.) and the CLI examples use real flags
  (`--password-file`, `--primary-group`, `--groups`, `--sudo`,
  `--dry-run`). Nothing to "fix".
- **Option B — document every shape + every example file (chosen).**
  _Pro:_ user can land on any example file and immediately see in the
  README how to invoke it; the unified-`--spec` shape becomes a
  first-class documented surface. _Con:_ slightly larger README diff.

## Recommendation / inference used

**Option B.** Created the four missing example files and added a
**Bundled example files** table to the README mapping each file to its
shape and the subverb that consumes it. Also added a documented section
for the unified `--spec` shape used by `useradm-bootstrap` (previously
only described in `orchestrate.sh`'s header comment).

Verification performed in this session:

1. `jq -e .` on every JSON in `examples/` → all 8 parse OK.
2. `add-group-from-json.sh examples/groups-wrapped.json --dry-run` → ok.
3. `add-group-from-json.sh examples/group-single.json --dry-run` → ok.
4. `orchestrate.sh --spec examples/full-bootstrap.json --dry-run` →
   parses both the `groups` and `users` arrays, runs the leaves in the
   correct order, exit 1 only because `/etc/secrets/bob.pw` (referenced
   intentionally as a realistic example) is absent in the sandbox.
5. CLI flag audit: every flag mentioned in README CLI examples
   (`--password`, `--password-file`, `--groups`, `--primary-group`,
   `--shell`, `--comment`, `--sudo`, `--dry-run`, `--gid`) exists in
   `add-user.sh` / `add-group.sh`.
6. JSON field audit: every field in the README user/group tables maps
   to a `jq -r '.<field>'` extraction in `add-user-from-json.sh` /
   `add-group-from-json.sh`. No drift.

## How to revert

Delete:
- `scripts-linux/68-user-mgmt/examples/group-single.json`
- `scripts-linux/68-user-mgmt/examples/groups-wrapped.json`
- `scripts-linux/68-user-mgmt/examples/users-with-keyfiles.json`
- `scripts-linux/68-user-mgmt/examples/full-bootstrap.json`

And revert the additions to `scripts-linux/68-user-mgmt/readme.md`
(the **Bundled example files** table and the **unified `--spec`**
section).