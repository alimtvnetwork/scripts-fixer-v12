# Changelog

All notable changes to this project are documented in this file.

## [v0.212.0] -- 2026-04-27

### Added: Script 68 -- PowerShell sibling of `_schema.sh` for cross-OS validation

`scripts/os/helpers/_schema.ps1` ports the bash strict-JSON-schema validator to PowerShell so a single allowed/required/specs/mutex string can be authored once per record type and shared by both OSes.

**Rule DSL (identical to bash `_schema.sh`):**
- `nestr` non-empty string, `str` string, `bool` boolean, `uid` non-negative integer or numeric string, `nestrarr` array of non-empty strings.
- Mutex pairs: space-separated `a,b`. Both true => ERROR on field `a`.

**Public API (PS-cased; semantics match bash exactly):**
- `Initialize-UmSchemaArray <file> <wrapperKey> [-AllowStrings]` -> `$script:UmNormalizedJson` + `$script:UmNormalizedCount`.
- `Test-UmSchemaRecord <rec> <allowed> <required> <specs> [<mutex>]` -> string[] of TSV rows (`ERROR\tfield\treason` / `WARN\tfield\treason`).
- `Write-UmSchemaReport -Index -File -Rows [-Mode rich|plain]` -> `Write-Log` lines + `$script:UmSchemaErrCount`.
- `Get-UmSchemaRecordName <rec>` -> `.name` / `<missing>` / `<not-an-object>`.

**Implementation note:** no `jq` dependency; uses native `PSCustomObject` introspection. The TSV output contract matches the bash version row-for-row so the same downstream report walker pattern works on both OSes.

**Verified by parity tests** against 13 record cases (valid, missing required, wrong-type for each rule, null, empty string, array-not-array, bad array item, unknown-field typo, mutex conflict, non-object) and all 5 input shapes (single object, array, wrapped, bare-string list with `-AllowStrings`, broken JSON).

**Not yet wired into the four `*-from-json.ps1` loaders** -- they still validate ad-hoc. Adoption is a follow-up that needs its own review pass.

**Files touched:**
- `scripts/os/helpers/_schema.ps1` (new, 294 lines)
- `.lovable/memory/features/windows-schema-validator.md` (new)
- `.lovable/memory/index.md` (+1 entry)
- `scripts/version.json` 0.211.0 -> 0.212.0

## [v0.211.0] -- 2026-04-27

### Hardened: Script 68 -- ACL + audit-trail parity across the three Windows SSH leaves

Audit pass against `gen-key.ps1` (the v0.210.0 baseline) found two gaps in `install-key.ps1` / `revoke-key.ps1` / `gen-key.ps1`. Both closed:

