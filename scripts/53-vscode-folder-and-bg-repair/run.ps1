# --------------------------------------------------------------------------
#  Script 53 -- VS Code Folder + Background Context Menu Repair
#
#  Re-registers BOTH right-click scenarios:
#    * Right-click ON a folder              -> Directory\shell\VSCode
#    * Right-click in EMPTY space in folder -> Directory\Background\shell\VSCode
#
#  Also removes the file-target leaf (HKCR\*\shell\VSCode) so right-click on
#  a FILE does NOT show the entry. Restarts explorer.exe so the changes
#  appear immediately.
#
#  Reuses script 52's repair helpers verbatim (Set-FolderContextMenuEntry,
#  Remove-ContextMenuTarget, Test-TargetState, Write-VerificationSummary,
#  Restart-Explorer, Resolve-VsCodePath). Behavior diff vs 52: 53 ENSURES
#  background instead of removing it.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "repair",

    [ValidateSet('', 'stable', 'insiders')]
    [string]$Edition = '',

    # Disable transactional rollback (default ON for `repair-vscode`).
    [switch]$NoRollback,

    # Restore the most recent registry snapshot for each edition (or one
    # specified via -BackupFile) and exit. Equivalent to `Command = 'rollback'`.
    [switch]$Rollback,

    # Optional explicit .reg snapshot to restore (overrides auto-pick of latest).
    [string]$BackupFile = '',

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "vscode-edition-detect.ps1")
. (Join-Path $sharedDir "admin-check.ps1")
. (Join-Path $sharedDir "registry-backup.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Reuse script 52's repair helpers (Set/Remove/Test + summary + restart) --
$_script52Helpers = Join-Path (Split-Path -Parent $scriptDir) "52-vscode-folder-repair\helpers\repair.ps1"
if (-not (Test-Path -LiteralPath $_script52Helpers)) {
    Write-Host "FATAL: required helper not found at: $_script52Helpers (script 52 must remain present alongside script 53)" -ForegroundColor Red
    exit 2
}
. $_script52Helpers

# -- Dot-source script 53's own pre-check helper -------------------------------
$_precheckHelper = Join-Path $scriptDir "helpers\precheck.ps1"
if (-not (Test-Path -LiteralPath $_precheckHelper)) {
    Write-Host "FATAL: precheck helper not found at: $_precheckHelper (failure: cannot run script 53 without helpers/precheck.ps1)" -ForegroundColor Red
    exit 2
}
. $_precheckHelper

# -- Dot-source script 53's rollback helper ------------------------------------
$_rollbackHelper = Join-Path $scriptDir "helpers\rollback.ps1"
if (-not (Test-Path -LiteralPath $_rollbackHelper)) {
    Write-Host "FATAL: rollback helper not found at: $_rollbackHelper (failure: cannot run script 53 without helpers/rollback.ps1)" -ForegroundColor Red
    exit 2
}
. $_rollbackHelper

# -- Load config & log messages -----------------------------------------------
$configPath = Join-Path $scriptDir "config.json"
$logPath    = Join-Path $scriptDir "log-messages.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "FATAL: config.json not found at: $configPath (failure: cannot run script 53 without its config)" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path -LiteralPath $logPath)) {
    Write-Host "FATAL: log-messages.json not found at: $logPath (failure: cannot run script 53 without log-messages.json)" -ForegroundColor Red
    exit 2
}
$config      = Import-JsonConfig $configPath
$logMessages = Import-JsonConfig $logPath

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help" -or $Command.ToLower() -eq 'help') {
    Show-ScriptHelp -LogMessages $logMessages

    # -- Extra prose sections (permissions / behavior / how-to-verify) ---------
    function _Write-HelpSection {
        param([Parameter(Mandatory)] $Node, [Parameter(Mandatory)] [ConsoleColor]$TitleColor)
        $hasNode = $null -ne $Node
        if (-not $hasNode) { return }
        Write-Host $Node.title -ForegroundColor $TitleColor
        Write-Host (("-" * [Math]::Min($Node.title.Length, 60))) -ForegroundColor DarkGray
        foreach ($line in @($Node.lines)) { Write-Host "  $line" -ForegroundColor Gray }
        Write-Host ""
    }
    _Write-HelpSection -Node $logMessages.permissions   -TitleColor Yellow
    _Write-HelpSection -Node $logMessages.behavior      -TitleColor Cyan
    _Write-HelpSection -Node $logMessages.verifySection -TitleColor Green
    return
}

