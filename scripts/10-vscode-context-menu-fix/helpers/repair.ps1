<#
.SYNOPSIS
    Repair the VS Code right-click context menu so it appears on FOLDERS
    + folder BACKGROUND but NOT on individual FILES. Also strips
    suppression hints and sweeps legacy duplicate keys.

.DESCRIPTION
    Mirror of scripts/54-vscode-menu-installer/helpers/vscode-repair.ps1
    re-implemented against Script 10's primitives:

      KEEP  : HKCR\Directory\shell\<Name>
      KEEP  : HKCR\Directory\Background\shell\<Name>
      DROP  : HKCR\*\shell\<Name>

    Four passes per edition:
      1. ENSURE  -- (re)write directory + background entries via
                    Register-ContextMenu (idempotent).
      2. DROP    -- delete the file-target entry via reg.exe delete.
      3. STRIP   -- remove suppression values
                    (ProgrammaticAccessOnly, AppliesTo, NoWorkingDirectory,
                     LegacyDisable, CommandFlags) from the surviving keys.
      4. SWEEP   -- delete legacy duplicate child keys listed in
                    config.repair.legacyNames (strict allow-list, never
                    enumerates outside the list).

    Each registry write/delete is captured in the audit log via
    Write-RegistryAuditEvent so the change is reversible / traceable.
#>

Set-StrictMode -Version Latest

$_helperDir10 = $PSScriptRoot
$_sharedDir10 = Join-Path (Split-Path -Parent (Split-Path -Parent $_helperDir10)) "shared"
$_loggingPath10 = Join-Path $_sharedDir10 "logging.ps1"
if ((Test-Path $_loggingPath10) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath10
}
# Same-script peers (registry.ps1 supplies Register-ContextMenu / Resolve-VsCodePath)
foreach ($peer in @("registry.ps1","audit-snapshot.ps1")) {
    $peerPath = Join-Path $_helperDir10 $peer
    if (Test-Path -LiteralPath $peerPath) { . $peerPath }
}

$script:Repair10SuppressionValues = @(
    'ProgrammaticAccessOnly',
    'AppliesTo',
    'NoWorkingDirectory',
    'LegacyDisable',
    'CommandFlags'
)

function ConvertTo-RegExePathR10 {
    param([string]$PsPath)
    $p = $PsPath -replace '^Registry::', ''
    return ($p -replace '^HKEY_CLASSES_ROOT', 'HKCR')
}