**Gap A -- `revoke-key.ps1` skipped re-hardening the `.ssh\` directory.** After `Move-Item -Force` rewrites `authorized_keys`, only the file ACL was re-asserted; the parent dir was left as-is. If the dir had been widened out-of-band, sshd's StrictModes would silently reject the rewritten file. Now matches `install-key.ps1`: harden parent dir AND file, both via `Set-SshFileAcl`. Failure is fatal (with the exact path + reason) since shipping an unusable key is worse than aborting loudly.

**Gap B -- `gen-key.ps1` silently skipped ledger entry when helper was missing.** `install-key.ps1` and `revoke-key.ps1` already emit a loud WARN with the helper path when `Add-SshLedgerEntry` isn't loaded. `gen-key.ps1` did not, so a generated key with no ledger row would look "unknown" to later install/revoke calls. Now warns with the same message + exact `$ledgerHelper` path.

**Confirmed at parity (no changes needed):** backup-failure-is-fatal, Admin elevation for cross-user writes, atomic write via `.tmp` + `Move-Item`, CODE RED exact-path-and-reason on every file/path failure, ACL re-assertion after writes, per-action ledger entries.

**Known cosmetic follow-up (not done):** `Get-KeyBody` / `Get-KeyFingerprint` / `Get-KeyComment` are duplicated between `install-key.ps1` and `revoke-key.ps1`; could be lifted into `_common.ps1`.

**Files touched:**
- `scripts/os/helpers/revoke-key.ps1` (+1 `Set-SshFileAcl` call on `$sshDir` after Move-Item)
- `scripts/os/helpers/gen-key.ps1` (ledger-helper-missing path now WARNs with `$ledgerHelper` path)
- `scripts/version.json` 0.210.0 -> 0.211.0

## [v0.210.0] -- 2026-04-27

### Hardened: Script 68 -- `gen-key.ps1` adopts shared `Set-SshFileAcl` helper

Refactored `gen-key.ps1` to import `_common.ps1` and replace its inline `icacls` hardening with calls to `Set-SshFileAcl` for `$sshDir`, `$out`, and `"$out.pub"`. Now all three SSH-key scripts (gen, install, revoke) share one ACL hardening codepath: `/inheritance:r`, `/grant:r SYSTEM/Administrators/<user>`, strip `Authenticated Users`/`Everyone`/`Users`, set owner.

**Files touched:**
- `scripts/os/helpers/gen-key.ps1` (inline icacls block -> `Set-SshFileAcl` loop)
- `scripts/version.json` 0.209.0 -> 0.210.0

## [v0.209.0] -- 2026-04-27

### Hardened: Script 68 -- `install-key.ps1` / `revoke-key.ps1` ACL + audit hardening

Both scripts now:
- **Admin elevation:** `Assert-Admin` is called when targeting a different user's profile.
- **Fatal backups:** failed `authorized_keys.<ts>.bak` aborts the run unless `--no-backup` was explicitly passed.
- **ACL enforcement:** `Set-SshFileAcl` runs on the `.ssh\` dir (install-key only at this point) and on `authorized_keys`, re-asserted after `Move-Item -Force`.
- **Ledger audit:** loud WARN if `Add-SshLedgerEntry` is unavailable, including the exact helper path.

New shared helper `Set-SshFileAcl -Path -User [-DryRun]` in `_common.ps1`: disables inheritance, grants Full Control only to SYSTEM / Administrators / target user, strips `Everyone` and `Users`. Captures `icacls` stdout/stderr and emits CODE RED log lines (exact path + captured output) on any non-zero exit.

**Files touched:**
- `scripts/os/helpers/_common.ps1` (+`Set-SshFileAcl`)
- `scripts/os/helpers/install-key.ps1`
- `scripts/os/helpers/revoke-key.ps1`
- `scripts/version.json` 0.208.0 -> 0.209.0

## [v0.208.0] -- 2026-04-27

### Added: Script 68 -- Windows PowerShell parity for edit/remove/purge user

Closes the cross-OS gap: every operation the bash side gained in v0.198..v0.203 is now available on Windows in-process via the same shared-helper architecture.

**New shared helpers in `scripts/os/helpers/_common.ps1`:**
- `Invoke-UserModify` -- mirrors `um_user_modify`: rename, password reset, group add/remove, sudo/admin promote/demote, shell, comment, enable/disable.
- `Invoke-UserDelete` -- mirrors `um_user_delete`: removes the local account; idempotent (missing user is success).
- `Invoke-PurgeHome` -- mirrors `um_purge_home`: deletes the resolved home directory after the account record is gone.

**Refactored leaves to call the helpers in-process** (no per-row script forks):
- `scripts/os/helpers/edit-user.ps1` -- single-user edit CLI.
- `scripts/os/helpers/remove-user.ps1` -- single-user delete CLI.
- `scripts/os/helpers/edit-user-from-json.ps1` (new) -- bulk edit loader; same JSON shapes as `add-user-from-json.ps1` (single object / array / wrapped `{users:[...]}`).
- `scripts/os/helpers/remove-user-from-json.ps1` (new) -- bulk remove loader; also accepts the bare-string shorthand `[ "alice", "bob" ]`.

`scripts/os/run.ps1` learned the matching subverbs (`edit-user`, `edit-user-json`, `remove-user`, `remove-user-json`) with the same alias surface as the bash dispatcher.

**Files touched:**
- `scripts/os/helpers/_common.ps1` (+3 helpers)
- `scripts/os/helpers/edit-user.ps1` (refactor to call helper)
- `scripts/os/helpers/remove-user.ps1` (refactor to call helper)
- `scripts/os/helpers/edit-user-from-json.ps1` (new)
- `scripts/os/helpers/remove-user-from-json.ps1` (new)
- `scripts/os/run.ps1` (+4 subverbs)
- `.lovable/memory/features/windows-user-mgmt-shared-helpers.md` (new)
- `.lovable/memory/index.md` (+1 entry)
- `scripts/version.json` 0.207.0 -> 0.208.0

## [v0.203.0] -- 2026-04-27

### Refactored: Script 68 -- bulk edit/remove loaders apply records in-process

`edit-user-from-json.sh` and `remove-user-from-json.sh` previously forked `bash edit-user.sh` / `bash remove-user.sh` per record. v0.203.0 invokes the new shared helpers directly:

- `um_user_modify <name> [flags...]`
- `um_user_delete <name> [--remove-mail-spool]`
- `um_purge_home <home>`

...all defined in `scripts-linux/68-user-mgmt/helpers/_common.sh`. Per-record fork overhead is gone, behavior is preserved (same flag mapping, same idempotency contract, same CODE RED file/path error reporting).

`remove-user-from-json.sh` keeps its bare-string shorthand (`[ "alice", "bob" ]` -> `[ {name:"alice"}, {name:"bob"} ]`) and continues to add `--yes` semantics implicitly (bulk mode is non-interactive by design).

**Files touched:**
- `scripts-linux/68-user-mgmt/edit-user-from-json.sh` (in-process applicator loop)
- `scripts-linux/68-user-mgmt/remove-user-from-json.sh` (in-process applicator loop)
- `scripts-linux/68-user-mgmt/helpers/_common.sh` (+`um_user_modify` / `um_user_delete` / `um_purge_home`)
- `.lovable/memory/features/user-mgmt-shared-helpers.md` (new)
- `scripts/version.json` 0.202.0 -> 0.203.0

## [v0.198.0] -- 2026-04-27

### Added: Script 68 -- bulk edit + bulk remove from JSON (Linux + macOS)

Mirrors the existing add-from-json shapes for the edit + remove leaves. New subverbs in `scripts-linux/68-user-mgmt/run.sh`:

- `edit-user-json <file.json> [--dry-run]` -> `edit-user-from-json.sh`
- `remove-user-json <file.json> [--dry-run]` -> `remove-user-from-json.sh`

**Per-record schemas (every field optional except `name`):**

`edit-users.json` -- `name`, `rename`, `password`, `passwordFile`, `promote`, `demote`, `addGroups[]`, `removeGroups[]`, `shell`, `comment`, `enable`, `disable`. Mutually-exclusive intents (`promote`+`demote`, `enable`+`disable`) are rejected up front so a half-applied batch is impossible.

`remove-users.json` -- `name`, `purgeHome`, `removeMailSpool`. Also accepts the bare-string shorthand `[ "alice", "bob" ]`.

`remove-user-json` always passes `--yes` to its children (bulk mode cannot be interactive). Removing a missing user is treated as success, so re-running the same JSON is idempotent.

**Example invocations (now in `run.sh --help`):**

```bash
# edit-user-json (bulk; same record fields as edit-user flags)
bash run.sh edit-user-json examples/edit-users.json --dry-run
sudo bash run.sh edit-user-json examples/edit-users.json

