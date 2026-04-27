---
name: Script 68 ssh-key rollback via per-run manifests
description: add-user.sh / add-user-from-json.sh write a fingerprint manifest per run; remove-ssh-keys.sh strips ONLY those keys from authorized_keys
type: feature
---

# Script 68 -- ssh-key rollback (v0.172.0, counters renamed in v0.173.0)

Closes the loop on the SSH-key install pipeline. Every `add-user.sh` run
that actually appends keys writes a JSON manifest containing the
fingerprint, algorithm, source tag, and literal line of each NEW key
(net-new only -- pre-existing keys are excluded so rollback can never
touch them). `remove-ssh-keys.sh` reads that manifest and removes just
those lines.

## Storage

- Default dir: `/var/lib/68-user-mgmt/ssh-key-runs/` (mode 0700, root)
- Filename: `<run-id>__<user>.json` (mode 0600, root)
- One manifest per `(run-id, user)` tuple. A batch JSON run shares one
  `run-id` so a single rollback undoes the whole batch.

## Manifest schema (v1)

```json
{
  "manifestVersion": 1,
  "runId": "20260427-153045-ab12",
  "writtenAt": "2026-04-27T15:30:45+08:00",
  "host": "myhost",
  "user": "alice",
  "authorizedKeysFile": "/home/alice/.ssh/authorized_keys",
  "scriptVersion": "0.172.0",
  "keys": [
    {
      "fingerprint": "SHA256:abc...",
      "algo": "ssh-ed25519",
      "source": "url:https://github.com/alice.keys",
      "line": "ssh-ed25519 AAAA... alice@host"
    }
  ]
}
```

The literal line is kept as a fallback when fingerprint formats drift
between install and rollback (different `ssh-keygen` versions, exotic
algos). Match priority: fingerprint -> literal line.

## CLI

`add-user.sh` (and `add-user-from-json.sh`) gain:

| Flag                | Default                                   | Notes |
|---------------------|-------------------------------------------|-------|
| `--run-id <id>`     | auto: `YYYYmmdd-HHMMSS-<rand4>`           | batch loader prefixes `batch-` |
| `--manifest-dir D`  | `/var/lib/68-user-mgmt/ssh-key-runs`      | created 0700 root |
| `--no-manifest`     | off                                       | opt-out; rollback impossible |

`remove-ssh-keys.sh`:

```
remove-ssh-keys.sh --list                   # show all tracked runs
remove-ssh-keys.sh --run-id <id> --dry-run  # preview
remove-ssh-keys.sh --run-id <id>            # apply (root)
remove-ssh-keys.sh --manifest <path>        # roll back from arbitrary file
```

## Safety model

1. `authorized_keys` is backed up to `<file>.bak.<YYYYmmdd-HHMMSS>` BEFORE
   any edit. The log line includes the exact restore command.
2. Comments and blank lines in `authorized_keys` are preserved verbatim.
3. Keys whose fingerprint is in the manifest but NOT in the file are
   reported as "already missing" (warning, not error) -- safe to re-run.
4. After successful rollback the manifest is removed so `--list` stays
   accurate. `--keep-manifest` overrides for audit workflows.
5. Re-running rollback after manifest deletion exits `2` with
   `manifestNotFound` -- the operator gets a clear "already done" signal.

## Verified end-to-end

1. Pre-existing manually-added key survives rollback.
2. Both fingerprint-tracked keys removed cleanly.
3. Backup file created with timestamped suffix.
4. Manifest auto-deleted on success.
5. `--list` shows run-id, timestamp, user, key count, source list.
6. `--dry-run` reports identical removal plan, touches nothing.
7. Re-run after rollback returns `2 manifestNotFound` (idempotent signal).

## CODE RED compliance

Every file/path failure path logs the exact path + reason via
`log_file_error` or `manifestWriteFail` / `manifestParseFail` /
`removeWriteFail` / `removeNoAuthKeys`. No silent skips.

## v0.173.0 -- counter rename

The single ambiguous "requested vs installed" pair was split into a
5-stage pipeline so the summary tells the operator exactly what
happened at each step:

