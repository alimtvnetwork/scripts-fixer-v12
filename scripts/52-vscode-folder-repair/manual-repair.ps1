<#
.SYNOPSIS
    Single-file, runnable equivalent of the "Manual repair -- VS Code folder
    context menu" walkthrough in the project README.

.DESCRIPTION
    One command, one file, no dot-sourcing, no shared helpers required.
    Mirrors README Steps 0--6 in order:

        Step 0 -- Resolve + VALIDATE Code.exe (file + extension + version-info
                  + optional Authenticode signer == "CN=Microsoft Corporation")
        Step 1 -- Assert Administrator
        Step 2 -- Remove the noisy entries (file + background)
        Step 3 -- Ensure the folder entry exists and points at the validated exe
        Step 4 -- Restart explorer.exe (skippable with -NoRestart)
        Step 5 -- Verify final state of all three targets
        Step 6 -- Capture before/after .reg snapshots and print a diff summary

    Every failure logs the EXACT registry path or file path + the exact reason
    (CODE RED rule). Snapshots are written to a single timestamped subdir so
    you can inspect or re-import them later.

.PARAMETER Edition
    'stable' or 'insiders'. Drives both the exe location and the registry
    leaf name (VSCode vs VSCodeInsiders).

    When OMITTED, the script auto-detects which editions are installed:
        - exactly one installed -> uses it silently
        - both installed (or none) -> shows an interactive prompt
    Pass -NonInteractive to suppress the prompt and force 'stable'.

.PARAMETER NonInteractive
    Suppresses the interactive edition prompt. When -Edition is omitted
    in this mode, defaults to 'stable'. Use this in CI / unattended runs.

.PARAMETER OverrideCodePath
    Optional explicit path to Code.exe / Code - Insiders.exe. Skips auto-resolution.

.PARAMETER SnapshotDir
    Where to write the BEFORE/AFTER .reg snapshots. Defaults to
    $env:USERPROFILE\Desktop\vscode-menu-snapshots.

.PARAMETER RequireSignature
    Also enforce Authenticode signature == Valid and signer subject contains
    "CN=Microsoft Corporation". Recommended for production use.

.PARAMETER NoRestart
    Skip the explorer.exe restart. The menu will refresh on next sign-in.

.PARAMETER VerboseRegistry
    Emits a one-line trace for every registry value the script reads,
    compares, writes, deletes, exports, or imports. Each line is prefixed
    "[reg] <OP> <key>!<valueName>  data=<payload>" (or before/after for
    DIFF lines). Use this when something looks off and you want to see
    exactly what the script is touching, with the actual value names and
    data shown -- not just the key path.

.PARAMETER WhatIf
    Standard SupportsShouldProcess switch. Shows every registry write/delete
    and every snapshot WITHOUT touching the registry or the filesystem.

.PARAMETER RestoreDefaultEntries
    Switches the script into RESTORE mode. Instead of running the folder-only
    repair, it:
        1. Locates the most recent BEFORE snapshot for the chosen -Edition in
           -SnapshotDir (or uses the explicit -RestoreFromFile if provided).
        2. Deletes all three current keys (file, directory, background) for
           the edition so the import lands on a clean slate.
        3. Imports the snapshot via reg.exe -- this is the file VS Code's own
           installer would have produced, so the result is the stock menu.
        4. Restarts explorer.exe (unless -NoRestart) and verifies all three
           keys are present.

    The exe-validation step (Step 0) is still run so the BEFORE snapshot's
    Code.exe path is sanity-checked against what's actually on disk.

.PARAMETER RestoreFromFile
    Optional explicit path to a .reg snapshot to restore from. When omitted,
    the newest "vscode-menu-<edition>-BEFORE-*.reg" file inside -SnapshotDir
    is used. Only meaningful with -RestoreDefaultEntries.

.EXAMPLE
    .\manual-repair.ps1 -WhatIf
    .\manual-repair.ps1
    .\manual-repair.ps1 -Edition insiders -RequireSignature
    .\manual-repair.ps1 -OverrideCodePath 'D:\VSCode\Code.exe' -NoRestart
    .\manual-repair.ps1 -RestoreDefaultEntries                    # newest BEFORE for stable
    .\manual-repair.ps1 -RestoreDefaultEntries -Edition insiders
    .\manual-repair.ps1 -RestoreDefaultEntries -RestoreFromFile 'D:\snaps\vscode-menu-stable-BEFORE-20260422-143012.reg'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('stable', 'insiders')]
    [string]$Edition,                     # left empty -> interactive prompt

    [string]$OverrideCodePath,

    [string]$SnapshotDir = (Join-Path $env:USERPROFILE 'Desktop\vscode-menu-snapshots'),

    [switch]$RequireSignature,

    [switch]$NoRestart,

    [switch]$RestoreDefaultEntries,

    [string]$RestoreFromFile,

    # Use this to force the default non-interactively (e.g. CI / unattended).
    [switch]$NonInteractive,

    # Print every registry value name + data being read, compared, written,
    # or deleted. Goes to stderr-style cyan/grey lines prefixed [reg].
    [switch]$VerboseRegistry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Interactive edition prompt -- only fires when -Edition is OMITTED.
# Detects which installs are present so we can mark them in the menu and
# auto-pick when only one edition is installed.
#
# Detection delegates to the shared helper scripts/shared/vscode-edition-detect.ps1
# when available so Stable-vs-Insiders probing stays consistent across all
# entry points (run.ps1, manual-repair.ps1, rollback.ps1). A self-contained
# inline fallback is kept so this file remains runnable on its own.
# --------------------------------------------------------------------------
$_sharedDetect = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared\vscode-edition-detect.ps1"
# $PSScriptRoot resolves to scripts\52-vscode-folder-repair when run.ps1 dot-sources
# this file, but manual-repair.ps1 lives at the same depth so the join is identical.
$_sharedDetectAlt = Join-Path (Split-Path -Parent $PSScriptRoot) "shared\vscode-edition-detect.ps1"
foreach ($_p in @($_sharedDetect, $_sharedDetectAlt)) {
    if (Test-Path -LiteralPath $_p) { . $_p; break }
}