function Get-Repair10LegacyNames {
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

function Get-Repair10ShellParent {
    param([string]$RegistryPath)
    $exe = ConvertTo-RegExePathR10 $RegistryPath
    $idx = $exe.LastIndexOf('\')
    if ($idx -lt 0) { return $exe }
    return $exe.Substring(0, $idx)
}

function Remove-Repair10SuppressionValues {
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
    $key  = $hkcr.OpenSubKey($sub, $true)
    if ($null -eq $key) { return 0 }

    $removed = 0
    try {
        $names = $key.GetValueNames()
        foreach ($name in $names) {
            $isSuppression = $script:Repair10SuppressionValues -contains $name
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

function Remove-Repair10LegacyChild {
    <#
    .SYNOPSIS
        Delete one legacy named child key under a fixed parent (HKCR-relative).
        Strict allow-list: caller passes (parentExePath, childName) so this
        never enumerates.
    .OUTPUTS
        'removed' | 'absent' | 'failed'
    #>
    param(
        [Parameter(Mandatory)] [string] $ParentExePath,  # e.g. HKCR\Directory\shell
        [Parameter(Mandatory)] [string] $ChildName,
        [string] $EditionName = "",
        [string] $TargetName  = ""
    )

    $fullExe = $ParentExePath + "\" + $ChildName
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

function Remove-Repair10FileTarget {
    <#
    .SYNOPSIS
        Delete HKCR\*\shell\<Name> for one edition.
    .OUTPUTS
        'removed' | 'absent' | 'failed'
    #>
    param(
        [Parameter(Mandatory)] [string] $RegistryPath,
        [string] $EditionName = ""
    )
    $exe = ConvertTo-RegExePathR10 $RegistryPath
    $null = reg.exe query $exe 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)
    if (-not $isPresent) {
        Write-Log ("  [repair] file-target already absent: " + $exe) -Level "info"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "skip-absent" `
                -Edition $EditionName -Target 'file' -RegPath $exe `
                -Reason "file-target absent on repair"
        }
        return 'absent'
    }
    $null = reg.exe delete $exe /f 2>&1
    $hasFailed = ($LASTEXITCODE -ne 0)
    if ($hasFailed) {
        Write-Log ("  [repair] FAILED to delete file-target: " + $exe + " (failure: reg.exe exit " + $LASTEXITCODE + ")") -Level "error"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "fail" `
                -Edition $EditionName -Target 'file' -RegPath $exe `
                -Reason "file-target delete failed: reg.exe exit $LASTEXITCODE"
        }
        return 'failed'
    }
    Write-Log ("  [repair] dropped file-target: " + $exe) -Level "success"
    if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
        $null = Write-RegistryAuditEvent -Operation "remove" `
            -Edition $EditionName -Target 'file' -RegPath $exe `
            -Reason "file-target removed by repair"
    }
    return 'removed'
}

function Invoke-Script10Repair {
    <#
    .SYNOPSIS
        Main repair entry point for Script 10. See module synopsis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $LogMessages,
        [Parameter(Mandatory)] [string] $ScriptDir,
        [string] $InstallType   = "user",
        [string] $EditionFilter = ""
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

    $legacyNames = Get-Repair10LegacyNames -Config $Config
    Write-Log ("Repair scope: ensure folder+background, drop file-target, strip suppression values, sweep " + $legacyNames.Count + " legacy name(s) per edition.") -Level "info"

    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) {
            Write-Log ("Edition '" + $edName + "' has no editions." + $edName + " block (failure: cannot repair unknown edition)") -Level "warn"
            $stats.editionsSkipped++
            continue
        }
        $ed = $Config.editions.$edName
        Write-Log ("--- Repairing edition '" + $edName + "' (" + $ed.contextMenuLabel + ") ---") -Level "info"

        # Resolve VS Code exe (needed to (re-)write folder + background entries)
        $vsCodeExe = Resolve-VsCodePath -PathConfig $ed.vscodePath -PreferredType $InstallType `
            -ScriptDir $ScriptDir -EditionName $edName
        $isExeMissing = -not $vsCodeExe
        if ($isExeMissing) {
            Write-Log ("Cannot repair edition '" + $edName + "': VS Code exe not found (failure: see Resolve-VsCodePath log above; tried installationType=" + $InstallType + ")") -Level "error"
            $stats.editionsSkipped++
            $stats.errors++
            continue
        }

        $label   = $ed.contextMenuLabel
        $iconVal = "`"$vsCodeExe`""

        # 1. Ensure folder + background entries (idempotent)
        $ensureMap = @(
            @{ Step = "[repair] ensure FOLDER";            Target='directory';  Path=$ed.registryPaths.directory;  Cmd="`"$vsCodeExe`" `"%V`"" },
            @{ Step = "[repair] ensure FOLDER BACKGROUND"; Target='background'; Path=$ed.registryPaths.background; Cmd="`"$vsCodeExe`" `"%V`"" }
        )
        foreach ($e in $ensureMap) {
            $ok = Register-ContextMenu `
                -StepLabel $e.Step `
                -RegistryPath $e.Path `
                -Label $label `
                -IconValue $iconVal `
                -CommandArg $e.Cmd `
                -LogMsgs $LogMessages
            if ($ok) {
                if ($e.Target -eq 'directory')  { $stats.ensuredFolders++     }
                if ($e.Target -eq 'background') { $stats.ensuredBackgrounds++ }
                if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
                    $null = Write-RegistryAuditEvent -Operation "add" `
                        -Edition $edName -Target $e.Target -RegPath (ConvertTo-RegExePathR10 $e.Path) `
                        -Values @{ "(Default)"=$label; "Icon"=$iconVal; "command"=$e.Cmd } `
                        -Reason "ensured by repair"
                }
            } else {
                $stats.errors++
            }
        }

        # 2. Drop the file-target entry
        $hasFileTarget = $ed.registryPaths.PSObject.Properties.Name -contains 'file'
        if ($hasFileTarget) {
            $st = Remove-Repair10FileTarget -RegistryPath $ed.registryPaths.file -EditionName $edName
            if ($st -eq 'removed') { $stats.droppedFileTargets++ }
            elseif ($st -eq 'failed') { $stats.errors++ }
        }

        # 3. Strip suppression values from the surviving folder + background keys
        foreach ($keepTarget in @('directory','background')) {
            $hasKey = $ed.registryPaths.PSObject.Properties.Name -contains $keepTarget
            if (-not $hasKey) { continue }
            $regPath = $ed.registryPaths.$keepTarget
            $stats.suppressionStripped += (Remove-Repair10SuppressionValues `
                -RegistryPath $regPath -EditionName $edName -TargetName $keepTarget)
        }

        # 4. Legacy-name sweep under each of the three shell parents
        $parents = @{}
        foreach ($t in @('file','directory','background')) {
            $hasT = $ed.registryPaths.PSObject.Properties.Name -contains $t
            if (-not $hasT) { continue }
            $parent = Get-Repair10ShellParent -RegistryPath $ed.registryPaths.$t
            $parents[$parent] = $t
        }
        foreach ($parentExe in $parents.Keys) {
            $assocTarget = $parents[$parentExe]
            foreach ($child in $legacyNames) {
                $st = Remove-Repair10LegacyChild `
                    -ParentExePath $parentExe -ChildName $child `
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