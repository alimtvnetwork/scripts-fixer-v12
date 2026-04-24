<#
.SYNOPSIS
    Repair VS Code right-click context menu so it appears on folders and
    folder backgrounds, but not on files. Also cleans up legacy duplicate
    VSCode-ish keys and strips suppression hints (ProgrammaticAccessOnly,
    AppliesTo, NoWorkingDirectory) from the surviving entries.

.DESCRIPTION
    Exposes Invoke-VsCodeMenuRepair. Operates strictly on:
      KEEP  : HKCR\Directory\shell\<Name>            (folder right-click)
      KEEP  : HKCR\Directory\Background\shell\<Name> (folder-background)
      DROP  : HKCR\*\shell\<Name>                    (file right-click)

    Uses the SAME registry paths that live in config.json::editions.<n>.
    registryPaths so it stays in lock-step with install/uninstall.

    Legacy cleanup uses config.repair.legacyNames -- a list of suspect
    sibling key names (e.g. "VSCode2", "OpenWithCode"). Repair only
    deletes those exact named children of the same three parents.
    Never enumerates, never touches anything outside the allow-list.
#>

Set-StrictMode -Version Latest

$_helperDir = $PSScriptRoot
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $_helperDir)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}
foreach ($peer in @("vscode-install.ps1","vscode-uninstall.ps1","audit-log.ps1")) {
    $peerPath = Join-Path $_helperDir $peer
    if ((Test-Path $peerPath)) { . $peerPath }
}

# Suppression value names that, when present on a shell-verb key, hide
# the entry from the right-click menu. Stripped on repair.
$script:SuppressionValues = @(
    'ProgrammaticAccessOnly',
    'AppliesTo',
    'NoWorkingDirectory',
    'LegacyDisable',
    'CommandFlags'  # bit 0x40 = ECF_HIDE; safest to remove the value entirely
)

function ConvertTo-RegExePathR {
    param([string]$PsPath)
    $p = $PsPath -replace '^Registry::', ''
    return ($p -replace '^HKEY_CLASSES_ROOT', 'HKCR')
}

function Get-RepairLegacyNames {
    <#
    .SYNOPSIS
        Returns the list of legacy/duplicate child key names to clean up
        from the three parent shell paths. Reads config.repair.legacyNames
        if present; otherwise falls back to a sensible default list.
    #>
    param($Config)

    $hasRepairBlock = $Config.PSObject.Properties.Name -contains 'repair'
    $hasList = $hasRepairBlock -and ($Config.repair.PSObject.Properties.Name -contains 'legacyNames')
    if ($hasList) {
        return @($Config.repair.legacyNames)
    }
    return @(
        'VSCode2','VSCode3','VSCodeOld','VSCode_old',
        'OpenWithCode','OpenWithVSCode','Open with Code','OpenCode',
        'VSCodeInsiders2','VSCodeInsidersOld','OpenWithInsiders'
    )
}

function Remove-SuppressionValuesIfPresent {
    <#
    .SYNOPSIS
        Strip suppression value names from a shell key (read+delete only;
        never touches the (Default), Icon, or \command).
    .OUTPUTS
        [int] count of values removed.
    #>
    param(
        [Parameter(Mandatory)] [string] $RegistryPath,
        [string] $EditionName = "",
        [string] $TargetName  = ""
    )

    $sub  = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    $key  = $hkcr.OpenSubKey($sub, $true)  # writable
    if ($null -eq $key) { return 0 }

    $removed = 0
    try {
        $names = $key.GetValueNames()
        foreach ($name in $names) {
            $isSuppression = $script:SuppressionValues -contains $name
            if (-not $isSuppression) { continue }
            try {
                $key.DeleteValue($name, $false)
                $removed++
                Write-Log ("  [repair] stripped suppression value '" + $name + "' from: " + $RegistryPath) -Level "success"
                if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
                    $null = Write-RegistryAuditEvent -Operation "remove" `
                        -Edition $EditionName -Target $TargetName -RegPath ($RegistryPath + "::" + $name) `
                        -Reason "suppression value stripped by repair"
                }
            } catch {
                Write-Log ("  [repair] FAILED to delete value '" + $name + "' on: " + $RegistryPath + " (failure: " + $_.Exception.Message + ")") -Level "warn"
            }
        }
    } finally {
        $key.Close()
    }
    return $removed
}

