---
name: Script 68 macOS account creation -- correct home seed + numeric-gid chown
description: add-user.sh on macOS now uses createhomedir for ~/Library skeleton, and SSH chown resolves the numeric primary GID instead of name-based form
type: feature
---

# Script 68 -- macOS perms hardening (v0.174.0)

Two macOS-specific bugs in the v0.140-0.173 series:

1. **Bare `mkdir -p $HOME` on dscl create.** The previous code created
   the home directory as an empty dir without the `~/Library` template,
   relying on first-login to populate it. Apps that touch `~/Library`
   before first login (LaunchAgents, login keychain) failed silently.
2. **Name-based `chown user:groupname` in the SSH install path.** On
   macOS, directory-services group names occasionally differ from
   `/etc/group` entries; chown by name can return "invalid group" even
   though the user clearly exists. Linux is unaffected because
   `getent group` and `id -gn` agree.

## Fix

### `_um_seed_macos_home <user> <home> <numeric-gid>`

Lives in `helpers/_common.sh`. Preferred path: `createhomedir -c -u <user>`
(populates `~/Library`, applies ACLs, sets `0755 user:gid`). Fallback path
(when `createhomedir` is missing on stripped CI runners): `mkdir -p` +
numeric-gid `chown` + `chmod 0755`, with a `macHomeSeededFallback`
warning so the operator knows the `~/Library` skeleton is missing.

### `um_resolve_pg_gid <user>`

Cross-OS numeric primary GID lookup:
1. `id -g <user>` (Linux + macOS, works for any real user)
2. macOS dscl `PrimaryGroupID` fallback (covers the post-`dscl -create`
   getpwnam race)

Empty result is allowed; the caller falls back to the GROUP NAME and
logs `macPgGidMissing`.

### SSH install chown

Was: `chown "$UM_NAME:$UM_PRIMARY_GROUP" "$_ssh_dir" "$_ssh_file"`
Now: numeric-resolve `_pg_gid` once, then `chown "$_chown_target"`
(form `alice:20` not `alice:staff`) on `.ssh` dir AND `authorized_keys`
separately. `.ssh` dir is chowned BEFORE `authorized_keys` is written so
an interrupted run can't leave a root-owned dir blocking sshd. Success
path emits a `sshChownNumeric` info line; failure emits `sshOwnerWarn`
with the exact target.

## Verified (mocked dscl + createhomedir on Linux sandbox)

1. `dscl . -create /Users/alice` runs all 6 record-create calls
2. `createhomedir -c -u alice` runs AFTER dscl create
3. Seeded home contains `~/Library`
4. Home mode = `0755`
5. `.ssh` mode = `0700`, `authorized_keys` mode = `0600`
6. Chown attempted on `.ssh` AND `authorized_keys` with NUMERIC gid
   (`alice:20`), never name-based (`alice:staff`)
7. `macHomeSeeded` and `sshChownNumeric` log lines emit on success;
   `macHomeSeededFallback` / `macPgGidMissing` / `macHomeSeedFail` cover
   the degraded paths with exact path + reason (CODE RED compliant)

## New log keys

| Key                       | When                                              |
|---------------------------|---------------------------------------------------|
| `macHomeSeeded`           | createhomedir succeeded                           |
| `macHomeSeededFallback`   | createhomedir absent; bare mkdir+chown succeeded  |
| `macHomeSeedFail`         | createhomedir present but failed                  |
| `macPgGidMissing`         | `id -g`/dscl returned empty -- chown falls back to name |
| `sshChownNumeric`         | chown succeeded with the numeric `user:gid` form  |

## Linux behaviour unchanged

`um_resolve_pg_gid` returns `id -g`'s output on Linux, which has always
been numeric, so the chown call expands to identical bytes. The
`sshChownNumeric` log just makes the safe form visible.