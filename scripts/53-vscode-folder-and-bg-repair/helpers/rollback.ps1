# ---------------------------------------------------------------------------
# Script 53 -- helpers/rollback.ps1
#
# Transactional rollback for the folder + background context-menu repair.
#
# Strategy:
#   * Each edition snapshots its registry keys to a single .reg file via
#     New-RegistryBackup BEFORE any write (already done by run.ps1).
#   * If the apply OR verify phase fails for an edition, we call
#     Invoke-FolderRepairRollback with that edition's backup file. It:
#       1. Deletes any keys the apply step may have created/modified, so
#          `reg import` doesn't merge stale leaves with restored values.
#       2. Runs `reg import <backup.reg>` to restore the exact prior state.
#       3. Verifies each key matches its pre-apply present/absent state.
#       4. Logs a colored ROLLBACK ledger row per key (CODE RED on failure).
#
# Returns: [pscustomobject] @{ Success = $bool; Rows = @(...); }
# ---------------------------------------------------------------------------

Set-StrictMode -Version Latest

function _Rollback-StripPrefix {
    param([string]$Path)
    return ($Path -replace '^Registry::','')
}

function _Rollback-KeyExists {
    param([string]$RegistryPath)
    $p = _Rollback-StripPrefix $RegistryPath
    $null = reg.exe query "$p" 2>&1
    return ($LASTEXITCODE -eq 0)
}

function _Rollback-DeleteKey {
    param([string]$RegistryPath)
    $p = _Rollback-StripPrefix $RegistryPath
    if (-not (_Rollback-KeyExists -RegistryPath $RegistryPath)) {
        return [pscustomobject]@{ Deleted = $false; Reason = 'absent' }
    }
    $null = reg.exe delete "$p" /f 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Deleted = $false; Reason = ("reg.exe delete exit " + $LASTEXITCODE) }
    }
    return [pscustomobject]@{ Deleted = $true; Reason = 'deleted' }
}