function Test-VsCodeEditionInstalled {
    param([string]$EditionName)
    # Prefer the shared helper when it has been dot-sourced above.
    $sharedCmd = Get-Command -Name 'Test-VsCodeEditionInstalled' -CommandType Function -ErrorAction SilentlyContinue |
        Where-Object { $_.ScriptBlock.File -and ($_.ScriptBlock.File -ne $PSCommandPath) } |
        Select-Object -First 1
    if ($sharedCmd) { return (& $sharedCmd -EditionName $EditionName) }

    # Fallback: same logic as the shared helper, kept inline so this script
    # works even when shared\vscode-edition-detect.ps1 is missing.
    $exeName = if ($EditionName -eq 'insiders') { 'Code - Insiders.exe' } else { 'Code.exe' }
    $folder  = if ($EditionName -eq 'insiders') { 'Microsoft VS Code Insiders' } else { 'Microsoft VS Code' }
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $candidate = Join-Path $base ("Programs\$folder\$exeName")
        if (Test-Path -LiteralPath $candidate) { return $true }
        # System install lives directly under ProgramFiles (no "Programs\")
        $altCandidate = Join-Path $base ("$folder\$exeName")
        if (Test-Path -LiteralPath $altCandidate) { return $true }
    }
    return $false
}

function Read-EditionInteractive {
    param([bool]$StableInstalled, [bool]$InsidersInstalled)

    $stableTag   = if ($StableInstalled)   { 'installed'    } else { 'NOT installed' }
    $insidersTag = if ($InsidersInstalled) { 'installed'    } else { 'NOT installed' }

    Write-Host ""
    Write-Host "Which VS Code edition do you want to target?" -ForegroundColor Cyan
    Write-Host ("  [1] stable     ({0})  -- default, press Enter" -f $stableTag)   -ForegroundColor White
    Write-Host ("  [2] insiders   ({0})" -f $insidersTag)                          -ForegroundColor White
    Write-Host ("  [Q] quit")                                                      -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $raw = Read-Host "Enter choice (1/2/Q) [default: 1]"
        $choice = ($raw + '').Trim().ToLower()
        switch ($choice) {
            ''         { return 'stable' }
            '1'        { return 'stable' }
            'stable'   { return 'stable' }
            's'        { return 'stable' }
            '2'        { return 'insiders' }
            'insiders' { return 'insiders' }
            'i'        { return 'insiders' }
            'q'        { Write-Host "aborted by user." -ForegroundColor Yellow; exit 0 }
            'quit'     { Write-Host "aborted by user." -ForegroundColor Yellow; exit 0 }
            default    { Write-Host "Invalid choice '$raw'. Type 1, 2, or Q." -ForegroundColor Yellow }
        }
    }
}

$_editionPassed = $PSBoundParameters.ContainsKey('Edition')
if (-not $_editionPassed) {
    if ($NonInteractive) {
        $Edition = 'stable'
        Write-Host "[non-interactive] -Edition omitted -- defaulting to 'stable'." -ForegroundColor DarkGray
    } else {
        $hasStable   = Test-VsCodeEditionInstalled -EditionName 'stable'
        $hasInsiders = Test-VsCodeEditionInstalled -EditionName 'insiders'

        # Auto-pick when exactly one edition is present -- no point prompting.
        if ($hasStable -and -not $hasInsiders) {
            $Edition = 'stable'
            Write-Host "[auto] only Stable detected -- using -Edition stable." -ForegroundColor DarkGray
        } elseif ($hasInsiders -and -not $hasStable) {
            $Edition = 'insiders'
            Write-Host "[auto] only Insiders detected -- using -Edition insiders." -ForegroundColor DarkGray
        } else {
            $Edition = Read-EditionInteractive -StableInstalled $hasStable -InsidersInstalled $hasInsiders
            Write-Host ("[chosen] -Edition {0}" -f $Edition) -ForegroundColor Green
        }
    }
}

# --------------------------------------------------------------------------
# Tiny inline logger -- keeps this script truly single-file.
# Every line is timestamped + colour-coded. Errors include path + reason.
# --------------------------------------------------------------------------
$script:_summary = [ordered]@{
    Edition       = $Edition
    CodeExe       = $null
    CodeVersion   = $null
    Removed       = New-Object System.Collections.Generic.List[string]
    Ensured       = New-Object System.Collections.Generic.List[string]
    AlreadyAbsent = New-Object System.Collections.Generic.List[string]
    Errors        = New-Object System.Collections.Generic.List[string]
    BeforeReg     = $null
    AfterReg      = $null
    DiffAdded     = 0
    DiffRemoved   = 0
    DiffModified  = 0
    DiffByTarget  = [ordered]@{}   # target name -> @{Added=N; Removed=N; Modified=N}
}

function Write-Step {
    param([string]$Text, [string]$Level = 'info')
    $colour = switch ($Level) {
        'success' { 'Green' }
        'warn'    { 'Yellow' }
        'error'   { 'Red' }
        default   { 'Cyan' }
    }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] {1}" -f $stamp, $Text) -ForegroundColor $colour
}

function Write-FileError {
    # CODE RED helper: every file/path error MUST include both fields.
    param([string]$Path, [string]$Reason)
    $msg = "path={0} reason={1}" -f $Path, $Reason
    Write-Step $msg -Level 'error'
    $script:_summary.Errors.Add($msg) | Out-Null
}