| Counter                  | Meaning |
|--------------------------|---------|
| `sources_requested`      | `--ssh-key` + `--ssh-key-file` + `--ssh-key-url` flag count (one per flag, regardless of how many keys each source carries) |
| `keys_parsed`            | Non-blank, non-comment, algo-valid key lines read from all sources -- BEFORE intra-run de-dup |
| `keys_unique`            | `keys_parsed` minus duplicates within this run |
| `keys_installed_new`     | Net-new lines actually appended to `authorized_keys` |
| `keys_preserved`         | Pre-existing lines we left untouched |

Console summary now reads e.g.
`sources=3 parsed=5 unique=2 installed_new=2 preserved=1`.

Old names removed: `UM_SSH_REQUESTED_COUNT`, `UM_SSH_INSTALLED_COUNT`.
New names: `UM_SSH_SOURCES_REQUESTED`, `UM_SSH_KEYS_PARSED`,
`UM_SSH_KEYS_UNIQUE`, `UM_SSH_KEYS_INSTALLED_NEW`,
`UM_SSH_KEYS_PRESERVED`. `sshKeyInstalled` log template now takes 6
args; `sshKeyNoneValid` wording clarified to "source(s)".

## v0.181.0 -- automatic manifest cleanup

The manifest dir grows by one file per `add-user.sh` run. v0.181.0
adds retention-based cleanup so it self-maintains:

### CLI: `remove-ssh-keys.sh --prune`

| Flag                    | Default (config.json)             | Notes |
|-------------------------|-----------------------------------|-------|
| `--older-than DAYS`     | `manifestRetention.olderThanDays` (90) | mtime-based; 0 = disable |
| `--keep-last N`         | `manifestRetention.keepLastPerUser` (20) | per-user retention; 0 = disable |
| `--max-total N`         | `manifestRetention.maxTotal` (500) | dir-wide cap; 0 = disable |
| `--dry-run`             | off                                | preview only, never deletes |
| `--manifest-dir DIR`    | `/var/lib/68-user-mgmt/ssh-key-runs` | override |