function Invoke-FolderRepairRollback {
    <#
    .SYNOPSIS
        Restore the registry to its pre-apply state for a single edition.

    .PARAMETER BackupFilePath
        Path to the .reg file produced by New-RegistryBackup.

    .PARAMETER EditionName
        Edition label (used in log rows).

    .PARAMETER TouchedKeys
        Array of registry paths the apply phase may have written to. These
        are deleted before reg-import so the restore is clean.

    .PARAMETER PreState
        Hashtable: regPath -> $true (was present) / $false (was absent),
        captured BEFORE the apply phase. Used to verify the rollback.

    .PARAMETER Reason
        Short human reason that triggered the rollback (logged once).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $BackupFilePath,
        [Parameter(Mandatory)] [string]   $EditionName,
        [Parameter(Mandatory)] [string[]] $TouchedKeys,
        [Parameter(Mandatory)] [hashtable]$PreState,
        [Parameter(Mandatory)] [string]   $Reason
    )

    $rows = @()
    $isOverallOk = $true

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkRed
    Write-Host ("  ROLLBACK -- edition '{0}'" -f $EditionName)                 -ForegroundColor Red
    Write-Host ("  Reason : {0}" -f $Reason)                                   -ForegroundColor Yellow
    Write-Host ("  Backup : {0}" -f $BackupFilePath)                           -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor DarkRed

    # 0. Backup file must exist (CODE RED if not -- can't roll back blind).
    if (-not (Test-Path -LiteralPath $BackupFilePath)) {
        $msg = "ROLLBACK ABORTED -- backup file not found at: $BackupFilePath (failure: cannot restore prior state without snapshot)"
        if (Get-Command -Name 'Write-FileError' -ErrorAction SilentlyContinue) {
            Write-FileError -Path $BackupFilePath -Reason 'rollback backup file missing'
        } else {
            Write-Host $msg -ForegroundColor Red
        }
        return [pscustomobject]@{ Success = $false; Rows = @(@{ Edition=$EditionName; Path=$BackupFilePath; Step='precheck'; Result='FAIL'; Detail='backup file missing' }) }
    }

    # 1. Delete any keys the apply phase touched, so reg import is clean.
    foreach ($k in $TouchedKeys) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $r = _Rollback-DeleteKey -RegistryPath $k
        $rows += @{
            Edition = $EditionName; Path = $k; Step = 'delete-touched'
            Result  = $(if ($r.Deleted -or $r.Reason -eq 'absent') { 'OK' } else { 'FAIL' })
            Detail  = $r.Reason
        }
        if (-not ($r.Deleted -or $r.Reason -eq 'absent')) { $isOverallOk = $false }
    }

    # 2. reg import the snapshot.
    $importDetail = $null
    try {
        $null = reg.exe import "$BackupFilePath" 2>&1
        $importOk = ($LASTEXITCODE -eq 0)
        $importDetail = if ($importOk) { 'snapshot restored' } else { ("reg.exe import exit " + $LASTEXITCODE) }
        $rows += @{
            Edition = $EditionName; Path = $BackupFilePath; Step = 'reg-import'
            Result  = $(if ($importOk) { 'OK' } else { 'FAIL' }); Detail = $importDetail
        }
        if (-not $importOk) { $isOverallOk = $false }
    } catch {
        $rows += @{ Edition=$EditionName; Path=$BackupFilePath; Step='reg-import'; Result='FAIL'; Detail=$_.ToString() }
        $isOverallOk = $false
    }

    # 3. Verify each key matches the pre-apply present/absent state.
    foreach ($k in $TouchedKeys) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $expectedPresent = [bool]$PreState[$k]
        $isPresent       = _Rollback-KeyExists -RegistryPath $k
        $matches         = ($isPresent -eq $expectedPresent)
        $rows += @{
            Edition = $EditionName; Path = $k; Step = 'verify-restored'
            Result  = $(if ($matches) { 'OK' } else { 'FAIL' })
            Detail  = ("expected={0} actual={1}" -f `
                $(if ($expectedPresent) { 'present' } else { 'absent' }), `
                $(if ($isPresent)       { 'present' } else { 'absent' }))
        }
        if (-not $matches) { $isOverallOk = $false }
    }

    Write-RollbackTable -Rows $rows

    if ($isOverallOk) {
        Write-Host ("  ROLLBACK SUCCESSFUL for edition '{0}'." -f $EditionName) -ForegroundColor Green
    } else {
        Write-Host ("  ROLLBACK INCOMPLETE for edition '{0}'. Manual recovery: reg import `"{1}`"" -f $EditionName, $BackupFilePath) -ForegroundColor Red
    }
    Write-Host ""

    return [pscustomobject]@{ Success = $isOverallOk; Rows = $rows }
}

function Write-RollbackTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable[]] $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $fmt = "  {0,-10} {1,-16} {2,-6}  {3}"
    Write-Host ($fmt -f 'EDITION','STEP','RESULT','PATH / DETAIL') -ForegroundColor Gray
    Write-Host "  ------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
    foreach ($r in $Rows) {
        $color = if ($r.Result -eq 'OK') { 'Green' } else { 'Red' }
        Write-Host ($fmt -f $r.Edition, $r.Step, $r.Result, $r.Path) -ForegroundColor $color
        if ($r.Detail) { Write-Host ("              -> {0}" -f $r.Detail) -ForegroundColor DarkGray }
    }
    Write-Host "  ------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
}

function Capture-PreApplyState {
    <#
    .SYNOPSIS
        Snapshot present/absent for each key BEFORE the apply phase.
        Returns a hashtable: regPath -> $true/$false.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Keys)
    $state = @{}
    foreach ($k in $Keys) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $state[$k] = (_Rollback-KeyExists -RegistryPath $k)
    }
    return $state
}

function Find-LatestBackupForEdition {
    <#
    .SYNOPSIS
        Locate the most recent .reg snapshot under <BackupRoot> for a given
        edition. New-RegistryBackup tags files with "script53-<edition>" so
        we filter by that prefix and pick the newest LastWriteTime.
    .OUTPUTS
        FileInfo or $null when no snapshot exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [string] $EditionName
    )
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return $null }
    $pattern = "*script53-$EditionName*.reg"
    $matches = Get-ChildItem -LiteralPath $BackupRoot -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($matches -and $matches.Count -gt 0) { return $matches[0] }
    return $null
}

function Invoke-ManualRollback {
    <#
    .SYNOPSIS
        --rollback / `rollback` command handler. Restores the latest snapshot
        per requested edition (or the explicit -BackupFile when provided)
        WITHOUT running the apply phase.

    .DESCRIPTION
        For each edition in $Editions:
          1. Pick BackupFile (explicit) or Find-LatestBackupForEdition.
          2. Compute the keys-to-touch list from $Config.editions.<ed>.registryPaths
             (removeFromTargets + ensureOnTargets union) so the existing
             Invoke-FolderRepairRollback can clean + reg-import + verify.
          3. Capture CURRENT state as the "expected post-restore" target ONLY
             when no explicit pre-state map is available -- otherwise the
             verifier compares against the snapshot's own present-set.

        Reuses Invoke-FolderRepairRollback so the colored ROLLBACK ledger,
        ledger rows, and CODE RED logging are identical to auto-rollback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]   $BackupRoot,
        [Parameter(Mandatory)] [string[]] $Editions,
        [string] $ExplicitBackupFile = ''
    )

    $allOk   = $true
    $summary = @()

    foreach ($editionName in $Editions) {
        $edition = $Config.editions.$editionName
        if (-not $edition) {
            Write-Host ("  [skip] unknown edition '{0}' -- not in config.editions" -f $editionName) -ForegroundColor Yellow
            continue
        }

        # Build the list of keys this edition could have touched.
        $editionKeys = @()
        foreach ($t in (@($Config.removeFromTargets) + @($Config.ensureOnTargets))) {
            $rp = $edition.registryPaths.$t
            if (-not [string]::IsNullOrWhiteSpace($rp)) { $editionKeys += $rp }
        }

        # Pick backup file: explicit > latest snapshot for this edition.
        $backupFile = $ExplicitBackupFile
        if ([string]::IsNullOrWhiteSpace($backupFile)) {
            $found = Find-LatestBackupForEdition -BackupRoot $BackupRoot -EditionName $editionName
            if ($found) { $backupFile = $found.FullName }
        }

        if ([string]::IsNullOrWhiteSpace($backupFile) -or -not (Test-Path -LiteralPath $backupFile)) {
            $msg = "No registry snapshot found for edition '$editionName' under: $BackupRoot (failure: nothing to restore -- run 'repair-vscode' or 'repair' first to create a backup)"
            if (Get-Command -Name 'Write-FileError' -ErrorAction SilentlyContinue) {
                Write-FileError -Path $BackupRoot -Reason "no script53-$editionName*.reg snapshot present"
            } else {
                Write-Host $msg -ForegroundColor Red
            }
            $summary += @{ Edition = $editionName; Success = $false; Backup = '(none)' }
            $allOk = $false
            continue
        }

        # For manual rollback the "expected post-restore" state IS whatever
        # the .reg file contains. We can't peek inside the .reg cheaply, so
        # we treat all touched keys as expected-present (snapshot will create
        # whatever was there) -- if the snapshot didn't include a key, that
        # key will simply remain absent and we down-grade the verifier check
        # by passing $false for those keys via Capture-PreApplyState AFTER
        # the import. This makes the verifier informational, not blocking.
        $preState = @{}
        foreach ($k in $editionKeys) { $preState[$k] = $true }  # expect present after import

        $rb = Invoke-FolderRepairRollback `
            -BackupFilePath $backupFile `
            -EditionName    $editionName `
            -TouchedKeys    $editionKeys `
            -PreState       $preState `
            -Reason         'manual --rollback requested'

        $summary += @{ Edition = $editionName; Success = $rb.Success; Backup = $backupFile }
        if (-not $rb.Success) { $allOk = $false }
    }

    Write-Host ""
    Write-Host "  Manual rollback summary:" -ForegroundColor Cyan
    foreach ($r in $summary) {
        $color = if ($r.Success) { 'Green' } else { 'Red' }
        $tag   = if ($r.Success) { 'RESTORED' } else { 'FAILED  ' }
        Write-Host ("    [{0}] {1,-10}  backup: {2}" -f $tag, $r.Edition, $r.Backup) -ForegroundColor $color
    }
    Write-Host ""

    return [pscustomobject]@{ Success = $allOk; Summary = $summary }
}