# remove-user-json (bulk; --yes is added automatically per record)
bash run.sh remove-user-json examples/remove-users.json --dry-run
sudo bash run.sh remove-user-json examples/remove-users.json
# bare-string shorthand: ["alice","bob"]  -> name-only records
```

**Files touched:**
- `scripts-linux/68-user-mgmt/edit-user-from-json.sh` (new)
- `scripts-linux/68-user-mgmt/remove-user-from-json.sh` (new)
- `scripts-linux/68-user-mgmt/run.sh` (+2 subverbs, expanded examples)
- `scripts-linux/68-user-mgmt/readme.md` (Bulk edit / remove section)
- `.lovable/memory/features/bulk-edit-remove-user-json.md` (new)
- `scripts/version.json` 0.197.0 -> 0.198.0

## [v0.74.0] -- 2026-04-22

### Added: Script 49 (WhatsApp) -- post-uninstall registry + shortcut sweep

`Uninstall-WhatsApp` previously stopped at `Uninstall-ChocoPackage` + `.installed` record purge, leaving leftover HKCU/HKLM keys and Start Menu / Desktop / Taskbar shortcuts behind. v0.74.0 adds a sweep stage that runs immediately after the choco uninstall.

**New cleanup stage (`Invoke-WaPostUninstallCleanup` in `helpers/whatsapp.ps1`):**
1. Reads `config.whatsapp.uninstallCleanup` -- skips entirely if `enabled = false` or the block is missing (logs a clear reason in both cases).
2. **Registry sweep** (`Remove-WaRegistryKeys`): iterates the configured `registryKeys` list, calls `Test-Path` then `Remove-Item -Recurse -Force` on each. Counts removed / missing / failed separately.
3. **Shortcut sweep** (`Remove-WaShortcuts`): iterates `shortcutPaths` (with `%ENV%` expansion via `Expand-WaPath`), deletes both `.lnk` files and Start Menu folders. Handles file vs. container automatically.
4. **AppData sweep (opt-in)**: `appDataPaths` listed but `purgeAppData = false` by default -- logs each existing folder as "kept" so the user knows it survived. Set `purgeAppData = true` to nuke `%LOCALAPPDATA%\WhatsApp`.
5. **Summary line**: one-line `cleanupSummary` with all six counters; logs at `success` if zero failures, `warn` otherwise.

**Default targets covered:**
- Registry: `HKCU/HKLM\Software\WhatsApp`, `HKCU/HKLM\Software\Classes\WhatsApp`, `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\WhatsApp`, `HKCU\...\Run\WhatsApp`, plus HKLM uninstall key.
- Shortcuts: per-user + all-users Start Menu entries (`.lnk` and folder), per-user + public Desktop, Taskbar pin, Start Menu pin.

**Config additions (`config.json -> whatsapp.uninstallCleanup`):**
```json
{
  "enabled": true,
  "removeRegistryKeys": true,
  "removeShortcuts": true,
  "registryKeys": ["HKCU:\\Software\\WhatsApp", "..."],
  "shortcutPaths": ["%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\WhatsApp.lnk", "..."],
  "appDataPaths": ["%LOCALAPPDATA%\\WhatsApp"],
  "purgeAppData": false
}
```

**New log message keys (`log-messages.json`):** `cleanupSkipped`, `cleanupStart`, `cleanupRegKeyRemoved`, `cleanupRegKeyMissing`, `cleanupRegKeyFailed`, `cleanupShortcutRemoved`, `cleanupShortcutMissing`, `cleanupShortcutFailed`, `cleanupAppDataKept`, `cleanupAppDataPurged`, `cleanupSummary`. Missing items log at `info` (not noise), removed at `success`, failures at `error` + always route through `Write-FileError`.

**Uninstall-failure log level:** downgraded `uninstallFailed` log call from `error` to `warn` because the cleanup sweep now follows -- a failed choco uninstall is no longer terminal; the sweep can still recover loose state.

**Error visibility (CODE RED compliance):** every registry / file / appdata failure routes through `Write-FileError` with the full path + the underlying `$_.Exception.Message`. No silent `try{} catch{}` swallows.

**Files touched:**
- `scripts/49-install-whatsapp/config.json` (+30-line `uninstallCleanup` block)
- `scripts/49-install-whatsapp/log-messages.json` (+11 cleanup message keys, downgraded uninstallFailed copy)
- `scripts/49-install-whatsapp/helpers/whatsapp.ps1` (+4 new functions: `Expand-WaPath`, `Remove-WaRegistryKeys`, `Remove-WaShortcuts`, `Invoke-WaPostUninstallCleanup`; `Uninstall-WhatsApp` calls the sweep)
- `spec/2025-batch/03-whatsapp.md` (uninstall-cleanup section + config block)
- `scripts/49-install-whatsapp/readme.md` (uninstall section + version bump)
- `scripts/version.json` 0.73.0 -> 0.74.0

## [v0.73.0] -- 2026-04-22

### Added: Script 49 (WhatsApp) -- direct-download fallback when Chocolatey fails

Resolves the open question logged in `spec/2025-batch/03-whatsapp.md`: Chocolatey's `whatsapp` package occasionally lags or fails outright. Script 49 now silently falls back to the official Microsoft-published installer instead of bubbling a hard failure.

**Trigger conditions (either one fires the fallback):**
1. `Install-ChocoPackage -PackageName "whatsapp"` returns `$false`.
2. Chocolatey reports success but `Get-WhatsAppPath` cannot locate `WhatsApp.exe` in any of the four expected install roots after the run.

**Fallback flow (`Invoke-WhatsAppOfficialInstaller` in `helpers/whatsapp.ps1`):**
1. Read `config.whatsapp.fallback` -- abort with a clear log line if `enabled = false` or `url` is empty.
2. Download `WhatsAppSetup.exe` from `https://web.whatsapp.com/desktop/windows/release/x64/WhatsAppSetup.exe` to `$env:TEMP` (override via `fallback.downloadDir`). TLS 1.2 forced; progress bar suppressed.
3. Reject the download if the file is missing or `< 1 MB` (defensive against stub/captive-portal HTML).
4. Launch installer hidden with `/S` (configurable via `fallback.silentArgs`); enforce `fallback.timeoutSeconds` (default 600s); kill on timeout.
5. Re-run `Get-WhatsAppPath` to verify; record install with `Method = "official-installer"` so `.installed/` tracking distinguishes it from the choco path.

