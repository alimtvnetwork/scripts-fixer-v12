<#
.SYNOPSIS
    Read-only verification of the THREE post-repair invariants:
      1. File-target keys are ABSENT  (HKCR\*\shell\<Name>)
      2. Surviving folder + background keys carry NO suppression values
         (ProgrammaticAccessOnly, AppliesTo, NoWorkingDirectory,
          LegacyDisable, CommandFlags)
      3. Legacy / duplicate sibling keys (config.repair.legacyNames) are
         ABSENT under each of the three shell parents.

.DESCRIPTION
    Pure read-only. Used by the `check` command and by the `verify` test
    harness (Cases 6/7/8) to fail when the context-menu state diverges
    from what `repair` is supposed to guarantee.

    Naming follows project convention: is/has booleans, no bare -not.
#>

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Mirror the suppression list used by vscode-repair.ps1 so the two stay in
# lock-step. Kept local on purpose -- this module is read-only and must not
# depend on the writable repair helper being dot-sourced first.
$script:RepairSuppressionValues = @(
    'ProgrammaticAccessOnly',
    'AppliesTo',
    'NoWorkingDirectory',
    'LegacyDisable',
    'CommandFlags'
)

function Get-HkcrSubkeyPathRC {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function Get-ShellParentSubkeyRC {
    <#
    .SYNOPSIS
        Maps "Registry::HKEY_CLASSES_ROOT\Directory\shell\VSCode" to
        the HKCR-relative parent "Directory\shell".
    #>
    param([string]$RegistryPath)
    $sub = Get-HkcrSubkeyPathRC $RegistryPath
    $idx = $sub.LastIndexOf('\')
    if ($idx -lt 0) { return $sub }
    return $sub.Substring(0, $idx)
}

function Test-FileTargetAbsent {
    <#
    .SYNOPSIS
        Returns $true if the file-target key (HKCR\*\shell\<Name>) does NOT
        exist for this edition. Per repair invariant: the menu must NOT
        appear when right-clicking individual files.
    #>
    param(
        [Parameter(Mandatory)] [string] $RegistryPath
    )
    $sub  = Get-HkcrSubkeyPathRC $RegistryPath
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    $key  = $hkcr.OpenSubKey($sub)
    $isAbsent = $null -eq $key
    if (-not $isAbsent) { $key.Close() }
    return $isAbsent
}

function Get-SuppressionValuesPresent {
    <#
    .SYNOPSIS
        Returns the list of suppression value names actually present on
        the given key (empty array = clean). Read-only.
    #>
    param(
        [Parameter(Mandatory)] [string] $RegistryPath
    )
    $sub  = Get-HkcrSubkeyPathRC $RegistryPath
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    $key  = $hkcr.OpenSubKey($sub)
    if ($null -eq $key) { return @() }
    $found = @()
    try {
        $valueNames = $key.GetValueNames()
        foreach ($v in $valueNames) {
            if ($script:RepairSuppressionValues -contains $v) { $found += $v }
        }
    } finally {
        $key.Close()
    }
    return $found
}

function Get-LegacyChildrenPresent {
    <#
    .SYNOPSIS
        Returns the list of legacy/duplicate child key names that DO exist
        under the given shell parent. Strict allow-list: only checks names
        from $LegacyNames (never enumerates).
    #>
    param(
        [Parameter(Mandatory)] [string]   $ParentSub,    # HKCR-relative
        [Parameter(Mandatory)] [string[]] $LegacyNames
    )
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    $parent = $hkcr.OpenSubKey($ParentSub)
    if ($null -eq $parent) { return @() }
    $present = @()
    try {
        foreach ($name in $LegacyNames) {
            $child = $parent.OpenSubKey($name)
            $hasChild = $null -ne $child
            if ($hasChild) {
                $present += $name
                $child.Close()
            }
        }
    } finally {
        $parent.Close()
    }
    return $present
}

function Get-RepairLegacyNamesRC {
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

function Test-RepairInvariantsEnforced {
    <#
    .SYNOPSIS
        Returns $true if config.repair.enforceInvariants is true OR not
        set (default = enforce). Set to false to opt out (e.g. on a
        machine where the user legitimately wants the file-target entry).
    #>
    param($Config)
    $hasRepair = $Config.PSObject.Properties.Name -contains 'repair'
    if (-not $hasRepair) { return $true }
    $hasFlag = $Config.repair.PSObject.Properties.Name -contains 'enforceInvariants'
    if (-not $hasFlag) { return $true }
    return [bool]$Config.repair.enforceInvariants
}

function Invoke-VsCodeRepairInvariantCheck {
    <#
    .SYNOPSIS
        Run all three repair invariants across every enabled edition.
    .OUTPUTS
        PSCustomObject with .editions[], .totalPass, .totalMiss, .enforced
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [string] $EditionFilter = ""
    )

    $enforced = Test-RepairInvariantsEnforced -Config $Config
    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) {
        $editions = $editions | Where-Object { $_ -ieq $EditionFilter }
    }

    $legacyNames = Get-RepairLegacyNamesRC -Config $Config
    $editionResults = @()
    $totalPass = 0
    $totalMiss = 0

    Write-Log "" -Level "info"
    if ($enforced) {
        Write-Log ("Repair invariants: file-target ABSENT, no suppression values, no legacy duplicates (" + $legacyNames.Count + " allow-list names).") -Level "info"
    } else {
        Write-Log "Repair invariants: NOT enforced (config.repair.enforceInvariants = false). Reporting only." -Level "warn"
    }

    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) {
            Write-Log ("  [skip] edition '" + $edName + "' not in config.editions") -Level "warn"
            continue
        }
        $ed = $Config.editions.$edName
        Write-Log ("Repair-invariant check for edition '" + $edName + "' (" + $ed.label + ")") -Level "info"

        $perEditionMisses = 0
        $perEditionPasses = 0
        $details = @()

        # Invariant 1: file-target absent
        $hasFile = $ed.registryPaths.PSObject.Properties.Name -contains 'file'
        if ($hasFile) {
            $fileReg = $ed.registryPaths.file
            $isAbsent = Test-FileTargetAbsent -RegistryPath $fileReg
            if ($isAbsent) {
                Write-Log ("  [PASS] file-target absent: " + $fileReg) -Level "success"
                $perEditionPasses++
                $details += [pscustomobject]@{ invariant='file-absent'; ok=$true; path=$fileReg }
            } else {
                Write-Log ("  [MISS] file-target STILL PRESENT: " + $fileReg + " (failure: run 'repair' to remove)") -Level "error"
                $perEditionMisses++
                $details += [pscustomobject]@{ invariant='file-absent'; ok=$false; path=$fileReg; reason='file-target key still exists' }
            }
        }

        # Invariant 2: no suppression values on directory + background
        foreach ($keep in @('directory','background')) {
            $hasKey = $ed.registryPaths.PSObject.Properties.Name -contains $keep
            if (-not $hasKey) { continue }
            $regPath = $ed.registryPaths.$keep
            $sup = Get-SuppressionValuesPresent -RegistryPath $regPath
            $isClean = $sup.Count -eq 0
            if ($isClean) {
                Write-Log ("  [PASS] no suppression values on " + $keep + ": " + $regPath) -Level "success"
                $perEditionPasses++
                $details += [pscustomobject]@{ invariant='no-suppression'; target=$keep; ok=$true; path=$regPath }
            } else {
                $joined = ($sup -join ', ')
                Write-Log ("  [MISS] suppression values on " + $keep + " (" + $regPath + "): " + $joined + " (failure: run 'repair' to strip)") -Level "error"
                $perEditionMisses++
                $details += [pscustomobject]@{ invariant='no-suppression'; target=$keep; ok=$false; path=$regPath; reason="suppression values present: $joined" }
            }
        }

        # Invariant 3: no legacy duplicate siblings under any of the 3 shell parents
        $parentSubs = @{}
        foreach ($t in @('file','directory','background')) {
            $hasT = $ed.registryPaths.PSObject.Properties.Name -contains $t
            if (-not $hasT) { continue }
            $sub = Get-ShellParentSubkeyRC $ed.registryPaths.$t
            $parentSubs[$sub] = $true
        }
        foreach ($parentSub in $parentSubs.Keys) {
            $present = Get-LegacyChildrenPresent -ParentSub $parentSub -LegacyNames $legacyNames
            $isClean = $present.Count -eq 0
            if ($isClean) {
                Write-Log ("  [PASS] no legacy duplicates under HKCR\" + $parentSub) -Level "success"
                $perEditionPasses++
                $details += [pscustomobject]@{ invariant='no-legacy'; ok=$true; parent="HKCR\$parentSub" }
            } else {
                $joined = ($present -join ', ')
                Write-Log ("  [MISS] legacy duplicates under HKCR\" + $parentSub + ": " + $joined + " (failure: run 'repair' to remove)") -Level "error"
                $perEditionMisses++
                $details += [pscustomobject]@{ invariant='no-legacy'; ok=$false; parent="HKCR\$parentSub"; reason="legacy children present: $joined" }
            }
        }

        if ($enforced) {
            $totalPass += $perEditionPasses
            $totalMiss += $perEditionMisses
        } else {
            # Not enforced: count everything as informational pass so check exit stays 0
            $totalPass += ($perEditionPasses + $perEditionMisses)
        }

        $editionResults += [pscustomobject]@{
            edition  = $edName
            label    = $ed.label
            passes   = $perEditionPasses
            misses   = $perEditionMisses
            details  = $details
        }
    }

    Write-Log "" -Level "info"
    $level = if ($totalMiss -eq 0) { 'success' } else { 'error' }
    Write-Log ("Repair-invariant totals: PASS=" + $totalPass + ", MISS=" + $totalMiss + " (enforced=" + $enforced + ")") -Level $level

    return [pscustomobject]@{
        editions  = $editionResults
        totalPass = $totalPass
        totalMiss = $totalMiss
        enforced  = $enforced
    }
}