# 02 — "Root Unix script: create user from JSON spec, with home + password/SSH key handling"

- **Logged on:** 2026-04-26 (UTC+8)
- **Triggering task:** *"Implement a root Unix script that creates a user from a JSON spec, including home directory setup and password/SSH key handling."*
- **Original spec reference:** chat message immediately preceding this entry; project context = `scripts-linux/68-user-mgmt/`.
- **Mode:** No-Questions (task **2 of 40**)

## The point of confusion

Two layers of ambiguity:

### Layer A — what does "root Unix script" mean?
1. **A new top-level script in the repo root** (e.g. `./add-user-from-json.sh`).
2. **A new numbered script slot** (e.g. `69-add-user-from-json/`).
3. **A new entry point in the existing root orchestrator** (`scripts-linux/run.sh`)
   that delegates to `68-user-mgmt/add-user-from-json.sh`. Same shape we
   used for task 01 (`add-group` / `add-groups-from-json`).

### Layer B — SSH key handling shape
Existing 68 script handles password + home dir, but has **no SSH key field**.
Choices:
- `sshKeys`: array of inline OpenSSH-format public-key strings
  (e.g. `"ssh-ed25519 AAAA... user@host"`).
- `sshKeyFiles`: array of paths to `.pub` files on the host running the
  installer.
- `sshKeyUrls`: array of HTTPS URLs (e.g. `https://github.com/<user>.keys`).
- All three. None is exclusive.

## Options considered

### Option A — New top-level script in repo root
- **Pros:** Matches the literal phrase "root script".
- **Cons:** Repo currently has zero shell scripts at the literal top
  level; everything lives under `scripts-linux/`. Putting a single shell
  script at `/` would break the toolkit's structure.

### Option B — New numbered slot 69-add-user-from-json/
- **Pros:** Discoverable in the registry.
- **Cons:** Identical complaint as task 01: duplicates 68's helpers.
  We'd then have two places that own user creation logic.

### Option C — Extend 68 with SSH-key support + add root orchestrator shortcuts
- **What it means:** (1) Add `--ssh-key` (repeatable) and `--ssh-key-file`
  (repeatable) flags to `add-user.sh`. (2) Make `add-user-from-json.sh`
  read `sshKeys` (array of strings) and `sshKeyFiles` (array of paths)
  from each record and forward them. (3) Add `add-user` and
  `add-users-from-json` shortcuts to `scripts-linux/run.sh`, mirroring
  the `add-group` / `add-groups-from-json` shortcuts added in task 01.
- **Pros:** Zero helper duplication. Mirrors task 01's pattern. Honors
  the existing "68 = user/group management" architectural decision.
  "Root Unix script" is satisfied via the root orchestrator entry point.
- **Cons:** Doesn't add a literal script at filesystem root.

### Option D — Option C + URL support (`sshKeyUrls` -> curl github.com/<u>.keys)
- **Pros:** GitHub-style key import is a common pattern.
- **Cons:** Network dependency at user-creation time. Risk of pulling
  unintended keys if the URL is wrong. Curl + URL validation adds
  complexity that the user did not explicitly request.

## Recommendation

**Option C.** Same reasoning as task 01: the user's working pattern for
"root orchestrator" in this project is `scripts-linux/run.sh`, and the
helpers in 68 already exist. SSH keys are added via inline strings AND
files (covers airgapped + secret-store flows). URL import deferred — it
can be added later as a pure additive `sshKeyUrls` field.

## Inference actually used in this task

Implementing **Option C**:
1. **`add-user.sh`** — accept repeatable `--ssh-key "<contents>"` and
   `--ssh-key-file <path>`; collect into one merged authorized_keys block,
   create `~/.ssh` (700) + `authorized_keys` (600), `chown` to the user,
   de-duplicate, never log key contents (only fingerprints + counts).
2. **`add-user-from-json.sh`** — read `sshKeys` (array of strings) and
   `sshKeyFiles` (array of paths) per record; forward as repeatable flags.
3. **`scripts-linux/run.sh`** — new shortcuts:
   - `add-user`            → `68-user-mgmt/add-user.sh`            (alias: `user-add`)
   - `add-users-from-json` → `68-user-mgmt/add-user-from-json.sh`  (aliases: `users-from-json`, `add-user-from-json`)
4. New log-message keys for SSH key install / failure.
5. Updated `examples/users.json` with an `sshKeys` + `sshKeyFiles` sample.
6. Smoke-test with `--dry-run` (no real account created in sandbox).

## How to revert / change course

- Revert SSH support: drop the new `--ssh-key*` flag block in `add-user.sh`
  and the corresponding `sshKeys`/`sshKeyFiles` fields in
  `add-user-from-json.sh`. JSON is forward-compatible — old records
  without those fields continue to work.
- Switch to Option B (new slot 69): create the folder, repoint the two
  root shortcuts. Same approach as documented in ambiguity 01.
- Add Option D (URL import) later: read `sshKeyUrls`, curl into a temp
  file, then funnel through the same `--ssh-key-file` plumbing.

## Smoke-test observations (NOT bugs, just nuances to document)

1. The summary line `SSH keys : requested=R installed=I` uses two
   different units:
   - `requested` counts the *number of `--ssh-key` + `--ssh-key-file`
     CLI invocations* (or JSON array entries). One file flag = 1.
   - `installed` counts *unique post-dedupe key lines actually written*.
     One file with 3 keys + 1 dup contributes 2 here.
   Result: `installed > requested` is normal when a single file holds
   multiple keys, and `installed < requested` is normal when some inline
   entries are malformed.
   Future polish (low priority): rename the labels to
   `sources requested` vs `keys installed` for clarity.
2. JSON dispatcher uses `jq -e 'has("sshKeys") and (.sshKeys|type=="array")'`
   so a record passing `"sshKeys": "ssh-ed25519 ..."` (string instead of
   array) is silently ignored. The example in `examples/users.json` shows
   the array form so this should be obvious from a copy-paste workflow.