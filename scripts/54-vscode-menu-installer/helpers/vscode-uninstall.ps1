<#
.SYNOPSIS
    Surgical uninstall logic for the VS Code menu installer (script 54).

.DESCRIPTION
    The uninstaller iterates ONLY over the registry paths declared in
    config.json::editions.<name>.registryPaths. It never enumerates the
    registry, never reads a sibling key, never deletes anything that is
    not on the allow-list.

    This is the safety guarantee for users who have other 'shell' entries
    under the same parent (e.g. HKCR\Directory\shell\VSCode2 from a
    different installer) -- those entries are provably untouched because
    they never enter the loop.
#>

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_auditPath = Join-Path $PSScriptRoot "audit-log.ps1"
if ((Test-Path $_auditPath) -and -not (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue)) {
    . $_auditPath
}

function ConvertTo-RegExePathU {
    param([string]$PsPath)
    $p = $PsPath -replace '^Registry::', ''
    return ($p -replace '^HKEY_CLASSES_ROOT', 'HKCR')
}

function Remove-VsCodeMenuEntry {
    <#
    .SYNOPSIS
        Surgically removes ONE registry entry by full path. Recursive delete
        handles the \command subkey. Returns a status code:
          'removed'  -- key existed and was deleted
          'absent'   -- key did not exist; nothing to do
          'failed'   -- delete failed; reason logged with full path
    #>
    param(
        [string]$TargetName,
        [string]$RegistryPath,
        $LogMsgs,
        [string]$EditionName = ""
    )

    $regPath = ConvertTo-RegExePathU $RegistryPath

    $null = reg.exe query $regPath 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)
    if (-not $isPresent) {
        Write-Log ((($LogMsgs.messages.alreadyAbsent -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "info"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "skip-absent" `
                -Edition $EditionName -Target $TargetName -RegPath $regPath
        }
        return 'absent'
    }

    Write-Log ((($LogMsgs.messages.removingTarget -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "info"
    $null = reg.exe delete $regPath /f 2>&1
    $hasFailed = ($LASTEXITCODE -ne 0)
    if ($hasFailed) {
        $msg = ($LogMsgs.messages.removeFailed -replace '\{path\}', $regPath) -replace '\{error\}', ("reg.exe exit " + $LASTEXITCODE)
        Write-Log $msg -Level "error"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "fail" `
                -Edition $EditionName -Target $TargetName -RegPath $regPath `
                -Reason ("reg.exe delete exited " + $LASTEXITCODE)
        }
        return 'failed'
    }
    Write-Log ((($LogMsgs.messages.removed -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "success"
    if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
        $null = Write-RegistryAuditEvent -Operation "remove" `
            -Edition $EditionName -Target $TargetName -RegPath $regPath
    }
    return 'removed'
}

function Get-EditionAllowList {
    <#
    .SYNOPSIS
        Returns the strict allow-list of registry paths for an edition,
        in the order [file, directory, background]. Skips any null/empty
        entry and logs which ones it returned.
    #>
    param(
        $EditionConfig
    )

    $paths = @()
    foreach ($target in @('file', 'directory', 'background')) {
        $val = $EditionConfig.registryPaths.$target
        $hasVal = -not [string]::IsNullOrWhiteSpace($val)
        if ($hasVal) {
            $paths += [PSCustomObject]@{ Target = $target; Path = $val }
        }
    }
    return $paths
}