**Config additions (`scripts/49-install-whatsapp/config.json`):**
```json
"fallback": {
  "enabled": true,
  "url": "https://web.whatsapp.com/desktop/windows/release/x64/WhatsAppSetup.exe",
  "fileName": "WhatsAppSetup.exe",
  "downloadDir": "",
  "silentArgs": "/S",
  "timeoutSeconds": 600
}
```

**New log message keys (`log-messages.json`):** `fallbackTriggered`, `fallbackDisabled`, `fallbackDownloading`, `fallbackDownloadOk`, `fallbackDownloadFailed`, `fallbackRunning`, `fallbackInstallerExited`, `fallbackInstallerFailed`, `fallbackVerifyFailed`, `fallbackSuccess`. Every one routes through `Write-Log` with appropriate level (`info`/`warn`/`success`/`error`).

**Error visibility (CODE RED compliance):** every disk/network failure path in the fallback (mkdir, download, verify, exec) calls `Write-FileError` with the exact path + reason, never just `"failed"`.

**Spec update:** `spec/2025-batch/03-whatsapp.md` "Open questions" section is now "Resolved questions" and documents the test recipe (point `chocoPackage` at a bogus name to force the fallback path end-to-end).

**Files touched:**
- `scripts/49-install-whatsapp/config.json` (+11 lines fallback block)
- `scripts/49-install-whatsapp/log-messages.json` (+11 message keys)
- `scripts/49-install-whatsapp/helpers/whatsapp.ps1` (new `Invoke-WhatsAppOfficialInstaller`, `Install-WhatsApp` rewired to call it on both failure branches)
- `spec/2025-batch/03-whatsapp.md` (config block + flow steps + resolved-questions section)
- `scripts/version.json` 0.72.0 -> 0.73.0