function Format-RegData {
    # Render registry data safely + truncate noisy blobs for the trace line.
    param($Value, [int]$MaxLen = 240)
    if ($null -eq $Value) { return '<null>' }
    $s = if ($Value -is [byte[]]) {
        '<binary ' + $Value.Length + ' bytes>'
    } else {
        [string]$Value
    }
    if ($s.Length -gt $MaxLen) { $s = $s.Substring(0, $MaxLen) + '...<truncated>' }
    # Make embedded control chars visible without breaking the line.
    return ($s -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t')
}

function Write-RegTrace {
    <#
      Structured one-liner for every registry value touched during the run.
      No-op unless -VerboseRegistry was passed, so production runs stay quiet.

      Op codes (kept short for grepping):
          READ    -- queried a value (data printed)
          PRESENT -- key existence probe   (data = True / False)
          WRITE   -- about to write a value (data = new payload)
          DELETE  -- about to delete a key  (data = recursive marker)
          IMPORT  -- bulk import from .reg  (data = file path)
          EXPORT  -- bulk export to .reg    (data = file path)
          DIFF    -- before vs after comparison result
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('READ','PRESENT','WRITE','DELETE','IMPORT','EXPORT','DIFF')]
        [string]$Op,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Name = '(default)',
        $Data,
        $Before,
        $After
    )
    if (-not $VerboseRegistry) { return }

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $colour = switch ($Op) {
        'WRITE'   { 'Green' }
        'DELETE'  { 'Yellow' }
        'IMPORT'  { 'Magenta' }
        'EXPORT'  { 'DarkCyan' }
        'DIFF'    { 'White' }
        default   { 'Gray' }
    }

    $line = if ($Op -eq 'DIFF') {
        '[{0}] [reg] {1,-7} {2}!{3}  before={4}  after={5}' -f `
            $stamp, $Op, $Path, $Name, (Format-RegData $Before), (Format-RegData $After)
    } else {
        '[{0}] [reg] {1,-7} {2}!{3}  data={4}' -f `
            $stamp, $Op, $Path, $Name, (Format-RegData $Data)
    }
    Write-Host $line -ForegroundColor $colour
}

# --------------------------------------------------------------------------
# Step 0 -- Resolve + VALIDATE Code.exe (mirrors Resolve-AndValidateVsCodeExe
#          in the README).
# --------------------------------------------------------------------------
function Resolve-AndValidateVsCodeExe {
    param(
        [string]$EditionName,
        [string]$OverridePath,
        [switch]$RequireSignature
    )

    $exeName = if ($EditionName -eq 'insiders') { 'Code - Insiders.exe' } else { 'Code.exe' }
    $folder  = if ($EditionName -eq 'insiders') { 'Microsoft VS Code Insiders' } else { 'Microsoft VS Code' }
    $candidates = @()
    if ($OverridePath) { $candidates += $OverridePath }
    $candidates += "$env:LOCALAPPDATA\Programs\$folder\$exeName"
    $candidates += "$env:ProgramFiles\$folder\$exeName"

    $resolved = $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1
    if (-not $resolved) {
        throw ("Code.exe not found. Tried:`n  - " + ($candidates -join "`n  - "))
    }

    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer) {
        throw "path=$resolved reason=resolved path is a directory, not a file"
    }
    if ($item.Extension -ne '.exe') {
        throw "path=$resolved reason=expected .exe, got '$($item.Extension)'"
    }

    $vi = $item.VersionInfo
    $isMicrosoft = $vi.CompanyName -match '^Microsoft Corporation'
    $isVsCode    = $vi.ProductName -match 'Visual Studio Code'
    if (-not ($isMicrosoft -and $isVsCode)) {
        throw ("path=$resolved reason=version-info mismatch " +
               "(CompanyName='$($vi.CompanyName)' ProductName='$($vi.ProductName)')")
    }

    if ($RequireSignature) {
        $sig = Get-AuthenticodeSignature -LiteralPath $resolved
        if ($sig.Status -ne 'Valid') {
            throw "path=$resolved reason=Authenticode status='$($sig.Status)'"
        }
        $isMsSigner = $sig.SignerCertificate.Subject -match 'CN=Microsoft Corporation'
        if (-not $isMsSigner) {
            throw "path=$resolved reason=signer is not Microsoft ('$($sig.SignerCertificate.Subject)')"
        }
    }

    Write-Step ("[validated] {0} v{1} -> {2}" -f $vi.ProductName, $vi.ProductVersion, $resolved) -Level 'success'
    $script:_summary.CodeExe     = $resolved
    $script:_summary.CodeVersion = $vi.ProductVersion
    return $resolved
}

# --------------------------------------------------------------------------
# Step 6 helper -- snapshot the three keys into one .reg file.
# --------------------------------------------------------------------------
function Save-MenuSnapshot {
    param(
        [string]$OutputPath,
        [string[]]$Keys
    )

    if ($PSCmdlet.ShouldProcess($OutputPath, "Write registry snapshot")) {
        Remove-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue
        Add-Content -LiteralPath $OutputPath -Value "Windows Registry Editor Version 5.00"
        Add-Content -LiteralPath $OutputPath -Value ""
        foreach ($k in $Keys) {
            Write-RegTrace -Op EXPORT -Path $k -Name '<key>' -Data $OutputPath
            $tmp = [IO.Path]::GetTempFileName() + '.reg'
            $null = reg.exe export $k $tmp /y 2>&1
            $isExported = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tmp)
            if ($isExported) {
                Add-Content -LiteralPath $OutputPath -Value "; ----- $k -----"
                # Skip the per-file header line so the merged file stays valid.
                Get-Content -LiteralPath $tmp | Select-Object -Skip 1 |
                    Add-Content -LiteralPath $OutputPath
                Remove-Item -LiteralPath $tmp -Force
            } else {
                Add-Content -LiteralPath $OutputPath -Value "; ----- $k ----- (absent at snapshot time)"
            }
        }
        Write-Step "snapshot written: $OutputPath" -Level 'success'
    }
}

