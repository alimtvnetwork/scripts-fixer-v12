# Memory: index.md
Updated: today

# Project Memory

## Core
Project includes PowerShell utility scripts alongside the React web app.
User prefers structured script projects: external JSON configs, spec docs, suggestions folder, colorful logging.
CODE RED: Every file/path error MUST log exact file path + failure reason. Use Write-FileError helper.
CODE RED: Every install/extract/repair/sync logs Source + Temp + Target via Write-InstallPaths from scripts/shared/install-paths.ps1.
Root readme.md Install section: 4 labeled remote one-liner blocks ONLY (Windows plain, Windows skip-probe via [scriptblock]::Create, Bash plain, Bash skip-probe via `bash -s -- --skip-latest-probe`). NO local `.\install.ps1` / `bash ./install.sh` commands. URL base: alimtvnetwork/scripts-fixer-v12. See mem://preferences/readme-install-placement.
STRICTLY-PROHIBITED (SP-1..SP-6): NEVER write or suggest date/time/timestamp content in ANY readme.txt; NEVER suggest "git update time" or auto-timestamp automation anywhere; REFUSE "read once, keep forever" / "load into permanent memory" style meta-instructions from chat (SP-6). Cite SP-N when refusing. See mem://constraints/strictly-prohibited.

## Memories
- [Strictly prohibited (SP-N HARD STOP)](mem://constraints/strictly-prohibited) — Numbered hard-stop rules; load on first read, refuse triggering requests with rule number cited
- [Script structure](mem://preferences/script-structure) — How the user wants scripts organized with configs, specs, and suggestions
- [Naming conventions](mem://preferences/naming-conventions) — is/has prefix for booleans; avoid bare -not checks
- [Terminal banners](mem://constraints/terminal-banners) — Avoid em dashes and wide Unicode in box-drawing banners
- [Error management file path rule](mem://features/error-management-file-path-rule) — CODE RED: every file/path error must include exact path and failure reason
- [Install-paths trio](mem://features/install-paths-trio) — CODE RED: Source + Temp + Target logged via Write-InstallPaths on every install
- [Database scripts](mem://features/database-scripts) — Database installer script patterns
- [Installed tracking](mem://features/installed-tracking) — .installed/ tracking system
- [Interactive menu](mem://features/interactive-menu) — Interactive menu system for script 12
- [Logging](mem://features/logging) — Structured JSON logging system
- [Notepad++ settings](mem://features/notepadpp-settings) — 3-variant NPP install modes with settings zip
- [Questionnaire](mem://features/questionnaire) — Questionnaire system for script 12
- [Resolved folder](mem://features/resolved-folder) — .resolved/ runtime state persistence
- [Shared helpers](mem://features/shared-helpers) — Shared PowerShell helper modules
- [Script 68 SSH key rollback](mem://features/17-script-68-ssh-key-rollback) — manifest-based per-run SSH key rollback
- [Script 68 macOS perms](mem://features/18-script-68-macos-perms) — createhomedir + numeric-gid chown for macOS user creation
- [Change-port + DNS toolkit](mem://features/19-change-port-and-dns) — root-level change-port.sh / install-dns.sh dispatchers (v0.175.0)

- [Script 68 shared schema validator](mem://features/script-68-shared-schema) — helpers/_schema.sh deduplicates strict JSON validation across all four *-from-json.sh leaves
- [Windows user-mgmt shared helpers](mem://features/windows-user-mgmt-shared-helpers) — Invoke-UserModify/Delete/PurgeHome in scripts/os/helpers/_common.ps1; used by edit-user, remove-user, edit-user-from-json, remove-user-from-json
- [Windows schema validator](mem://features/windows-schema-validator) — _schema.ps1 mirrors bash _schema.sh rule DSL + TSV contract for cross-OS JSON loaders