## [v0.72.0] -- 2026-04-22

### Added: Mandatory §13 footer rolled out to every spec + script readme

The §13 contributor parity contract added in v0.71.0 required every readme to carry the same Author, Riseup Asia LLC company section, License, and footer tagline as the root template. v0.72.0 rolls that footer out to every existing readme.

**Coverage:**
- 65 spec readmes updated (`spec/*/readme.md`, skipping `00-spec-writing-guide`).
- 52 script-folder readmes updated (`scripts/NN-*/readme.md`).
- 117 files total — same scope the v0.70.0 header pass touched.

**Idempotent marker:** `<!-- spec-footer:v1 -->` — re-running the script is a no-op.

**Footer block contents (verbatim per §5–§8 of the spec writing guide):**
1. `## Author` — centered H3 link to Md. Alim Ul Karim, title row, 20+ years bio with bolded year counts (.NET 18+, JS 10+, TS 6+, Go 4+), Crossover top 1% callout, Stack Overflow + LinkedIn stats, 5-row contact table.
2. `### Riseup Asia LLC — Top Software Company in Wyoming, USA` — full company description, 4-pillar bullet list with emoji prefixes, 4-row contact table.
3. `## License` — MIT block + copyright + MIT badge linked to `../../LICENSE`.
4. **Centered italic tagline** — links back to the spec writing guide so contributors land on the canonical contract.

**Relative link strategy:**
- Spec readmes (`spec/<name>/readme.md`) link `../../LICENSE` and `../00-spec-writing-guide/readme.md`.
- Script readmes (`scripts/NN-name/readme.md`) link `../../LICENSE` and `../../spec/00-spec-writing-guide/readme.md`.
- All paths verified to resolve from each file's own directory.

**Why a script and not 117 hand edits:** scoped Python pass at `/tmp/apply_footer.py` reads each readme, checks for `<!-- spec-footer:v1 -->`, and appends the canonical block only if absent. The header pass from v0.70.0 used the same pattern with `<!-- spec-header:v1 -->` — both markers now exist on every file, giving CI a simple grep-based audit hook.

## [v0.71.0] -- 2026-04-22

### Added: §13 "Contributing — Mandatory parity with the root template"

Appended a new §13 to `spec/00-spec-writing-guide/readme.md` that codifies a hard requirement: every new readme (root, spec, script, settings) MUST include the same five canonical blocks the root template uses — icon, 6+ badges, Author section, Riseup Asia LLC company section, and License + footer.

The section spells out:

- **What is mandatory** — the five blocks, each cross-referenced to the existing §2/§3/§5/§6/§7-8 of the guide.
- **Why parity is enforced** — brand consistency, search/LLM indexing, and CI audit-ability.
- **What "verbatim" allows** — bullet reordering inside the Riseup Asia "Core expertise" list and localized prose, but never altered names, headings, or contact tables.
- **PR rejection criteria** — explicit, scannable list of failures that block merge on sight (missing sections, renamed company heading, paraphrased contact tables, removed years-of-experience callout).

The §12 quick-commit checklist is preserved unchanged so it stays the at-a-glance "shippable" gate; §13 is the longer-form contributor contract sitting beneath it.

## [v0.70.2] -- 2026-04-22

### Fixed: User-facing scripts-fixer-v12 install URLs migrated to gitmap-v6

Three concrete user-facing references to the legacy `scripts-fixer-v12` repo slug were updated to `gitmap-v6`:

| File | Line | Change |
|------|------|--------|
| `run.ps1` | 1894 | `--version` output Readme link → `gitmap-v6/blob/main/readme.md` |
| `spec/install-bootstrap/readme.md` | 418 | Sample shell log "Cloning from" URL → `gitmap-v6.git` |
| `spec/install-bootstrap/readme.md` | 429 | TEMP-fallback sample log "Cloning from" URL → `gitmap-v6.git` |

**Intentionally NOT changed (design-doc references, not install URLs):**

- `spec/install-bootstrap/readme.md` line 45 — illustrates the historical `scripts-fixer-vN` family naming scheme inside `## Why this matters`. Renaming would invalidate the algorithm description.
- `spec/install-bootstrap/readme.md` line 256 — release/bump checklist references the legacy `-vN` convention; the spec describes how a *future* `-vN` rollout would work.
- `changelog.md` — historical entries naming the old slug are preserved for audit accuracy.

A repo-wide grep confirms zero remaining live install URLs point at `scripts-fixer-v12`.

## [v0.70.1] -- 2026-04-22

### Fixed: Root readme verification pass

Audited the root `readme.md` against the live GitHub render and the spec writing guide. Three concrete defects fixed; one upstream issue surfaced for the maintainer.