# -- Command classification ---------------------------------------------------
$cmdLower             = $Command.ToLower()
$isReadOnlyCommand    = $cmdLower -in @('verify','dry-run','whatif','precheck','pre-check','plan')
# `repair-vscode` is the explicit transactional all-in-one command:
#   pre-check -> backup -> apply -> verify -> auto-rollback on failure.
$isTransactionalCmd   = $cmdLower -in @('repair-vscode','repair-all','transactional','tx')
$isRollbackEnabled    = $isTransactionalCmd -and -not $NoRollback
# Manual rollback (--rollback flag OR `rollback` command): restore latest
# snapshot per edition (or the one passed via -BackupFile) and exit.
$isManualRollback     = $Rollback.IsPresent -or ($cmdLower -in @('rollback','restore','undo'))

if (-not $isReadOnlyCommand) {
    Assert-Elevated `
        -ScriptPath $PSCommandPath `
        -Reason     'Script 53 writes HKEY_CLASSES_ROOT\Directory\shell\VSCode and Directory\Background\shell\VSCode entries -- requires Administrator.'
}

# -- Banner -------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) --------------------------------
Write-InstallPaths `
    -Tool   "VS Code folder + background right-click repair" `
    -Action "Repair" `
    -Source "registry HKCR\Directory\shell + Background\shell entries" `
    -Temp   ($env:TEMP + "\scripts-fixer\vscode-folder-bg-repair") `
    -Target ("HKCR:\Directory\shell\VSCode  +  HKCR:\Directory\Background\shell\VSCode")

# -- Initialize logging -------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

    Invoke-GitPull

    $isDisabled = -not $config.enabled
    if ($isDisabled) {
        Write-Log $logMessages.messages.scriptDisabled -Level "warn"
        return
    }

    # -- Per-edition processing ----------------------------------------------
    $installType    = $config.installationType
    $configEditions = @($config.enabledEditions)
    $removeTargets  = @($config.removeFromTargets)
    $ensureTargets  = @($config.ensureOnTargets)
    $isAllSuccessful     = $true
    $verificationResults = @()

    # -- Backup + change ledger setup ----------------------------------------
    $backupRoot   = Join-Path $scriptDir ".logs\registry-backups"
    $backupResult = $null
    Start-RegistryChangeLog

    Write-Log ($logMessages.messages.installTypePref -replace '\{type\}', $installType) -Level "info"
    Write-Log ($logMessages.messages.enabledEditions -replace '\{editions\}', ($configEditions -join ', ')) -Level "info"

    $detectedEditions = @(Get-InstalledVsCodeEditions -EnabledEditions $configEditions -LogMsgs $logMessages)
    if (-not [string]::IsNullOrWhiteSpace($Edition)) {
        $detectedEditions = @($detectedEditions | Where-Object { $_ -eq $Edition })
    }
    $hasNoneInstalled = ($detectedEditions.Count -eq 0)
    if ($hasNoneInstalled) {
        Write-Log "[edition-detect] no enabled VS Code editions are installed (or filter excluded all) -- nothing to repair." -Level "warn"
        return
    }

    # -- MANUAL ROLLBACK: --rollback flag or `rollback` command --------------
    if ($isManualRollback) {
        Write-Log ("Manual rollback requested -- restoring from snapshots in {0}" -f $backupRoot) -Level "warn"
        $rb = Invoke-ManualRollback `
            -Config             $config `
            -BackupRoot         $backupRoot `
            -Editions           $detectedEditions `
            -ExplicitBackupFile $BackupFile

        # Persist a ledger row per edition for auditability.
        foreach ($row in $rb.Summary) {
            Add-RegistryChange -Operation 'ROLLBACK' -Edition $row.Edition -Target '-' `
                -Path $row.Backup `
                -Detail $(if ($row.Success) { 'manual rollback restored from snapshot' } else { 'manual rollback FAILED -- see log above' }) `
                -Success ([bool]$row.Success)
        }

        $changeLogPath = Save-RegistryChangeLog -OutputDir $backupRoot -Tag 'script53-rollback'
        Write-RegistryChangeLog -BackupFilePath '' -JsonLogPath $(if ($changeLogPath) { $changeLogPath } else { '' })

        # Restart explorer so restored entries appear immediately.
        $isNoRestartCommand = $cmdLower -eq "no-restart"
        $shouldRestart      = $config.restartExplorer -and -not $isNoRestartCommand
        if ($shouldRestart) {
            $waitMs = if ($config.PSObject.Properties.Match('restartExplorerWaitMs').Count) { [int]$config.restartExplorerWaitMs } else { 800 }
            $null = Restart-Explorer -WaitMs $waitMs -LogMsgs $logMessages
        }

        if ($rb.Success) {
            Write-Log "Manual rollback completed successfully." -Level "success"
        } else {
            Write-Log "Manual rollback completed with errors -- review log above." -Level "error"
        }
        return
    }

    # -- PRE-CHECK: report current state + planned actions BEFORE writing -----
    $isDryRun = $Command.ToLower() -in @('dry-run','whatif','precheck','pre-check','plan')
    Write-Log "Running pre-check (inspecting current registry state, no writes)..." -Level "info"
    $planRows = Invoke-FolderRepairPreCheck `
        -Config           $config `
        -LogMessages      $logMessages `
        -DetectedEditions $detectedEditions `
        -InstallType      $installType `
        -ScriptDir        $scriptDir `
        -ApplyMode:(-not $isDryRun)

    if ($isDryRun) {
        Write-Log "Dry-run mode -- no changes were applied. Re-run without 'dry-run' / 'precheck' to apply." -Level "success"
        return
    }

    $rollbackSummary = @()
    foreach ($editionName in $detectedEditions) {
        $edition = $config.editions.$editionName

        $isEditionMissing = -not $edition
        if ($isEditionMissing) {
            Write-Log ($logMessages.messages.unknownEdition -replace '\{name\}', $editionName) -Level "warn"
            $isAllSuccessful = $false
            continue
        }

        # Per-edition transactional state
        $editionApplyOk     = $true
        $editionPreState    = @{}
        $editionBackupFile  = $null

        Write-Host ""
        Write-Host $logMessages.messages.editionBorderLine -ForegroundColor DarkCyan
        Write-Host ($logMessages.messages.editionLabel -replace '\{label\}', $edition.contextMenuLabel) -ForegroundColor Cyan
        Write-Host $logMessages.messages.editionBorderLine -ForegroundColor DarkCyan

        Write-Log $logMessages.messages.detectInstall -Level "info"
        $vsCodeExe = Resolve-VsCodePath `
            -PathConfig    $edition.vscodePath `
            -PreferredType $installType `
            -ScriptDir     $scriptDir `
            -EditionName   $editionName

        $hasEnsureWork = $ensureTargets.Count -gt 0
        $isExeMissing  = -not $vsCodeExe
        if ($hasEnsureWork -and $isExeMissing) {
            Write-Log ($logMessages.messages.exeNotFound -replace '\{label\}', $edition.contextMenuLabel) -Level "warn"
        } elseif ($vsCodeExe) {
            Write-Log ($logMessages.messages.usingExe -replace '\{path\}', $vsCodeExe) -Level "success"
        }

        # 0. BEFORE backup of every key we might touch
        $editionKeys = @()
        foreach ($t in ($removeTargets + $ensureTargets)) {
            $rp = $edition.registryPaths.$t
            if (-not [string]::IsNullOrWhiteSpace($rp)) { $editionKeys += $rp }
        }
        if ($editionKeys.Count -gt 0) {
            Write-Log ("Creating registry backup for edition '$editionName' ({0} key(s))..." -f $editionKeys.Count) -Level "info"
            $editionBackup = New-RegistryBackup -Keys $editionKeys -OutputDir $backupRoot -Tag "script53-$editionName"
            if ($editionBackup -and $editionBackup.FilePath) {
                Write-Log ("Backup written: {0}" -f $editionBackup.FilePath) -Level "success"
                $backupResult      = $editionBackup
                $editionBackupFile = $editionBackup.FilePath
                # Capture pre-apply present/absent state per key, used by rollback verifier.
                $editionPreState = Capture-PreApplyState -Keys $editionKeys
                foreach ($kr in $editionBackup.Keys) {
                    $detail = if ($kr.Present) { if ($kr.Exported) { 'exported' } else { 'export FAILED' } } else { 'absent at backup time' }
                    Add-RegistryChange -Operation 'BACKUP' -Edition $editionName -Target '-' `
                        -Path $kr.Path -Detail $detail -Success ([bool]$kr.Exported -or -not $kr.Present)
                }
            } else {
                Write-Log "Backup step failed -- aborting writes for this edition to avoid an unrecoverable state (backup dir: $backupRoot)" -Level "error"
                Add-RegistryChange -Operation 'FAIL' -Edition $editionName -Target '-' `
                    -Path $backupRoot -Detail 'backup failed; writes skipped' -Success $false
                $isAllSuccessful = $false
                continue
            }
        }

        # 1. Remove unwanted targets (file-only by default)
        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Remove-ContextMenuTarget -TargetName $target -RegistryPath $regPath -LogMsgs $logMessages
            if (-not $ok) { $isAllSuccessful = $false; $editionApplyOk = $false }
            $op     = if ($ok) { 'DELETE' } else { 'FAIL' }
            $detail = if ($ok) { 'context menu entry removed (or already absent)' } else { 'reg.exe delete failed -- see log above' }
            Add-RegistryChange -Operation $op -Edition $editionName -Target $target `
                -Path $regPath -Detail $detail -Success ([bool]$ok)
        }

        # 2. Ensure desired targets (directory + background)
        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            if ($isExeMissing) {
                Write-Log ("Cannot ensure target '$target' -- VS Code executable missing for edition '$editionName' (path: $regPath)") -Level "error"
                Add-RegistryChange -Operation 'SKIP' -Edition $editionName -Target $target `
                    -Path $regPath -Detail 'VS Code executable not found' -Success $false
                $isAllSuccessful = $false
                $editionApplyOk  = $false
                continue
            }
            $ok = Set-FolderContextMenuEntry `
                -TargetName   $target `
                -RegistryPath $regPath `
                -Label        $edition.contextMenuLabel `
                -VsCodeExe    $vsCodeExe `
                -LogMsgs      $logMessages
            if (-not $ok) { $isAllSuccessful = $false; $editionApplyOk = $false }
            $op     = if ($ok) { 'WRITE' } else { 'FAIL' }
            $detail = if ($ok) { ("ensured '{0}' -> {1}" -f $edition.contextMenuLabel, $vsCodeExe) } else { 'CreateSubKey/SetValue failed -- see log above' }
            Add-RegistryChange -Operation $op -Edition $editionName -Target $target `
                -Path $regPath -Detail $detail -Success ([bool]$ok)
        }

        # 3. Verify
        Write-Log $logMessages.messages.verify -Level "info"
        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Test-TargetState -TargetName $target -RegistryPath $regPath -Expected "absent" -LogMsgs $logMessages
            $verificationResults += @{
                Edition  = $editionName
                Target   = $target
                Expected = 'absent'
                Actual   = $(if ($ok) { 'absent' } else { 'present' })
                Pass     = [bool]$ok
                Path     = $regPath
            }
            if (-not $ok) { $isAllSuccessful = $false; $editionApplyOk = $false }
        }
        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Test-TargetState -TargetName $target -RegistryPath $regPath -Expected "present" -LogMsgs $logMessages
            $verificationResults += @{
                Edition  = $editionName
                Target   = $target
                Expected = 'present'
                Actual   = $(if ($ok) { 'present' } else { 'absent' })
                Pass     = [bool]$ok
                Path     = $regPath
            }
            if (-not $ok) { $isAllSuccessful = $false; $editionApplyOk = $false }
        }

        # 4. Transactional rollback (only when caller opted in via `repair-vscode`)
        if (-not $editionApplyOk -and $isRollbackEnabled) {
            if ([string]::IsNullOrWhiteSpace($editionBackupFile)) {
                Write-Log ("Rollback requested for edition '{0}' but no backup file is available -- cannot restore prior state." -f $editionName) -Level "error"
                Add-RegistryChange -Operation 'FAIL' -Edition $editionName -Target '-' `
                    -Path '-' -Detail 'rollback requested but backup file missing' -Success $false
            } else {
                Write-Log ("Apply/verify failed for edition '{0}' -- triggering transactional rollback from {1}" -f $editionName, $editionBackupFile) -Level "warn"
                $rb = Invoke-FolderRepairRollback `
                    -BackupFilePath $editionBackupFile `
                    -EditionName    $editionName `
                    -TouchedKeys    $editionKeys `
                    -PreState       $editionPreState `
                    -Reason         'apply or verify phase failed'
                $rollbackSummary += @{ Edition = $editionName; Success = $rb.Success; Backup = $editionBackupFile }
                Add-RegistryChange -Operation 'ROLLBACK' -Edition $editionName -Target '-' `
                    -Path $editionBackupFile `
                    -Detail $(if ($rb.Success) { 'restored from snapshot' } else { 'rollback INCOMPLETE -- manual reg import required' }) `
                    -Success ([bool]$rb.Success)
            }
        }
    }

    # -- PASS/FAIL summary table ---------------------------------------------
    if ($verificationResults.Count -gt 0) {
        $summaryOk = Write-VerificationSummary -Results $verificationResults
        if (-not $summaryOk) { $isAllSuccessful = $false }
    }

    # -- Persist change ledger -----------------------------------------------
    $changeLogPath = Save-RegistryChangeLog -OutputDir $backupRoot -Tag 'script53'
    $primaryBackup = if ($backupResult) { $backupResult.FilePath } else { '' }
    $logPathArg    = if ($changeLogPath) { $changeLogPath } else { '' }
    Write-RegistryChangeLog -BackupFilePath $primaryBackup -JsonLogPath $logPathArg

    # -- Restart explorer ----------------------------------------------------
    $isNoRestartCommand = $Command.ToLower() -eq "no-restart"
    $shouldRestart      = $config.restartExplorer -and -not $isNoRestartCommand
    if ($shouldRestart) {
        $waitMs = if ($config.PSObject.Properties.Match('restartExplorerWaitMs').Count) { [int]$config.restartExplorerWaitMs } else { 800 }
        $null = Restart-Explorer -WaitMs $waitMs -LogMsgs $logMessages
    } else {
        Write-Log $logMessages.messages.explorerSkipped -Level "info"
    }

    if ($rollbackSummary.Count -gt 0) {
        Write-Host ""
        Write-Host "  Rollback summary (transactional repair-vscode):" -ForegroundColor Cyan
        foreach ($r in $rollbackSummary) {
            $color = if ($r.Success) { 'Green' } else { 'Red' }
            $tag   = if ($r.Success) { 'RESTORED' } else { 'INCOMPLETE' }
            Write-Host ("    [{0}] {1,-10}  backup: {2}" -f $tag, $r.Edition, $r.Backup) -ForegroundColor $color
        }
        Write-Host ""
    }

    if ($isAllSuccessful) {
        Write-Log $logMessages.messages.done -Level "success"
    } elseif ($isRollbackEnabled -and $rollbackSummary.Count -gt 0 -and ($rollbackSummary | Where-Object { -not $_.Success }).Count -eq 0) {
        Write-Log "Apply failed but transactional rollback restored prior state for all affected editions." -Level "warn"
    } else {
        Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
    }

    Save-ResolvedData -ScriptFolder "53-vscode-folder-and-bg-repair" -Data @{
        editions        = ($detectedEditions -join ',')
        removeTargets   = ($removeTargets -join ',')
        ensureTargets   = ($ensureTargets -join ',')
        restartExplorer = [bool]$shouldRestart
        timestamp       = (Get-Date -Format "o")
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
