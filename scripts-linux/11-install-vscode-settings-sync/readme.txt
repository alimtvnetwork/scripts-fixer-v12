11-install-vscode-settings-sync
===============================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

Title:    Deploy VS Code settings.json + keybindings.json + recommended extensions
Method:   Copy payload/* into ~/.config/Code/User/ with timestamped backup of any existing files
Payload:  payload/settings.json, payload/keybindings.json, payload/extensions.txt
Backup:   ~/.config/Code/User/.backup-YYYYMMDD-HHMMSS/
Verify:   both settings.json and keybindings.json exist in user dir

Note: Extensions install only if 'code' CLI is on PATH (skipped otherwise, not a failure).
