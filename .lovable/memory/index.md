# Memory: index.md
Updated: now

# Project Memory

## Core
Project includes PowerShell utility scripts alongside the React web app.
User prefers structured script projects: external JSON configs, spec docs, suggestions folder, colorful logging.
CODE RED: Every file/path error MUST log exact file path + failure reason. Use Write-FileError helper.
NO-QUESTIONS MODE active for next 40 tasks (from 2026-04-26): never call ask_questions; log ambiguities to .lovable/question-and-ambiguity/xx-name.md and proceed with best inference. Resume on user phrase "ask question if any understanding issues".

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
- [Script 68 strict JSON schema](mem://features/15-script-68-strict-json-schema) — add-user-from-json.sh rejects bad records loudly (v0.170.0)
- [Script 01 MIME cleanup](mem://features/14-script-01-mime-cleanup) — VS Code MIME defaults scrub on uninstall (allow-list, sibling-preserving)
- [SSH orchestration spec](mem://specs/01-ssh-orchestration) — Multi-OS SSH orchestrator at scripts-orchestrator/, bash CLI, password->key bootstrap, parallel dispatch, kubeadm v1.31 playbook
- [Script 67 context-menu verifier](mem://features/13-script-67-context-menu-verifier) — Independent post-cleanup scan of Linux desktop/MIME/file-manager surfaces (exit code 4)
- [No-Questions Mode](mem://preferences/no-questions-mode) — 40-task window: never ask the user; log ambiguities to .lovable/question-and-ambiguity/
- [Script 67 binary detector + resolve](mem://features/12-script-67-binary-detector-resolver) — Adds 'binary' install method, two new probe kinds (cmd-no-pkg-owner, symlink-into-roots), and a `resolve` verb that prints single classification line with structured exit code
- [Script 70 WordPress Ubuntu](mem://features/11-script-70-wordpress-ubuntu) — Modular Ubuntu LEMP+WordPress installer with --interactive prompts and root run.sh `wp`/`install wordpress`/`install wp-only` shortcuts
- [Script 54 verbosity switch](mem://features/09-script-54-verbosity-switch) — -Verbosity Quiet|Normal|Debug for verification + audit reports; failures never suppressed
- [os clean-vscode-mac](mem://features/10-os-clean-vscode-mac) — bash macOS cleanup of VS Code Services / code CLI / LaunchServices / login items, plan-then-prompt + audit JSONL
- [Cross-OS user mgmt (Script 68)](mem://features/04-cross-os-user-mgmt) — Linux+macOS user/group creation; CLI + JSON object/array auto-detect; mirrors Windows os add-user
- [Script 54 scope matrix](mem://features/05-script-54-scope-matrix) — Mutating PS test harness: install/uninstall per -Scope (CurrentUser+AllUsers) with cross-hive bleed detection
- [Script 54 audit scope](mem://features/06-script-54-audit-scope) — Every audit JSONL event + change-report row stamps the resolved Windows registry scope (CurrentUser/AllUsers)
- [Script 54 folder+bg coverage](mem://features/07-script-54-folder-bg-coverage) — check/verify + post-op confirm BOTH directory & background verbs exist under resolved scope, list missing sub-keys with exact paths
- [Script 54 scope+admin guidance](mem://features/08-script-54-scope-admin-guidance) — Write-ScopeAdminGuidance: actionable elevation messaging w/ verb-specific rerun commands for install/uninstall/repair/sync
- [Cross-OS startup-add (script 64)](mem://features/03-cross-os-startup-add) — Unix-side startup manager: 6 methods, tag-based enumerate/remove
- [Script 68 sshKeyUrls](mem://features/16-script-68-ssh-key-urls) — Fetch authorized_keys from HTTPS URLs with timeout + allowlist (v0.171.0)
- [Script 68 ssh-key rollback](mem://features/17-script-68-ssh-key-rollback) — Per-run JSON manifests + remove-ssh-keys.sh strip ONLY tracked keys (v0.172.0)