Policies are OR-combined and evaluated in order: `olderThanDays` first
(stale files don't count toward the keep budget), then
`keepLastPerUser` (per-user), then `maxTotal` (dir-wide). Manifests are
sorted newest-first before evaluation so the oldest are always the ones
evicted under the count caps.

### Auto-prune on install

`add-user.sh` and `add-user-from-json.sh` (via the same code path) call
the prune helper opportunistically AFTER a successful manifest write.
Best-effort: a prune failure NEVER fails the install -- it logs a clear
warning telling the operator to run `remove-ssh-keys.sh --prune`
manually. Disable with `--no-auto-prune` or `UM_NO_AUTO_PRUNE=1`. Also
disablable via `manifestRetention.autoPruneOnInstall: false`.

### Safety

1. **Corrupt JSON is SKIPPED, never deleted** -- forensics preserved.
   Reported as `skipped=N` in the summary; operator handles by hand.
2. **Non-numeric policy values abort with rc=2** before any delete --
   prevents surprise behaviour from a typo'd `--older-than abc`.
3. **Dry-run always available** for both the verb and the helper.
4. **CODE RED**: every delete failure logs the exact path + a precise
   reason (permission / mount-ro / vanished mid-prune) via
   `manifestPruneRemoveFail` + `log_file_error`.

### Implementation

- Shared helper: `helpers/_manifest_prune.sh` exporting
  `um_manifest_prune` (sourced by both `remove-ssh-keys.sh` and
  `add-user.sh`).
- Config: `config.json -> manifestRetention.{olderThanDays,
  keepLastPerUser, maxTotal, autoPruneOnInstall}`.
- Log keys: `manifestPruneHeader`, `manifestPruneCandidate`,
  `manifestPruneRemoved`, `manifestPruneRemoveFail`,
  `manifestPruneSummary`, `manifestPruneSkipParse`,
  `manifestPruneScanFail`, `manifestPruneNothing`,
  `manifestAutoPruneFail`.

### Verified end-to-end (8 scenarios)

1. Empty dir -> rc=0, "nothing to prune".
2. All-young manifests + age policy -> nothing removed.
3. Mixed young/old + `--older-than 30` -> exactly the old set removed.
4. `--keep-last 2` with 5 same-user files -> 3 oldest removed.
5. `--max-total 1` with 3 files -> 2 oldest evicted.
6. `--dry-run` reports the would-remove plan and touches nothing.
7. Corrupt JSON manifest SKIPPED + counted in summary, file preserved.
8. Non-numeric policy aborts rc=2 before any delete.

## v0.182.0 -- ssh-key install summary JSON export

`add-user.sh` and `add-user-from-json.sh` gain `--summary-json [TARGET]`
to emit the SSH-key install counters as a structured, versioned JSON
document. Failure NEVER fails the install (user has already been
created); CODE-RED logs exact path + reason on every write failure.

### Targets

| TARGET   | Behaviour |
|----------|-----------|
| `auto` (default if flag passed bare) | write to `<manifest-dir>/summaries/<run-id>__<user>.summary.json` (mode 0600, dir 0700 root). Pairs 1:1 with the rollback manifest. |
| `stdout` | append JSON to stdout AFTER the human summary, prefixed by the marker line `---SSH-SUMMARY-JSON---` so wrappers can split. |
| `<path>` | write to that exact path (mode 0600). Parent dir must exist. |

`--no-summary-json` and `UM_NO_SUMMARY_JSON=1` forcibly disable.
`UM_SUMMARY_JSON=<target>` env enables without touching CLI.

### Schema (v1)

```json
{
  "summaryVersion": 1,
  "writtenAt": "<UTC ISO-8601>",
  "host": "<hostname>", "user": "<unix>", "runId": "<rollback-id>",
  "scriptVersion": "0.182.0",
  "authorizedKeysFile": "<path>",
  "summary": {
    "sources_requested":  <n>,
    "keys_parsed":        <n>,
    "keys_unique":        <n>,
    "keys_installed_new": <n>,
    "keys_preserved":     <n>
  },
  "sources": { "inline": <n>, "file": <n>, "url": <n> },
  "manifestFile": "<path|null>",
  "ok": true
}
```

### Batch rollup (`add-user-from-json.sh`)

When the batch loader gets `--summary-json <target>`, it forces every
child into `auto` mode (per-user JSONs always land on disk for the
audit trail), then aggregates them into a batch envelope at
`<manifest-dir>/summaries/<run-id>__BATCH.summary.json` (or the
requested target). Envelope adds `kind:"batch"`, `userCount`, and an
`aggregate` block that sums every counter across users.

### Verified (6 scenarios)

1. `stdout` mode emits valid JSON with marker line + correct counters/sources/manifestFile.
2. `auto` mode writes file at expected path with mode 0600 under dir 0700.
3. Explicit `<path>` writes correctly with mode 0600.
4. `auto` + `--no-manifest` falls back to stdout with a clear warning.
5. Empty target = no-op (rc=0); `UM_NO_SUMMARY_JSON=1` forcibly disables.
6. Nonexistent parent dir → CODE-RED `log_file_error`, no crash.
### Summary JSON validator (v0.183.0)

`verify-summary.sh` (also `run.sh verify-summary`) is a READ-ONLY validator
for the JSON docs `--summary-json` writes. Inputs: `--file`, `--dir`,
`--auto` (= `<UM_MANIFEST_DIR>/summaries`), `--run-id` filter. Output
modes: pretty (default) or `--json` NDJSON + final summary line. Use
`--strict` to promote consistency warnings to errors.

Checks: required top-level fields per kind (per-user vs `kind:"batch"`),
`summaryVersion == 1`, every counter in `summary{}` / `aggregate{}` /
`sources{}` is present, JSON `type=="number"`, integer, `>= 0`, and `ok`
is boolean. Soft consistency warnings: `installed_new + preserved ==
unique`, `unique <= parsed`, `installed_new <= parsed`. Batch docs also
verify `aggregate.X == sum(users[].summary.X)` for all 5 counters as a
hard error. CODE-RED rule honored: every file/parse error logs the exact
path and the precise jq/stat reason.

Verified scenarios: valid per-user pass, malformed JSON (jq parser
error surfaced), negative counter, wrong-type counter (string), batch
aggregate mismatch (hard fail), internal inconsistency (warn by default,
fail under `--strict`), `--run-id` filter narrowing, `--auto` against a
missing summaries dir (CODE-RED log + rc=2).