# --------------------------------------------------------------------------
# .reg snapshot parser + grouped diff renderer.
#
# We turn each snapshot file into a hashtable of:
#     keyPath (string, full HKCR path) -> ordered map: valueName -> rawData
#
# This lets us compare on the *semantic* unit (a single registry value) and
# group results by target (file / directory / background) instead of dumping
# raw text-line diffs.
# --------------------------------------------------------------------------
function ConvertFrom-RegSnapshot {
    param([string]$Path)

    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $currentKey = $null
    $pending    = $null   # accumulator for backslash-continued value lines

    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        $line = $rawLine.TrimEnd()

        # Skip empty lines, file header, and our own "; ----- key -----" markers.
        if ($line -eq '')                                    { $pending = $null; continue }
        if ($line -match '^Windows Registry Editor Version') { continue }
        if ($line -match '^;')                               { continue }

        # Key header: [HKEY_CLASSES_ROOT\...]
        if ($line -match '^\[(.+)\]$') {
            $currentKey = $Matches[1]
            if (-not $result.Contains($currentKey)) {
                $result[$currentKey] = [ordered]@{}
            }
            $pending = $null
            continue
        }

        if (-not $currentKey) { continue }

        # Continuation of a previous backslash-terminated line (REG_BINARY etc.)
        if ($pending) {
            $result[$currentKey][$pending.Name] += $line.TrimStart()
            if ($line -notmatch '\\\s*$') { $pending = $null }
            else { $result[$currentKey][$pending.Name] = $result[$currentKey][$pending.Name].TrimEnd('\') }
            continue
        }

        # Default value:  @="data"
        # Named  value:  "Name"=...
        $name = $null; $data = $null
        if ($line -match '^@=(.*)$') {
            $name = '(default)'
            $data = $Matches[1]
        } elseif ($line -match '^"((?:[^"\\]|\\.)*)"=(.*)$') {
            $name = $Matches[1] -replace '\\"', '"' -replace '\\\\', '\'
            $data = $Matches[2]
        } else {
            continue
        }

        $result[$currentKey][$name] = $data
        if ($data -match '\\\s*$') {
            $result[$currentKey][$name] = $data.TrimEnd().TrimEnd('\')
            $pending = @{ Name = $name }
        }
    }

    return $result
}

function Get-TargetForKey {
    # Bucket a key path into one of file / directory / background / other.
    param([string]$KeyPath)
    if ($KeyPath -match '\\Directory\\Background\\shell\\') { return 'background' }
    if ($KeyPath -match '\\Directory\\shell\\')             { return 'directory' }
    if ($KeyPath -match '\\\*\\shell\\')                    { return 'file' }
    return 'other'
}

function Format-RegPayload {
    # Pretty-print a raw .reg value payload for display.
    param([string]$Raw, [int]$MaxLen = 200)
    if ($null -eq $Raw) { return '<absent>' }
    $s = $Raw.Trim()
    # Strip surrounding quotes for plain REG_SZ values so the output stays readable.
    if ($s -match '^"(.*)"$') { $s = $Matches[1] -replace '\\"', '"' -replace '\\\\', '\' }
    if ($s.Length -gt $MaxLen) { $s = $s.Substring(0, $MaxLen) + '...<truncated>' }
    return $s
}

function Write-GroupedDiff {
    <#
      Compare two parsed snapshots and print a per-target grouped diff with
      value-level adds / removes / modifications. Updates $script:_summary
      counts as a side effect.
    #>
    param($BeforeMap, $AfterMap)

    $allKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($k in $BeforeMap.Keys) { [void]$allKeys.Add($k) }
    foreach ($k in $AfterMap.Keys)  { [void]$allKeys.Add($k) }

    $buckets = [ordered]@{
        file       = [System.Collections.Generic.List[object]]::new()
        directory  = [System.Collections.Generic.List[object]]::new()
        background = [System.Collections.Generic.List[object]]::new()
        other      = [System.Collections.Generic.List[object]]::new()
    }
    foreach ($t in @('file','directory','background')) {
        $script:_summary.DiffByTarget[$t] = @{ Added = 0; Removed = 0; Modified = 0 }
    }

    foreach ($key in ($allKeys | Sort-Object)) {
        $target  = Get-TargetForKey -KeyPath $key
        $beforeK = if ($BeforeMap.Contains($key)) { $BeforeMap[$key] } else { $null }
        $afterK  = if ($AfterMap.Contains($key))  { $AfterMap[$key]  } else { $null }

        $allValues = [System.Collections.Generic.HashSet[string]]::new()
        if ($beforeK) { foreach ($v in $beforeK.Keys) { [void]$allValues.Add($v) } }
        if ($afterK)  { foreach ($v in $afterK.Keys)  { [void]$allValues.Add($v) } }

        # Whole-key adds/removes still surface even if no named values exist.
        if (-not $beforeK -and $afterK -and $allValues.Count -eq 0) {
            $buckets[$target].Add([PSCustomObject]@{ Key=$key; Name='<key>'; Change='ADDED'; Before=$null; After='<key created>' })
            $script:_summary.DiffByTarget[$target].Added++
            continue
        }
        if ($beforeK -and -not $afterK -and $allValues.Count -eq 0) {
            $buckets[$target].Add([PSCustomObject]@{ Key=$key; Name='<key>'; Change='REMOVED'; Before='<key existed>'; After=$null })
            $script:_summary.DiffByTarget[$target].Removed++
            continue
        }

        foreach ($vname in ($allValues | Sort-Object)) {
            $b = if ($beforeK -and $beforeK.Contains($vname)) { $beforeK[$vname] } else { $null }
            $a = if ($afterK  -and $afterK.Contains($vname))  { $afterK[$vname]  } else { $null }
            if ($b -eq $a) { continue }

            $change =
                if     ($null -eq $b -and $null -ne $a) { 'ADDED'    }
                elseif ($null -ne $b -and $null -eq $a) { 'REMOVED'  }
                else                                    { 'MODIFIED' }

            $buckets[$target].Add([PSCustomObject]@{
                Key = $key; Name = $vname; Change = $change; Before = $b; After = $a
            })
            switch ($change) {
                'ADDED'    { $script:_summary.DiffByTarget[$target].Added++ }
                'REMOVED'  { $script:_summary.DiffByTarget[$target].Removed++ }
                'MODIFIED' { $script:_summary.DiffByTarget[$target].Modified++ }
            }
        }
    }

    # ---- Render --------------------------------------------------------
    Write-Host ""
    Write-Host "=== DIFF SUMMARY (grouped by target, value-level) ===" -ForegroundColor DarkCyan

    $targetOrder = @('file','directory','background','other')
    $totalAdd = 0; $totalDel = 0; $totalMod = 0

    foreach ($t in $targetOrder) {
        $rows = $buckets[$t]
        if ($rows.Count -eq 0) {
            if ($t -ne 'other') {
                Write-Host ("  [{0,-10}] no changes" -f $t) -ForegroundColor DarkGray
            }
            continue
        }

        $stats = if ($script:_summary.DiffByTarget.Contains($t)) { $script:_summary.DiffByTarget[$t] } else { @{Added=0;Removed=0;Modified=0} }
        Write-Host ""
        Write-Host ("  [{0,-10}]  +{1} added   -{2} removed   ~{3} modified" -f $t, $stats.Added, $stats.Removed, $stats.Modified) -ForegroundColor Cyan

        # Group by key so the same key isn't repeated as a header per row.
        foreach ($keyGroup in ($rows | Group-Object Key)) {
            Write-Host ("    {0}" -f $keyGroup.Name) -ForegroundColor White
            foreach ($row in $keyGroup.Group) {
                $colour = switch ($row.Change) {
                    'ADDED'    { 'Green' }
                    'REMOVED'  { 'Yellow' }
                    'MODIFIED' { 'Magenta' }
                }
                $tag = '{0,-8}' -f $row.Change
                if ($row.Change -eq 'MODIFIED') {
                    Write-Host ("      {0} {1}" -f $tag, $row.Name) -ForegroundColor $colour
                    Write-Host ("          before: {0}" -f (Format-RegPayload $row.Before)) -ForegroundColor DarkGray
                    Write-Host ("          after : {0}" -f (Format-RegPayload $row.After))  -ForegroundColor Gray
                } elseif ($row.Change -eq 'ADDED') {
                    Write-Host ("      {0} {1} = {2}" -f $tag, $row.Name, (Format-RegPayload $row.After)) -ForegroundColor $colour
                } else {
                    Write-Host ("      {0} {1} (was {2})" -f $tag, $row.Name, (Format-RegPayload $row.Before)) -ForegroundColor $colour
                }
            }
        }

        $totalAdd += $stats.Added; $totalDel += $stats.Removed; $totalMod += $stats.Modified
    }

    $script:_summary.DiffAdded    = $totalAdd
    $script:_summary.DiffRemoved  = $totalDel
    $script:_summary.DiffModified = $totalMod

    Write-Host ""
    Write-Host ("Totals:  +{0} added   -{1} removed   ~{2} modified" -f $totalAdd, $totalDel, $totalMod) -ForegroundColor Cyan
}
Write-Host ""
Write-Host "==========================================================" -ForegroundColor DarkCyan
$_modeLabel = if ($RestoreDefaultEntries) { 'RESTORE (reinstall stock entries)' } else { 'REPAIR (folder-only)' }
Write-Host ("  VS Code menu helper (single-file) -- mode: {0}" -f $_modeLabel) -ForegroundColor Cyan
Write-Host ("  Edition: {0}   WhatIf: {1}" -f $Edition, $WhatIfPreference)     -ForegroundColor DarkCyan
Write-Host "==========================================================" -ForegroundColor DarkCyan

try {
    # ---- Step 1: admin -------------------------------------------------
    Write-Step "Step 1/6 -- checking Administrator privileges"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Step ("current user: {0}  isAdmin: {1}" -f $identity.Name, $isAdmin)
    if (-not $isAdmin) {
        Write-FileError -Path '<elevation>' -Reason 'Run this script from an elevated PowerShell (Run as Administrator).'
        return
    }

    # ---- Step 0: resolve + validate exe -------------------------------
    Write-Step "Step 0/6 -- resolving and validating Code.exe"
    $code = Resolve-AndValidateVsCodeExe -EditionName $Edition `
                                         -OverridePath $OverrideCodePath `
                                         -RequireSignature:$RequireSignature

    # ---- Compose the three target keys for this edition ---------------
    $leaf = if ($Edition -eq 'insiders') { 'VSCodeInsiders' } else { 'VSCode' }
    $label = if ($Edition -eq 'insiders') { 'Open with Code - Insiders' } else { 'Open with Code' }

    $fileKey       = "Registry::HKEY_CLASSES_ROOT\*\shell\$leaf"
    $directoryKey  = "Registry::HKEY_CLASSES_ROOT\Directory\shell\$leaf"
    $backgroundKey = "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\$leaf"

    # reg.exe-style equivalents for snapshot/diff
    $regKeysForExport = @(
        "HKCR\*\shell\$leaf",
        "HKCR\Directory\shell\$leaf",
        "HKCR\Directory\Background\shell\$leaf"
    )

    # ====================================================================
    # RESTORE MODE -- runs INSTEAD of the folder-only repair flow.
    # ====================================================================
    if ($RestoreDefaultEntries) {
        Write-Step "RESTORE MODE -- reinstalling stock VS Code context menu entries from a BEFORE snapshot" -Level 'warn'

        # 1) Pick the snapshot file ----------------------------------------
        $snapFile = $null
        if (-not [string]::IsNullOrWhiteSpace($RestoreFromFile)) {
            if (-not (Test-Path -LiteralPath $RestoreFromFile)) {
                Write-FileError -Path $RestoreFromFile -Reason '-RestoreFromFile does not exist on disk.'
                return
            }
            $snapFile = (Get-Item -LiteralPath $RestoreFromFile).FullName
            Write-Step "using explicit snapshot: $snapFile"
        } else {
            $isSnapDirMissing = -not (Test-Path -LiteralPath $SnapshotDir)
            if ($isSnapDirMissing) {
                Write-FileError -Path $SnapshotDir -Reason 'SnapshotDir does not exist; nothing to restore. Pass -RestoreFromFile or run a normal repair first to create one.'
                return
            }
            $pattern = "vscode-menu-$Edition-BEFORE-*.reg"
            $candidates = Get-ChildItem -LiteralPath $SnapshotDir -Filter $pattern -File -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending
            $hasCandidate = $candidates -and $candidates.Count -gt 0
            if (-not $hasCandidate) {
                Write-FileError -Path (Join-Path $SnapshotDir $pattern) -Reason 'no BEFORE snapshot matches this edition. Pass -RestoreFromFile to point at one explicitly.'
                return
            }
            $snapFile = $candidates[0].FullName
            Write-Step ("using newest snapshot ({0}): {1}" -f $candidates[0].LastWriteTime, $snapFile)
        }
        $script:_summary.BeforeReg = $snapFile   # repurpose -- "source of truth"

        # 2) Sanity-check the snapshot mentions the validated Code.exe ----
        try {
            $snapText = Get-Content -LiteralPath $snapFile -Raw -ErrorAction Stop
            $exeLeaf  = Split-Path -Leaf $code
            $isMentioned = $snapText -match [regex]::Escape($exeLeaf)
            if (-not $isMentioned) {
                Write-Step ("[warn] snapshot does not reference '$exeLeaf' -- it may be from a different install. Continuing anyway.") -Level 'warn'
            } else {
                Write-Step "[ok] snapshot references the validated Code.exe leaf name" -Level 'success'
            }
        } catch {
            Write-FileError -Path $snapFile -Reason ("could not read snapshot: " + $_.Exception.Message)
            return
        }

        # 3) Wipe the three current keys so the import lands clean --------
        Write-Step "wiping current keys before import"
        foreach ($key in @($fileKey, $directoryKey, $backgroundKey)) {
            $isPresent = Test-Path -LiteralPath $key
            Write-RegTrace -Op PRESENT -Path $key -Name '<key>' -Data $isPresent
            if (-not $isPresent) {
                Write-Step "[skip] not present: $key" -Level 'warn'
                $script:_summary.AlreadyAbsent.Add($key) | Out-Null
                continue
            }
            Write-RegTrace -Op DELETE -Path $key -Name '<key>' -Data 'recursive=true (pre-restore wipe)'
            if ($PSCmdlet.ShouldProcess($key, "Remove-Item -Recurse -Force (pre-restore wipe)")) {
                try {
                    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                    Write-Step "[wiped] $key" -Level 'success'
                    $script:_summary.Removed.Add($key) | Out-Null
                } catch {
                    Write-FileError -Path $key -Reason $_.Exception.Message
                }
            }
        }

        # 4) Import the snapshot via reg.exe ------------------------------
        Write-RegTrace -Op IMPORT -Path '<bulk>' -Name '<.reg file>' -Data $snapFile
        if ($PSCmdlet.ShouldProcess($snapFile, "reg.exe import")) {
            $importLog = & reg.exe import $snapFile 2>&1
            $hasImportFailed = ($LASTEXITCODE -ne 0)
            if ($hasImportFailed) {
                Write-FileError -Path $snapFile -Reason ("reg.exe import exit " + $LASTEXITCODE + " :: " + ($importLog -join ' | '))
            } else {
                Write-Step "[imported] $snapFile" -Level 'success'
                foreach ($key in @($fileKey, $directoryKey, $backgroundKey)) {
                    $script:_summary.Ensured.Add($key) | Out-Null
                }
            }
        }

        # 5) Restart Explorer (same logic as the repair flow) ------------
        if ($NoRestart) {
            Write-Step "[skip] -NoRestart specified; sign out / sign in to refresh." -Level 'warn'
        } elseif ($PSCmdlet.ShouldProcess('explorer.exe', 'Stop + Start')) {
            try {
                Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object {
                    try { $_.Kill() } catch { }
                }
                Start-Sleep -Milliseconds 800
                $isStillRunning = $null -ne (Get-Process -Name explorer -ErrorAction SilentlyContinue)
                if (-not $isStillRunning) { Start-Process explorer.exe | Out-Null }
                Write-Step "[ok] explorer.exe restarted" -Level 'success'
            } catch {
                Write-FileError -Path 'explorer.exe' -Reason $_.Exception.Message
            }
        }

        # 6) Verify all THREE targets are present (stock state) -----------
        Write-Step "verifying restored state -- all three targets must be present"
        foreach ($row in @(
            @{ Name='file       '; Path=$fileKey       },
            @{ Name='directory  '; Path=$directoryKey  },
            @{ Name='background '; Path=$backgroundKey }
        )) {
            $have = Test-Path -LiteralPath $row.Path
            Write-RegTrace -Op PRESENT -Path $row.Path -Name '<key>' -Data $have
            $tag  = if ($have) { 'PASS' } else { 'FAIL' }
            $lvl  = if ($have) { 'success' } else { 'error' }
            Write-Step ("  [{0}] {1} present={2,-5} -> {3}" -f $tag, $row.Name, $have, $row.Path) -Level $lvl
            if (-not $have) {
                Write-FileError -Path $row.Path -Reason 'expected key present after restore, got absent'
            }
        }

        return   # skip the rest of the repair flow
    }


    # ---- Step 6a: BEFORE snapshot (run before any change) -------------
    Write-Step "Step 6a/6 -- writing BEFORE snapshot"
    if (-not (Test-Path -LiteralPath $SnapshotDir)) {
        if ($PSCmdlet.ShouldProcess($SnapshotDir, "Create snapshot directory")) {
            New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
        }
    }
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $before = Join-Path $SnapshotDir ("vscode-menu-{0}-BEFORE-{1}.reg" -f $Edition, $stamp)
    $after  = Join-Path $SnapshotDir ("vscode-menu-{0}-AFTER-{1}.reg"  -f $Edition, $stamp)
    Save-MenuSnapshot -OutputPath $before -Keys $regKeysForExport
    $script:_summary.BeforeReg = $before

    # ---- Step 2: remove file + background ----------------------------
    Write-Step "Step 2/6 -- removing file + background entries"
    foreach ($key in @($fileKey, $backgroundKey)) {
        $isPresent = Test-Path -LiteralPath $key
        Write-RegTrace -Op PRESENT -Path $key -Name '<key>' -Data $isPresent
        if (-not $isPresent) {
            Write-Step "[skip] not present: $key" -Level 'warn'
            $script:_summary.AlreadyAbsent.Add($key) | Out-Null
            continue
        }
        # Capture the existing values BEFORE the delete so the trace shows
        # exactly what's about to disappear (not just the key path).
        if ($VerboseRegistry) {
            try {
                $cur = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                Write-RegTrace -Op READ -Path $key -Name '(default)' -Data $cur.'(default)'
                if ($cur.PSObject.Properties.Name -contains 'Icon') {
                    Write-RegTrace -Op READ -Path $key -Name 'Icon' -Data $cur.Icon
                }
                $cmdSub = "$key\command"
                if (Test-Path -LiteralPath $cmdSub) {
                    $curCmd = Get-ItemProperty -LiteralPath $cmdSub -ErrorAction Stop
                    Write-RegTrace -Op READ -Path $cmdSub -Name '(default)' -Data $curCmd.'(default)'
                }
            } catch { }
        }
        Write-RegTrace -Op DELETE -Path $key -Name '<key>' -Data 'recursive=true'
        if ($PSCmdlet.ShouldProcess($key, "Remove-Item -Recurse -Force")) {
            try {
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                Write-Step "[removed] $key" -Level 'success'
                $script:_summary.Removed.Add($key) | Out-Null
            } catch {
                Write-FileError -Path $key -Reason $_.Exception.Message
            }
        }
    }

    # ---- Step 3: ensure directory entry ------------------------------
    Write-Step "Step 3/6 -- ensuring folder entry"
    # Pre-flight gate: re-validate $code right before writing.
    if (-not $code -or -not (Test-Path -LiteralPath $code)) {
        Write-FileError -Path "$code" -Reason '$code is empty or no longer exists.'
        return
    }
    $cmdKey = "$directoryKey\command"
    $cmdVal = '"{0}" "%1"' -f $code

    # BEFORE-state read so the trace shows exactly what we're about to change.
    $prevLabel = $null; $prevIcon = $null; $prevCmd = $null
    if ($VerboseRegistry -and (Test-Path -LiteralPath $directoryKey)) {
        try {
            $cur = Get-ItemProperty -LiteralPath $directoryKey -ErrorAction Stop
            $prevLabel = $cur.'(default)'
            if ($cur.PSObject.Properties.Name -contains 'Icon') { $prevIcon = $cur.Icon }
        } catch { }
        if (Test-Path -LiteralPath $cmdKey) {
            try {
                $curCmd = Get-ItemProperty -LiteralPath $cmdKey -ErrorAction Stop
                $prevCmd = $curCmd.'(default)'
            } catch { }
        }
    }
    Write-RegTrace -Op DIFF  -Path $directoryKey -Name '(default)' -Before $prevLabel -After $label
    Write-RegTrace -Op DIFF  -Path $directoryKey -Name 'Icon'      -Before $prevIcon  -After $code
    Write-RegTrace -Op DIFF  -Path $cmdKey       -Name '(default)' -Before $prevCmd   -After $cmdVal

    if ($PSCmdlet.ShouldProcess($directoryKey, "Create + set Default/Icon")) {
        try {
            New-Item -Path $directoryKey -Force | Out-Null
            New-Item -Path $cmdKey       -Force | Out-Null

            Write-RegTrace -Op WRITE -Path $directoryKey -Name '(default)' -Data $label
            Set-ItemProperty -Path $directoryKey -Name '(default)' -Value $label

            Write-RegTrace -Op WRITE -Path $directoryKey -Name 'Icon'      -Data $code
            Set-ItemProperty -Path $directoryKey -Name 'Icon'      -Value $code

            Write-RegTrace -Op WRITE -Path $cmdKey       -Name '(default)' -Data $cmdVal
            Set-ItemProperty -Path $cmdKey       -Name '(default)' -Value $cmdVal

            Write-Step ("[ensured] {0}  ->  {1}" -f $directoryKey, $cmdVal) -Level 'success'
            $script:_summary.Ensured.Add($directoryKey) | Out-Null
        } catch {
            Write-FileError -Path $directoryKey -Reason $_.Exception.Message
        }
    }

    # ---- Step 4: restart explorer ------------------------------------
    Write-Step "Step 4/6 -- restarting explorer.exe"
    if ($NoRestart) {
        Write-Step "[skip] -NoRestart specified; sign out / sign in to refresh." -Level 'warn'
    } elseif ($PSCmdlet.ShouldProcess('explorer.exe', 'Stop + Start')) {
        try {
            Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object {
                try { $_.Kill() } catch { }
            }
            Start-Sleep -Milliseconds 800
            $isStillRunning = $null -ne (Get-Process -Name explorer -ErrorAction SilentlyContinue)
            if (-not $isStillRunning) { Start-Process explorer.exe | Out-Null }
            Write-Step "[ok] explorer.exe restarted" -Level 'success'
        } catch {
            Write-FileError -Path 'explorer.exe' -Reason $_.Exception.Message
        }
    }

    # ---- Step 5: verify ----------------------------------------------
    Write-Step "Step 5/6 -- verifying final state"
    $verifyMatrix = @(
        @{ Name = 'file       '; Path = $fileKey;       Want = $false }
        @{ Name = 'directory  '; Path = $directoryKey;  Want = $true  }
        @{ Name = 'background '; Path = $backgroundKey; Want = $false }
    )
    foreach ($row in $verifyMatrix) {
        $have = Test-Path -LiteralPath $row.Path
        Write-RegTrace -Op PRESENT -Path $row.Path -Name '<key>' -Data $have
        $isOk = ($have -eq $row.Want)
        $tag  = if ($isOk) { 'PASS' } else { 'FAIL' }
        $lvl  = if ($isOk) { 'success' } else { 'error' }
        Write-Step ("  [{0}] {1} got={2,-5} want={3,-5} -> {4}" -f $tag, $row.Name, $have, $row.Want, $row.Path) -Level $lvl
        if (-not $isOk) {
            $reason = if ($row.Want) { 'expected key present, got absent' } else { 'expected key absent, still present' }
            Write-FileError -Path $row.Path -Reason $reason
        }
    }

    # ---- Step 6c+d: AFTER snapshot + diff ---------------------------
    Write-Step "Step 6c/6 -- writing AFTER snapshot"
    Save-MenuSnapshot -OutputPath $after -Keys $regKeysForExport
    $script:_summary.AfterReg = $after

    Write-Step "Step 6d/6 -- diff summary"
    $hasBoth = (Test-Path -LiteralPath $before) -and (Test-Path -LiteralPath $after)
    if ($hasBoth) {
        try {
            $beforeMap = ConvertFrom-RegSnapshot -Path $before
            $afterMap  = ConvertFrom-RegSnapshot -Path $after
            Write-GroupedDiff -BeforeMap $beforeMap -AfterMap $afterMap
        } catch {
            Write-FileError -Path "$before / $after" -Reason ("grouped diff failed: " + $_.Exception.Message)
            # Fallback to raw line diff so the user still sees something.
            $diff = Compare-Object `
                        -ReferenceObject  (Get-Content -LiteralPath $before) `
                        -DifferenceObject (Get-Content -LiteralPath $after) |
                    Where-Object { $_.InputObject -notmatch '^;|^Windows Registry|^\s*$' }
            Write-Host ""
            Write-Host "=== DIFF SUMMARY (fallback: raw lines) ===" -ForegroundColor DarkCyan
            foreach ($d in $diff) {
                $tag = if ($d.SideIndicator -eq '<=') { 'REMOVED' } else { 'ADDED  ' }
                $col = if ($d.SideIndicator -eq '<=') { 'Yellow'  } else { 'Green'  }
                Write-Host ("  {0}  {1}" -f $tag, $d.InputObject) -ForegroundColor $col
            }
            $script:_summary.DiffRemoved = ($diff | Where-Object SideIndicator -eq '<=').Count
            $script:_summary.DiffAdded   = ($diff | Where-Object SideIndicator -eq '=>').Count
        }
    } else {
        Write-Step "skipped diff -- one or both snapshots not on disk (likely -WhatIf run)" -Level 'warn'
    }

} catch {
    Write-FileError -Path '<unhandled>' -Reason ("$($_.Exception.Message) :: $($_.ScriptStackTrace)")
} finally {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor DarkCyan
    Write-Host "  Run summary"                                              -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor DarkCyan
    Write-Host ("Edition         : {0}" -f $script:_summary.Edition)
    Write-Host ("Code.exe        : {0}" -f $script:_summary.CodeExe)
    Write-Host ("Code version    : {0}" -f $script:_summary.CodeVersion)
    Write-Host ("Removed keys    : {0}" -f $script:_summary.Removed.Count)
    foreach ($k in $script:_summary.Removed)       { Write-Host "  - $k" -ForegroundColor Yellow }
    Write-Host ("Ensured keys    : {0}" -f $script:_summary.Ensured.Count)
    foreach ($k in $script:_summary.Ensured)       { Write-Host "  + $k" -ForegroundColor Green }
    Write-Host ("Already absent  : {0}" -f $script:_summary.AlreadyAbsent.Count)
    Write-Host ("BEFORE snapshot : {0}" -f $script:_summary.BeforeReg)
    Write-Host ("AFTER  snapshot : {0}" -f $script:_summary.AfterReg)
    Write-Host ("Diff totals     : +{0} added  -{1} removed  ~{2} modified" -f $script:_summary.DiffAdded, $script:_summary.DiffRemoved, $script:_summary.DiffModified)
    foreach ($t in @('file','directory','background')) {
        if ($script:_summary.DiffByTarget.Contains($t)) {
            $s = $script:_summary.DiffByTarget[$t]
            Write-Host ("  - {0,-10} : +{1} / -{2} / ~{3}" -f $t, $s.Added, $s.Removed, $s.Modified)
        }
    }
    Write-Host ("Errors          : {0}" -f $script:_summary.Errors.Count)
    foreach ($e in $script:_summary.Errors)        { Write-Host "  ! $e" -ForegroundColor Red }
    Write-Host "==========================================================" -ForegroundColor DarkCyan

    # Non-zero exit on any error so this can be chained in CI / scripts.
    if ($script:_summary.Errors.Count -gt 0) { exit 1 }
}