**Fixed in this commit:**
- Stale version badge `Version-v0.67.0` → `Version-v0.70.0` (line 15).
- One-liner install + manual-clone URLs pointed at the wrong repo (`scripts-fixer-v12`); switched to `gitmap-v6` (lines 78, 84, 90, 91).
- Footer tagline used `--` em-dash impostor (banned by spec writing guide §11) → replaced with real `—`.

**Verified clean:**
- Centered header renders correctly: blank lines around `<div align="center">` are present (required for GitHub markdown inside divs).
- Icon size attributes (`width="160" height="160"`) preserved.
- All 10 header badges resolve.
- "At a Glance" 3×2 table uses `<table>` with blank lines around `<td>` content (required for markdown inside cells).
- Internal anchors `#what-it-does` and `#databases-18-29` resolve to existing headings.

**Surfaced (not fixed — needs maintainer decision):**
The repository at `https://github.com/alimtvnetwork/gitmap-v6` currently hosts a **different project** (a Go CLI named "GitMap") with its own `README.md`. This Lovable workspace's `readme.md` (Dev Tools Setup Scripts) has not been pushed to that repo — there is no `readme.md` (lowercase) at `gitmap-v6/main`, only the Go project's `README.md` (uppercase). Either:
1. This Lovable project should push to a different repo slug (and all badge links + clone URLs need updating again), or
2. The intent is to *replace* the Go project's README — in which case the file should also be renamed `readme.md` → `README.md` to match GitHub's case-sensitive default README discovery.

Until the canonical repo question is resolved, the badge URLs in the readme will not render live status against any deployed CI.

## [v0.70.0] -- 2026-04-22

### Added: Mandatory spec header rolled out to every spec + script readme

Every readme under `spec/` (65 files) and `scripts/NN-*/` (52 new stub files) now opens with the mandatory header defined in `spec/00-spec-writing-guide`:

- Centered icon (`assets/icon-v1-rocket-stack.svg`, reused project-wide).
- 6-badge row: PowerShell, Windows, Script #NN, License, Version, Changelog, Repo.
- Centered title + tagline + horizontal rule separator.
- Idempotent marker (`<!-- spec-header:v1 -->`) so future runs skip already-headed files.

**Coverage:**
- 65 spec readmes updated (skipping `spec/00-spec-writing-guide/readme.md`, which is the guide itself).
- 52 new `scripts/NN-*/readme.md` stubs created with header + 4-section body (Overview / Quick start / Layout / See also) linking back to the matching spec.
- Existing per-script content (e.g. `spec/53-script-fixer-context-menu/readme.md`, 727 lines) is preserved — header is prepended, body is untouched.

**Why a script and not 117 hand edits:** scoped Python pass at `/tmp/apply_headers.py` reads each readme, checks for the marker, and prepends the canonical header block only if missing. Re-running it is a no-op.


## [v0.69.0] -- 2026-04-22

### Fixed: CI badge placeholders replaced with canonical repo slug

All `OWNER/REPO` placeholders in script 53 test harness documentation have been replaced with the canonical slug `alimtvnetwork/gitmap-v6`. The badge and workflow links now point to the correct repository. No remaining placeholder instances exist in the project.

**Verification:**
- Badge SVG URL resolves (returns "no status" until first workflow run -- expected).
- Workflow page URL resolves to the correct repository.
- Full-project search confirms zero remaining `OWNER/REPO` strings.

## [v0.68.0] -- 2026-04-22

### Added: Root readme polish + spec writing guide

The root `readme.md` header has been rebuilt around a new project icon and a richer badge row, and a brand-new "At a Glance" 6-card grid sells the project value before users scroll into the long-form sections.

**Root icon (3 variants under `assets/`)**

| Variant | Concept | Palette |
| --- | --- | --- |
| `icon-v1-rocket-stack` *(default in root readme)* | Rocket launching over stacked code/log lines -- "ship a dev box fast". | Indigo -> violet -> pink with cream rocket. |
| `icon-v2-cube-gear` | Isometric cube with a gear on the top face on a dark grid -- "modular building blocks". | Slate background, sky/violet/purple cube faces. |
| `icon-v3-terminal-bolt` | Terminal window with prompt + lightning bolt -- "automated shell power". | Emerald-on-near-black, amber bolt. |

Each variant ships as both `.svg` (used in markdown) and `.png` (256x256 fallback). To switch the canonical icon, edit the `<img src="assets/...">` reference at the top of `readme.md`.

**Header upgrades**

- Centered icon (160px) above the H1 title.
- Badge row expanded from 5 to 10 shields: PowerShell, Windows, Scripts, Tools, Databases, License, Version, Changelog, CI, Maintained -- all with coordinated colors and logos.
- New "At a Glance" 3x2 card grid covering: One-Liner Install, 51 Modular Scripts, Interactive Menu, Keyword Install, Smart Dev Directory, Self-Healing.

**New: `spec/00-spec-writing-guide/readme.md`**