function Remove-LegacyChildIfPresent {
    <#
    .SYNOPSIS
        Delete one legacy named child key under a fixed parent. Strict
        allow-list: caller passes (parentPath, childName) so this never
        enumerates.
    .OUTPUTS
        'removed' | 'absent' | 'failed'
    #>
    param(
        [Parameter(Mandatory)] [string] $ParentPath,   # e.g. HKCR\Directory\shell
        [Parameter(Mandatory)] [string] $ChildName,    # e.g. "VSCode2"
        [string] $EditionName = "",
        [string] $TargetName  = ""
    )

    $fullExe = (ConvertTo-RegExePathR $ParentPath) + "\" + $ChildName
    $null = reg.exe query $fullExe 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)
    if (-not $isPresent) { return 'absent' }

    Write-Log ("  [repair] removing legacy duplicate: " + $fullExe) -Level "info"
    $null = reg.exe delete $fullExe /f 2>&1
    $hasFailed = ($LASTEXITCODE -ne 0)
    if ($hasFailed) {
        Write-Log ("  [repair] FAILED to remove legacy: " + $fullExe + " (failure: reg.exe exit " + $LASTEXITCODE + ")") -Level "error"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "fail" `
                -Edition $EditionName -Target $TargetName -RegPath $fullExe `
                -Reason "legacy delete failed: reg.exe exit $LASTEXITCODE"
        }
        return 'failed'
    }

    Write-Log ("  [repair] removed legacy: " + $fullExe) -Level "success"
    if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
        $null = Write-RegistryAuditEvent -Operation "remove" `
            -Edition $EditionName -Target $TargetName -RegPath $fullExe `
            -Reason "legacy duplicate cleanup by repair"
    }
    return 'removed'
}

