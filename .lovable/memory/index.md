# Memory: index.md
Updated: now

# Project Memory

## Core
Project includes PowerShell utility scripts alongside the React web app.
User prefers structured script projects: external JSON configs, spec docs, suggestions folder, colorful logging.
CODE RED: Every file/path error MUST log exact file path + failure reason. Use Write-FileError helper.

## Memories
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
- [Cross-OS user mgmt (Script 68)](mem://features/04-cross-os-user-mgmt) — Linux+macOS user/group creation; CLI + JSON object/array auto-detect; mirrors Windows os add-user
- [Script 54 scope matrix](mem://features/05-script-54-scope-matrix) — Mutating PS test harness: install/uninstall per -Scope (CurrentUser+AllUsers) with cross-hive bleed detection
- [Cross-OS startup-add (script 64)](mem://features/03-cross-os-startup-add) — Unix-side startup manager: 6 methods, tag-based enumerate/remove
