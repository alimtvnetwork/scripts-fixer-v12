<#
.SYNOPSIS
    Read-only verification for Script 10. Two layers:
      A. Install state -- folder/background/file leaf exists with correct
         (Default) label, Icon, and \command (Default).
      B. Repair invariants -- file-target ABSENT, no suppression values
         on directory+background, no legacy duplicate siblings.

.DESCRIPTION
    Mirrors Script 54's vscode-check.ps1 + vscode-repair-check.ps1, but
    reads $ed.contextMenuLabel (Script 10's schema) instead of $ed.label.
    The repair-invariant pass is config-shape-agnostic and is implemented
    locally to avoid coupling Script 10's runtime to Script 54's helper
    file existing on disk.

    Public functions:
      Invoke-Script10MenuCheck          -- install-state check (A)
      Invoke-Script10RepairInvariantCheck -- repair-state check (B)
#>

Set-StrictMode -Version Latest

$_helperDir10c = $PSScriptRoot
$_sharedDir10c = Join-Path (Split-Path -Parent (Split-Path -Parent $_helperDir10c)) "shared"
$_loggingPath10c = Join-Path $_sharedDir10c "logging.ps1"
if ((Test-Path $_loggingPath10c) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath10c
}

$script:Check10SuppressionValues = @(
    'ProgrammaticAccessOnly','AppliesTo','NoWorkingDirectory',
    'LegacyDisable','CommandFlags'
)

function Get-HkcrSubPath10 {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function Get-Check10MenuEntryStatus {
    param(
        [Parameter(Mandatory)] [string] $TargetName,
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $ExpectedLabel
    )

    $status = [ordered]@{
        target          = $TargetName
        registryPath    = $RegistryPath
        keyExists       = $false
        labelOk         = $false
        actualLabel     = $null
        iconPresent     = $false
        commandPresent  = $false
        commandValue    = $null
        exeResolvable   = $false
        exePath         = $null
        verdict         = "MISS"
        reason          = $null
    }

    $sub  = Get-HkcrSubPath10 $RegistryPath
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    $key = $hkcr.OpenSubKey($sub)
    $isKeyMissing = $null -eq $key
    if ($isKeyMissing) {
        $status.reason = "registry key not found: $RegistryPath"
        return [pscustomobject]$status
    }
    $status.keyExists = $true
    try {
        $defaultVal = $key.GetValue("")
        $iconVal    = $key.GetValue("Icon")
        $status.actualLabel = [string]$defaultVal
        $status.iconPresent = -not [string]::IsNullOrWhiteSpace([string]$iconVal)
        $status.labelOk     = ($status.actualLabel -eq $ExpectedLabel)
    } finally { $key.Close() }

    $cmdKey = $hkcr.OpenSubKey("$sub\command")
    $isCmdMissing = $null -eq $cmdKey
    if ($isCmdMissing) {
        $status.reason = "missing \\command subkey under: $RegistryPath"
        return [pscustomobject]$status
    }
    try {
        $cmdLine = [string]$cmdKey.GetValue("")
        $status.commandValue   = $cmdLine
        $status.commandPresent = -not [string]::IsNullOrWhiteSpace($cmdLine)
    } finally { $cmdKey.Close() }

    $hasMatch = $status.commandValue -match '^\s*"([^"]+)"'
    if ($hasMatch) {
        $exe = $Matches[1]
        $expanded = [System.Environment]::ExpandEnvironmentVariables($exe)
        $status.exePath       = $expanded
        $status.exeResolvable = Test-Path -LiteralPath $expanded
    }

    $isAllOk = $status.keyExists -and $status.labelOk -and $status.iconPresent `
        -and $status.commandPresent -and $status.exeResolvable
    if ($isAllOk) {
        $status.verdict = "PASS"
    } else {
        $reasons = @()
        if (-not $status.labelOk)        { $reasons += "label mismatch (got '$($status.actualLabel)', expected '$ExpectedLabel')" }
        if (-not $status.iconPresent)    { $reasons += "missing Icon value" }
        if (-not $status.commandPresent) { $reasons += "empty \\command (Default)" }
        if (-not $status.exeResolvable -and $status.exePath) {
            $reasons += "exe path not on disk: $($status.exePath)"
        } elseif (-not $status.exeResolvable) {
            $reasons += "could not parse exe path from command"
        }
        $status.reason = ($reasons -join "; ")
    }
    return [pscustomobject]$status
}

function Invoke-Script10MenuCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string] $EditionFilter = ""
    )

    $editionResults = @()
    $totalPass = 0
    $totalMiss = 0

    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) { $editions = $editions | Where-Object { $_ -ieq $EditionFilter } }

    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) {
            Write-Log "Edition '$edName' has no editions.$edName block in config.json (failure: cannot verify unknown edition)" -Level "warn"
            continue
        }
        $ed = $Config.editions.$edName
        Write-Log "" -Level "info"
        Write-Log ("Checking edition '" + $edName + "' (" + $ed.contextMenuLabel + ")") -Level "info"

        $perTarget = @()
        foreach ($targetName in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $targetName
            if (-not $hasTarget) {
                Write-Log "  [skip] $targetName -- no registryPaths.$targetName entry in config" -Level "warn"
                continue
            }
            $regPath = $ed.registryPaths.$targetName
            $st = Get-Check10MenuEntryStatus -TargetName $targetName -RegistryPath $regPath -ExpectedLabel $ed.contextMenuLabel
            $perTarget += $st

            $tag = if ($targetName -eq 'directory') { 'folder    ' }
                   elseif ($targetName -eq 'background') { 'background' }
                   else { 'file      ' }
            $line = "  [{0}] {1}  {2}" -f $st.verdict, $tag, $regPath
            $level = if ($st.verdict -eq 'PASS') { 'success' } else { 'error' }
            Write-Log $line -Level $level
            if ($st.verdict -ne 'PASS' -and $st.reason) {
                Write-Log ("           reason: " + $st.reason + " (failure path: " + $regPath + ")") -Level "error"
            }
            if ($st.verdict -eq 'PASS') { $totalPass++ } else { $totalMiss++ }
        }

        $editionResults += [pscustomobject]@{
            edition = $edName
            label   = $ed.contextMenuLabel
            targets = $perTarget
        }
    }

    Write-Log "" -Level "info"
    Write-Log ("Verification totals: PASS=" + $totalPass + ", MISS=" + $totalMiss) -Level $(if ($totalMiss -eq 0) { 'success' } else { 'error' })

    return [pscustomobject]@{
        editions  = $editionResults
        totalPass = $totalPass
        totalMiss = $totalMiss
    }
}

# ---------------------------------------------------------------------------
#  Repair invariants
# ---------------------------------------------------------------------------

function Test-Check10RepairEnforced {
    param($Config)
    $hasRepair = $Config.PSObject.Properties.Name -contains 'repair'
    if (-not $hasRepair) { return $true }
    $hasFlag = $Config.repair.PSObject.Properties.Name -contains 'enforceInvariants'
    if (-not $hasFlag) { return $true }
    return [bool]$Config.repair.enforceInvariants
}

function Get-Check10LegacyNames {
    param($Config)
    $hasRepair = $Config.PSObject.Properties.Name -contains 'repair'
    $hasList   = $hasRepair -and ($Config.repair.PSObject.Properties.Name -contains 'legacyNames')
    if ($hasList) { return @($Config.repair.legacyNames) }
    return @(
        'VSCode2','VSCode3','VSCodeOld','VSCode_old',
        'OpenWithCode','OpenWithVSCode','Open with Code','OpenCode',
        'VSCodeInsiders2','VSCodeInsidersOld','OpenWithInsiders'
    )
}

function Get-Check10ShellParentSub {
    param([string]$RegistryPath)
    $sub = Get-HkcrSubPath10 $RegistryPath
    $idx = $sub.LastIndexOf('\')
    if ($idx -lt 0) { return $sub }
    return $sub.Substring(0, $idx)
}

function Invoke-Script10RepairInvariantCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string] $EditionFilter = ""
    )

    $enforced = Test-Check10RepairEnforced -Config $Config
    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) { $editions = $editions | Where-Object { $_ -ieq $EditionFilter } }

    $legacyNames = Get-Check10LegacyNames -Config $Config
    $totalPass = 0
    $totalMiss = 0

    Write-Log "" -Level "info"
    if ($enforced) {
        Write-Log ("Repair invariants: file-target ABSENT, no suppression values, no legacy duplicates (" + $legacyNames.Count + " allow-list names).") -Level "info"
    } else {
        Write-Log "Repair invariants: NOT enforced (config.repair.enforceInvariants = false). Reporting only." -Level "warn"
    }

    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) { continue }
        $ed = $Config.editions.$edName
        Write-Log ("Repair-invariant check for edition '" + $edName + "' (" + $ed.contextMenuLabel + ")") -Level "info"

        $passes = 0
        $misses = 0

        # Invariant 1: file-target absent
        $hasFile = $ed.registryPaths.PSObject.Properties.Name -contains 'file'
        if ($hasFile) {
            $fileReg = $ed.registryPaths.file
            $sub = Get-HkcrSubPath10 $fileReg
            $key = $hkcr.OpenSubKey($sub)
            $isAbsent = $null -eq $key
            if (-not $isAbsent) { $key.Close() }
            if ($isAbsent) {
                Write-Log ("  [PASS] file-target absent: " + $fileReg) -Level "success"
                $passes++
            } else {
                Write-Log ("  [MISS] file-target STILL PRESENT: " + $fileReg + " (failure: run 'repair' to remove)") -Level "error"
                $misses++
            }
        }

        # Invariant 2: no suppression values on directory + background
        foreach ($keep in @('directory','background')) {
            $hasKey = $ed.registryPaths.PSObject.Properties.Name -contains $keep
            if (-not $hasKey) { continue }
            $regPath = $ed.registryPaths.$keep
            $sub = Get-HkcrSubPath10 $regPath
            $key = $hkcr.OpenSubKey($sub)
            $found = @()
            if ($null -ne $key) {
                try {
                    foreach ($v in $key.GetValueNames()) {
                        if ($script:Check10SuppressionValues -contains $v) { $found += $v }
                    }
                } finally { $key.Close() }
            }
            $isClean = $found.Count -eq 0
            if ($isClean) {
                Write-Log ("  [PASS] no suppression values on " + $keep + ": " + $regPath) -Level "success"
                $passes++
            } else {
                $joined = ($found -join ', ')
                Write-Log ("  [MISS] suppression values on " + $keep + " (" + $regPath + "): " + $joined + " (failure: run 'repair' to strip)") -Level "error"
                $misses++
            }
        }

        # Invariant 3: no legacy duplicates under any of the 3 shell parents
        $parentSubs = @{}
        foreach ($t in @('file','directory','background')) {
            $hasT = $ed.registryPaths.PSObject.Properties.Name -contains $t
            if (-not $hasT) { continue }
            $sub = Get-Check10ShellParentSub $ed.registryPaths.$t
            $parentSubs[$sub] = $true
        }
        foreach ($parentSub in $parentSubs.Keys) {
            $parent = $hkcr.OpenSubKey($parentSub)
            $present = @()
            if ($null -ne $parent) {
                try {
                    foreach ($n in $legacyNames) {
                        $child = $parent.OpenSubKey($n)
                        if ($null -ne $child) { $present += $n; $child.Close() }
                    }
                } finally { $parent.Close() }
            }
            $isClean = $present.Count -eq 0
            if ($isClean) {
                Write-Log ("  [PASS] no legacy duplicates under HKCR\" + $parentSub) -Level "success"
                $passes++
            } else {
                $joined = ($present -join ', ')
                Write-Log ("  [MISS] legacy duplicates under HKCR\" + $parentSub + ": " + $joined + " (failure: run 'repair' to remove)") -Level "error"
                $misses++
            }
        }

        if ($enforced) {
            $totalPass += $passes
            $totalMiss += $misses
        } else {
            $totalPass += ($passes + $misses)
        }
    }

    Write-Log "" -Level "info"
    $level = if ($totalMiss -eq 0) { 'success' } else { 'error' }
    Write-Log ("Repair-invariant totals: PASS=" + $totalPass + ", MISS=" + $totalMiss + " (enforced=" + $enforced + ")") -Level $level

    return [pscustomobject]@{
        totalPass = $totalPass
        totalMiss = $totalMiss
        enforced  = $enforced
    }
}