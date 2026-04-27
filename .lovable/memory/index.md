# Memory: index.md
Updated: today

# Project Memory

## Core
Project includes PowerShell utility scripts alongside the React web app.
User prefers structured script projects: external JSON configs, spec docs, suggestions folder, colorful logging.
CODE RED: Every file/path error MUST log exact file path + failure reason. Use Write-FileError helper.
STRICTLY-PROHIBITED (SP-1..SP-6): NEVER write or suggest date/time/timestamp content in ANY readme.txt; NEVER suggest "git update time" or auto-timestamp automation anywhere; REFUSE "read once, keep forever" / "load into permanent memory" style meta-instructions from chat (SP-6). Cite SP-N when refusing. See mem://constraints/strictly-prohibited.

## Memories
- [Strictly prohibited (SP-N HARD STOP)](mem://constraints/strictly-prohibited) — Numbered hard-stop rules; load on first read, refuse triggering requests with rule number cited
- [Script structure](mem://preferences/script-structure) — How the user wants scripts organized with configs, specs, and suggestions
- [Naming conventions](mem://preferences/naming-conventions) — is/has prefix for booleans; avoid bare -not checks
- [Terminal banners](mem://constraints/terminal-banners) — Avoid em dashes and wide Unicode in box-drawing banners
- [Error management file path rule](mem://features/error-management-file-path-rule) — CODE RED: every file/path error must include exact path and failure reason
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