A mandatory style guide that locks down how every readme in the repo is written so future contributors (and AI models handed the spec) produce consistent docs. It covers:

- Required header anatomy (icon + H1 + tagline + badges + pitch).
- Icon rules (svg + png, 3 variants, naming, viewBox, no external fonts).
- Badge rules (minimum 6, the 6 mandatory categories, color palette).
- "At a Glance" card grid template with the HTML-table-with-blank-lines trick.
- Canonical Author section (centered name, years-of-experience callout, contact table).
- Canonical "Riseup Asia LLC -- Top Software Company in Wyoming, USA" company section with the four pillars.
- License, footer, per-script spec checklist, style conventions, banned patterns, and a final pre-commit checklist.

---

## [v0.67.0] -- 2026-04-22

### Added: Three concept icons for script 53 (script-fixer)

Three SVG + PNG icon concepts have been added under `scripts/53-script-fixer-context-menu/assets/` so a canonical project icon can be picked. All icons are 256x256 with rounded-square containers and use semantic gradients only (no raster artwork, fully scalable).

| Variant | Concept | Palette |
| --- | --- | --- |
| `icon-v1-wrench-brackets` | Hex wrench cutting through `< >` code brackets -- the classic "fix the code" metaphor. | Indigo -> cyan with amber/orange tool. |
| `icon-v2-shield-spark` *(default in readme)* | Shield holding a lightning-bolt spark -- "guardian that repairs". | Slate background, cyan shield, yellow bolt. |
| `icon-v3-terminal-tools` | Terminal window with prompt + checkmark over crossed wrench/screwdriver -- toolbox aesthetic. | Emerald -> sky gradient. |

Each variant ships as both `.svg` (source-of-truth, used in markdown) and `.png` (256x256, for places that cannot render SVG -- e.g. Windows shell icons via later conversion to `.ico`).

The `tests/readme.md` now opens with the v2 icon at the top and includes an "Icon options" table showing all three side-by-side. To switch the canonical icon, change the `<img src="...">` reference at the top of that readme to the desired filename.

---

## [v0.66.0] -- 2026-04-22

### Added: CI/CD test workflow + status badge for script 53 test harness

A new GitHub Actions workflow (`.github/workflows/test-script-53.yml`) runs the script 53 test harness on every push and PR that touches `scripts/53-script-fixer-context-menu/**`. The workflow installs script 53 first (so the harness pre-flight finds the registry keys), runs `run-tests.ps1 -Json` with `-JsonPath`, and uploads the resulting `script-53-results.json` as a build artifact (30-day retention).

A status badge has been added to the top of `scripts/53-script-fixer-context-menu/tests/readme.md`:

```markdown
[![Test Script 53](https://github.com/alimtvnetwork/gitmap-v6/actions/workflows/test-script-53.yml/badge.svg?branch=main)](https://github.com/alimtvnetwork/gitmap-v6/actions/workflows/test-script-53.yml)
```

#### Workflow design notes

- Runs on `windows-latest` (the harness needs `HKCR:` / `HKCU:` registry access)
- Triggered only by changes under `scripts/53-script-fixer-context-menu/**` to avoid wasting CI minutes on unrelated edits
- `workflow_dispatch` enabled for manual reruns
- Honors the harness exit codes directly (0 = pass, 1 = fail, 2 = pre-flight failure) -- non-zero turns the badge red

---

## [v0.65.0] -- 2026-04-22

### Removed: schema identifier from test harness JSON output

The `schema` field (`"lovable.scriptfixer.testharness/v1"`) has been removed from the `-Json` output. The document is self-evident -- the consumer (you or your CI) already knows what it is. This eliminates unnecessary branding leakage and keeps the payload lean.

### Changed: readme heading "JSON output schema" → "JSON output"

The documentation now simply refers to the JSON output without a schema version identifier.

---

## [v0.64.0] -- 2026-04-22

### Improved: hardened HKCU / HKCR auto-mounting in the script 53 test harness

