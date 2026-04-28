# Install-paths trio (Source / Temp / Target)

> **CODE RED rule:** every install / extract / repair / sync action MUST surface
> three paths so users always know where work is starting from, where temp
> files land, and where the final artefact ends up.

## Why

When something goes wrong (permission denied, disk full, antivirus quarantine,
half-installed app), the first three questions are always:

1. *Which script started this?*  → **Source**
2. *Where did it write scratch data?*  → **Temp**
3. *Where did it try to install?*  → **Target**

Logging the trio in one block at the start of every install operation makes
those answers free.

## Helper

`scripts/shared/install-paths.ps1` exposes:

```powershell
Write-InstallPaths `
    -Tool   "Notepad++" `
    -Action "Install" `
    -Source $PSCommandPath `
    -Temp   "$env:TEMP\scripts-fixer\notepadpp" `
    -Target "C:\Program Files\Notepad++"
```

It prints a magenta `[ PATH ]` block and appends an `installPaths …` event to
the JSON log via `Write-Log`.

### Convenience

```powershell
$temp = Resolve-DefaultTempDir -ToolSlug "notepadpp"
```

Creates `$env:TEMP\scripts-fixer\notepadpp` (if missing) and returns the path.
Use this when the script doesn't already own a scratch dir.

## Where to call it

Place the call **after** the banner / `Initialize-Logging` / git-pull and
**before** the first download or install action.

```powershell
Write-Banner -Title $logMessages.scriptName
Initialize-Logging -ScriptName $logMessages.scriptName

try {
    Invoke-GitPull

    Write-InstallPaths `
        -Tool   "Chocolatey" `
        -Source $PSCommandPath `
        -Temp   (Resolve-DefaultTempDir -ToolSlug "chocolatey") `
        -Target "$env:ProgramData\chocolatey"

    # ... install logic ...
}
```

For multi-step scripts (e.g. databases, models) call `Write-InstallPaths` once
per discrete tool/component.

## Parameters

| Param  | Required | Notes                                                                |
|--------|----------|----------------------------------------------------------------------|
| Source | yes      | Script path, repo root, download URL, or installer .exe              |
| Temp   | yes      | Scratch / cache dir. Use `Resolve-DefaultTempDir` if you have no own |
| Target | yes      | Final install dir, PATH bin dir, %LocalAppData% subfolder, etc.      |
| Tool   | no       | Friendly name shown in the heading and JSON event                    |
| Action | no       | Defaults to `Install`. Use `Upgrade`, `Repair`, `Extract`, etc.      |

Pass `"(unknown)"` (literal string) when a path genuinely cannot be resolved —
the helper will render `(unknown)` in yellow rather than blank. Prefer fixing
the resolution upstream where possible (and use `Write-FileError` for the
underlying problem).

## JSON-log shape

```json
{
  "level": "info",
  "message": "installPaths tool=Notepad++ action=Install source=C:\\…\\run.ps1 temp=C:\\Users\\…\\AppData\\Local\\Temp\\scripts-fixer\\notepadpp target=C:\\Program Files\\Notepad++"
}
```

Grep with:

```powershell
Get-ChildItem .logs\*.json | Select-String 'installPaths'
```

## Adoption status

Tracked per-batch in the changelog and in `mem://features/install-paths-trio`.