function Get-ShellParentForTarget {
    <#
    .SYNOPSIS
        Maps a target's full key path to its *shell parent* path so the
        legacy-cleanup pass knows where to look.
        e.g. HKCR\Directory\shell\VSCode -> HKCR\Directory\shell
    #>
    param([Parameter(Mandatory)] [string] $RegistryPath)
    $exe = ConvertTo-RegExePathR $RegistryPath
    $idx = $exe.LastIndexOf('\')
    if ($idx -lt 0) { return $exe }
    return $exe.Substring(0, $idx)
}

function Invoke-VsCodeMenuRepair {
    <#
    .SYNOPSIS
        Main entry point for `repair`.
    .DESCRIPTION
        For every enabled edition:
          1. Ensure folder + background entries exist (re-write via
             Register-VsCodeMenuEntry; idempotent).
          2. Surgically delete the file-target entry if present.
          3. Strip suppression values from folder + background entries.
          4. Sweep config.repair.legacyNames under each shell parent and
             delete any matching duplicates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $LogMsgs,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $EditionFilter = "",
        [string] $VsCodePathOverride = ""
    )

    $stats = [ordered]@{
        ensuredFolders     = 0
        ensuredBackgrounds = 0
        droppedFileTargets = 0
        suppressionStripped= 0
        legacyRemoved      = 0
        legacyAbsent       = 0
        editionsSkipped    = 0
        errors             = 0
    }

    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) {
        $editions = $editions | Where-Object { $_ -ieq $EditionFilter }
    }

    $legacyNames = Get-RepairLegacyNames -Config $Config
    Write-Log ("Repair scope: ensure folder+background, drop file-target, strip suppression values, sweep " + $legacyNames.Count + " legacy name(s) per edition.") -Level "info"

    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) {
            Write-Log ("Edition '" + $edName + "' has no editions." + $edName + " block (failure: cannot repair unknown edition)") -Level "warn"
            $stats.editionsSkipped++
            continue
        }
        $ed = $Config.editions.$edName
        Write-Log ("--- Repairing edition '" + $edName + "' (" + $ed.label + ") ---") -Level "info"

        # Resolve exe (needed to (re-)write folder + background entries)
        $vsCodeExe = Resolve-VsCodeExecutable -EditionName $edName `
            -ConfigPath $ed.vsCodePath -Override $VsCodePathOverride -LogMsgs $LogMsgs
        $isExeMissing = -not $vsCodeExe
        if ($isExeMissing) {
            $stats.editionsSkipped++
            $stats.errors++
            continue
        }

        $confirmCfg = $null
        if ($Config.PSObject.Properties.Name -contains 'confirmBeforeLaunch') {
            $confirmCfg = $Config.confirmBeforeLaunch
        }

        # 1. Ensure folder + background entries (idempotent re-write)
        foreach ($keepTarget in @('directory','background')) {
            $regPath = $ed.registryPaths.$keepTarget
            $cmdTpl  = $ed.commandTemplates.$keepTarget
            $ok = Register-VsCodeMenuEntry `
                -TargetName      $keepTarget `
                -RegistryPath    $regPath `
                -Label           $ed.label `
                -VsCodeExe       $vsCodeExe `
                -CommandTemplate $cmdTpl `
                -RepoRoot        $RepoRoot `
                -ConfirmCfg      $confirmCfg `
                -LogMsgs         $LogMsgs `
                -EditionName     $edName
            if (-not $ok) { $stats.errors++; continue }
            if ($keepTarget -eq 'directory')  { $stats.ensuredFolders++     }
            if ($keepTarget -eq 'background') { $stats.ensuredBackgrounds++ }
        }

        # 2. Drop the file-target entry
        $hasFileTarget = $ed.registryPaths.PSObject.Properties.Name -contains 'file'
        if ($hasFileTarget) {
            $fileRegPath = $ed.registryPaths.file
            $status = Remove-VsCodeMenuEntry `
                -TargetName 'file' -RegistryPath $fileRegPath `
                -LogMsgs $LogMsgs -EditionName $edName
            if ($status -eq 'removed') { $stats.droppedFileTargets++ }
            elseif ($status -eq 'failed') { $stats.errors++ }
        }

        # 3. Strip suppression values from the surviving folder + background keys
        foreach ($keepTarget in @('directory','background')) {
            $regPath = $ed.registryPaths.$keepTarget
            $stats.suppressionStripped += (Remove-SuppressionValuesIfPresent `
                -RegistryPath $regPath -EditionName $edName -TargetName $keepTarget)
        }

        # 4. Legacy-name sweep under each of the three shell parents
        $parents = @{}
        foreach ($t in @('file','directory','background')) {
            $hasT = $ed.registryPaths.PSObject.Properties.Name -contains $t
            if (-not $hasT) { continue }
            $parent = Get-ShellParentForTarget -RegistryPath $ed.registryPaths.$t
            $parents[$parent] = $t
        }
        foreach ($parentExe in $parents.Keys) {
            $assocTarget = $parents[$parentExe]
            foreach ($child in $legacyNames) {
                $st = Remove-LegacyChildIfPresent `
                    -ParentPath $parentExe -ChildName $child `
                    -EditionName $edName -TargetName $assocTarget
                switch ($st) {
                    'removed' { $stats.legacyRemoved++ }
                    'absent'  { $stats.legacyAbsent++  }
                    'failed'  { $stats.errors++        }
                }
            }
        }
    }

    Write-Log "" -Level "info"
    Write-Log ("Repair summary -- folders ensured: " + $stats.ensuredFolders `
        + ", backgrounds ensured: " + $stats.ensuredBackgrounds `
        + ", file-targets dropped: " + $stats.droppedFileTargets `
        + ", suppression values stripped: " + $stats.suppressionStripped `
        + ", legacy keys removed: " + $stats.legacyRemoved `
        + ", legacy absent: " + $stats.legacyAbsent `
        + ", errors: " + $stats.errors) -Level $(if ($stats.errors -eq 0) { 'success' } else { 'error' })

    return [pscustomobject]$stats
}