The previous mount logic silently swallowed `New-PSDrive` failures and used `-Scope Script`, which broke HKCU probes on PowerShell hosts that start without registry provider access (Constrained Language Mode, JEA endpoints, fresh logins where the user hive isn't attached yet, PS Core in containers).

#### What changed

1. **Registry provider pre-check** -- new `Ensure-RegistryProvider` helper detects when the `Registry` PSProvider isn't loaded and tries `Import-Module Microsoft.PowerShell.Management` to recover. If it still fails, the harness exits 2 with a clean fatal (or fatal-tagged JSON document).

2. **Probe-then-trust** -- `Ensure-RegDrive` now takes a `-ProbePath` parameter. After mounting (or finding a pre-existing mount) it runs `Test-Path` against a known-good path (`HKCR:\CLSID`, `HKCU:\Software`) to verify the provider actually responds. Stale / broken pre-mounted drives are removed and re-mounted.

3. **Global-then-Script scope fallback** -- mounts try `-Scope Global` first so the drive survives nested function calls, then fall back to `-Scope Script` if Global is forbidden by the host policy.

4. **Lazy-load retry** -- if the post-mount probe fails, sleep 200ms and retry once. This catches the race where a freshly-loaded user hive isn't yet readable.

5. **Required vs optional drives** -- HKCR is marked `-Required` (script 53 always installs there). HKCU is optional: if it can't be mounted, the harness emits a yellow WARN, drops all HKCU candidates from the discovery matrix, and continues with HKCR-only probing instead of aborting.

6. **Diagnostics surfaced** -- a new `Registry drives:` block prints in the pre-flight banner showing per-drive `[ok]` / `[!! ]`, the mount action taken (`already-mounted`, `mount`, `remount-stale`), the probe path, and the resulting message.

#### JSON additions

A new top-level `driveMounts[]` array in the JSON output records the same diagnostics for machine consumption:

```jsonc
"driveMounts": [
  { "drive": "HKCR", "root": "HKEY_CLASSES_ROOT", "action": "mount",
    "probe": "HKCR:\\CLSID", "ok": true,  "message": "mounted at -Scope Global" },
  { "drive": "HKCU", "root": "HKEY_CURRENT_USER", "action": "already-mounted",
    "probe": "HKCU:\\Software", "ok": true, "message": "drive present and probe path resolved" }
]
```

This means CI pipelines can now distinguish "no HKCU installation found" from "HKCU drive failed to mount, so we couldn't even check".

#### Exit code semantics

- `0` -- all green (HKCU optional, HKCU may be skipped)
- `1` -- assertions failed
- `2` -- Registry provider unavailable, OR HKCR drive could not be mounted/probed (HKCU failure alone does NOT trigger exit 2)

---

## [v0.63.0] -- 2026-04-22

### Added: `-Json` machine-readable output for the script 53 test harness

The harness can now emit a single structured JSON document instead of human-prose console output, making it easy to capture results in CI pipelines or feed them to other tooling.

#### New parameters

| Parameter   | Default  | Notes                                                                                |
|-------------|----------|--------------------------------------------------------------------------------------|
| `-Json`     | off      | Emit JSON to stdout; suppresses all colored Write-C console output.                  |
| `-JsonPath` | (stdout) | When set with `-Json`, writes the JSON document to this file path instead of stdout. Confirmation line goes to stderr. |

#### Usage

```powershell
# Capture full results to a file via pipe
.\run.ps1 -I 53 verify -Json | Out-File results.json

# Or write directly (clean console kept for confirmation)
.\run.ps1 -I 53 verify -Json -JsonPath results.json

# Discover-only mode also supports -Json (just discovery + hitCount)
.\run.ps1 -I 53 verify -DiscoverOnly -Json
```

#### JSON shape

Top-level keys:

- `mode` -- `"discover"` or `"verify"`
- `scopeFilter`, `hiveFilter` -- echo of `-Scope` / `-Hive` arguments
- `discovery[]` -- every probed (hive, scope) candidate with `hit: true|false`
- `hitCount` -- number of installed scopes detected
- `fatal` -- non-empty only when pre-flight failed (no installation found)
- `summary` -- `{ pass, fail, skip }` totals across all scopes
- `results[]` -- one entry per assertion, each tagged with `scope` + `hive`
- `exitCode` -- mirrors the process exit code (0 / 1 / 2)

#### Per-result tagging

Every assertion in `results[]` is now tagged with the `scope` and `hive` it ran against. This means `-Scope All` produces a single JSON document where you can filter results per scope without re-running the harness.

#### Internal refactor

- `New-Result` helper centralizes result construction
- `Write-C` becomes a no-op when `-Json` is set (stdout stays clean for piping)
- New `Write-Err` helper sends pre-flight + JSON-write confirmations to stderr

---

## [v0.62.1] -- 2026-04-22

### Added: `--discover-only` mode for verify command

The test harness for script 53 now supports `-DiscoverOnly` switch to print the scope/hive detection results and exit without executing registry write test cases.

#### Usage

```powershell
# Print discovery table and exit cleanly
.\run.ps1 -I 53 verify -DiscoverOnly

# Direct invocation
.\scripts\53-script-fixer-context-menu\tests\run-tests.ps1 -DiscoverOnly
```

Output shows installed scope(s) detected under HKCR/HKCU:

```
================================================================
 Discover-only mode -- scope/hive detection complete
================================================================

Found 2 installed scope(s):
    - File on HKCR at HKCR:\*\shell\ScriptFixer
    - Directory on HKCR at HKCR:\Directory\shell\ScriptFixer

To run full verification cases, omit -DiscoverOnly.
```

Exit codes:
- `0` = at least one scope found (discovery successful)
- `2` = no installation detected under any probed scope/hive

---

## [v0.62.0] -- 2026-04-22

### Improved: script 53 harness pre-flight auto-detects scope + hive
