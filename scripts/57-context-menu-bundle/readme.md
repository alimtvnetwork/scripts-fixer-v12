# Script 57 — Context Menu Bundle

One guided command that runs both:

- **Script 31** — PowerShell Here (normal + admin) right-click entries
- **Script 52** — VS Code folder context-menu repair

## Usage

```powershell
# Guided install (prompts per component)
.\run.ps1 57

# Non-interactive
.\run.ps1 57 install -Yes

# Preview only (no registry writes, no admin needed)
.\run.ps1 57 dry-run
.\run.ps1 57 status

# Remove both
.\run.ps1 57 uninstall

# Skip one component
.\run.ps1 57 install -Skip pwsh
.\run.ps1 57 install -Skip vscode
```

## What it does

1. Loads `config.json` listing each component (script id, folder, install/uninstall args, registry targets).
2. For each component, prompts `Y/n` (or auto-accepts with `-Yes`).
3. Invokes the child `run.ps1` with the appropriate verb.
4. Prints a colored summary: title · status · detail (registry paths touched, or exact failure path + reason per the CODE RED rule).

Exits non-zero if any component failed.
