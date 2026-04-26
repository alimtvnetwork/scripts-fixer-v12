---
name: Script 54 scope+admin guidance helper
description: Write-ScopeAdminGuidance centralizes elevation messaging for install/uninstall/repair/sync -- prints actionable rerun commands when -Scope AllUsers needs admin, and a CurrentUser fallback that does NOT need admin
type: feature
---
## Centralized scope+admin elevation guidance

`scripts/54-vscode-menu-installer/helpers/vscode-install.ps1` exports
`Write-ScopeAdminGuidance`, called by every entry point right after
`Resolve-MenuScope`:

| Entry point     | Action arg passed |
|-----------------|-------------------|
| install.ps1     | 'install'         |
| uninstall.ps1   | 'uninstall'       |
| repair.ps1      | 'repair'          |
| sync.ps1        | 'sync'            |

### Four cases handled
1. **`-Scope AllUsers` requested + NOT admin** -> BLOCK with banner + two
   numbered options (re-run elevated *or* fall back to CurrentUser),
   each with the exact copy-pasteable command for the verb in play.
2. **Resolved=AllUsers + NOT admin** (defensive) -> BLOCK with single
   ACTION line.
3. **Resolved=AllUsers + admin** -> one-line success log confirming the
   machine-wide write to `HKLM\Software\Classes`.
4. **Resolved=CurrentUser** -> info line confirming HKCU writes.
   - When `-Scope` was OMITTED (Auto), also nudges the user toward
     `-Scope AllUsers` if they want every user on the box to see the menu.
   - When the user explicitly chose `CurrentUser`, the nudge is skipped
     (don't tell them what they already chose).

### Contract
- Returns `[bool]` -- callers gate with `if (-not $mayProceed) { return }`.
- All output goes through `Write-Log` so it lands in both the structured
  JSON log and the colored console.
- Verb-aware rerun commands: every BLOCK message includes
  `.\run.ps1 -I 54 <action> -Scope AllUsers` AND
  `.\run.ps1 -I 54 <action> -Scope CurrentUser`.

Built: v0.131.0. Replaces 4x duplicated inline gate blocks across
install/uninstall/repair/sync (one source of truth).