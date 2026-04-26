# Memory: index.md
Updated: just now

# Project Memory

## Core
Project includes PowerShell utility scripts alongside the React web app.
User prefers structured script projects: external JSON configs, spec docs, suggestions folder, colorful logging.
CODE RED: Every file/path error MUST log exact file path + failure reason. Use Write-FileError helper.
Install scripts: no tag → main branch; tag given → STRICT (no fallback, no vN hopping); discovery probes `<prefix>-v1..v20` lowercase parallel. See generic-install-spec.
Never read files under `assets/` (demos/icons are large generated artifacts) — reference by path only.
OneNote install (`onenote` keyword) must do ONLY OneNote. OneDrive disable lives in a separate combo `onenote+rm-onedrive`.

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
- [ZSH theme switcher](mem://features/zsh-theme-switcher) — Script 61: wires `zsh-theme` command into ~/.zshrc with interactive menu + flag mode
- [Models catalog](mem://features/models-catalog) — 90 GGUF models incl. OpenRouter leaderboard open-weight portion (Nov 2025)
- [VS Code Project Manager sync](mem://features/vscode-projects-sync) — `run.ps1 scan <path>` upserts discovered projects into VS Code Project Manager projects.json (match by rootPath, atomic writes, never opens VS Code)
- [Generic install spec (in design)](mem://features/generic-install-spec) — Cross-repo install behavior: strict tag mode, main fallback, v1..v20 parallel discovery. Awaiting 15-item checklist confirmation.
- [Install bootstrap](mem://features/install-bootstrap) — scripts-fixer-vN auto-discovery installers (concrete instance of generic spec)
- [Assets folder no-read](mem://constraints/assets-folder-noread) — Never read assets/ files into context
- [Profile install locations](mem://features/02-profile-install-locations) — Per-profile install location matrix (C:\ system vs E:\dev-tool); README + spec + config.json must stay in sync
