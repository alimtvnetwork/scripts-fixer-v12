# Script 56 — VS Code Folder Context Menu Re-register

Standalone, surgical re-registration of the **"Open with Code"** entry on
the Windows folder context menu. Companion to the heavier Script 10
(`vscode-context-menu-fix`); this one stays small enough to drop into any
other toolkit unchanged.

## What it touches

| Target                    | Registry path                                                      |
|---------------------------|--------------------------------------------------------------------|
| Folder right-click        | `HKCR\Directory\shell\VSCode` (and `\command`)                     |
| Folder background (empty) | `HKCR\Directory\Background\shell\VSCode` (and `\command`)          |
| **NOT** per-file menu     | `HKCR\*\shell\VSCode` is **never** created or modified by this script |

VS Code Insiders mirrors the same paths with `VSCodeInsiders` instead of
`VSCode` and label `Open with Code - Insiders`.

## Verbs

| Verb         | Needs admin | Purpose                                                                                              |
|--------------|-------------|------------------------------------------------------------------------------------------------------|
| `reregister` | yes         | Default. For each enabled edition: if `Code.exe` is on disk → write keys; otherwise → delete keys.   |
| `remove`     | yes         | Delete the folder + background keys for every enabled edition unconditionally.                       |
| `check`      | no          | Read-only. PASS/MISS per (edition, target). Exit 0 = all green, exit 1 = at least one MISS.          |

## Auto-removal ("removed when it shouldn't be")

`config.json` → `autoRemoveWhenMissing: true` (the default) means
`reregister` will **delete** the folder/background keys for any edition
whose `Code.exe` is no longer on disk. This is the safe behaviour after a
VS Code uninstall — without it, dead context-menu entries point at a
nonexistent executable.

Set the flag to `false` if you want `reregister` to log a warning and
leave the stale keys alone.

## Usage

```powershell
# Re-register folder + background entries for every enabled edition.
# Auto-removes editions whose Code.exe is gone.
.\run.ps1 -I 56 -- reregister

# Limit to one edition.
.\run.ps1 -I 56 -- reregister -Edition stable

# Read-only audit.
.\run.ps1 -I 56 -- check

# Wipe every key created by this script.
.\run.ps1 -I 56 -- remove
```

## Why a new script (instead of extending Script 10)

Script 10 owns a 470-line install-state + invariant + smoke pipeline.
Script 52 owns the inverse "I deliberately want the folder entry removed"
flow. Script 56 is the **smallest possible** primitive that does just one
thing — restore the folder/background entries in place — so it can be
called from a scheduled task (e.g. after a VS Code update wipes the keys)
without dragging in the full repair/check apparatus. Use Script 10 when
you also need invariant enforcement, granular CI exit codes, or an audit
trail under `.audit/snapshots/`.

## Files

| File                       | Purpose                                                              |
|----------------------------|----------------------------------------------------------------------|
| `run.ps1`                  | Entry point. Verbs: `reregister`, `remove`, `check`.                 |
| `config.json`              | Edition list, registry paths, executable paths, `autoRemoveWhenMissing`. |
| `log-messages.json`        | All user-facing strings (with `{name}`/`{path}` placeholders).        |
| `helpers/registry.ps1`     | Small `Set-`/`Remove-`/`Test-FolderContextMenuKey` + `Resolve-VsCodeExe`. |
| `tests/01-syntax.ps1`      | Parser + dispatch + config integrity test. Runs on Linux pwsh.       |