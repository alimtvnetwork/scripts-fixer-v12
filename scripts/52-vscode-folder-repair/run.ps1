# --------------------------------------------------------------------------
#  Script 52 -- VS Code Folder-Only Context Menu Repair
#
#  Single entry point. All operations are exposed as SUBCOMMANDS so callers
#  never have to invoke manual-repair.ps1 / rollback.ps1 directly with long
#  parameter lists. The dispatcher just forwards to the right helper.
#
#  Subcommands:
#    repair         (default) Folder-only repair + Explorer restart
#    dry-run        Preview repair (no registry writes, no snapshots)
#    no-restart     Repair but do NOT restart explorer.exe
#    verify         Verify final state without changing anything
#    trace          Repair with -VerboseRegistry trace
#    restore        Re-import the newest BEFORE snapshot (undo via snapshot)
#    rollback       Restore default installer entries on all 3 targets
#    refresh        Lightweight shell refresh (supports --verify post-check)
#    verify-handlers  Standalone PASS/FAIL check that VS Code menu handlers
#                     are registered. Read-only, no writes, no refresh.
#    help           Show usage + examples
#
#  Common options:
#    -Edition stable|insiders   Target edition (auto-detected when omitted)
#    -SnapshotDir <path>        Override snapshot folder
#    -RequireSignature          Enforce Authenticode signer check
#    -NonInteractive            Suppress prompts (CI mode)
#    -RestoreFromFile <path>    Explicit .reg snapshot for `restore`
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "repair",

    [ValidateSet('', 'stable', 'insiders')]
    [string]$Edition = '',

    [string]$SnapshotDir,
    [string]$RestoreFromFile,
    [switch]$RequireSignature,
    [switch]$NonInteractive,

    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
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

# -- Dot-source script helpers (also brings in script 10's registry helpers) -
. (Join-Path $scriptDir "helpers\repair.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Admin elevation gate -----------------------------------------------------
# Fail FAST (exit 87) before the dispatcher so the user gets a clear retry
# command instead of a cryptic registry-write failure deep inside a
# subcommand. Read-only subcommands skip the gate -- they don't write
# anywhere and are useful when triaging from a non-elevated shell.
$readOnlySubcommands = @('help','dry-run','whatif','verify','verify-handlers')
$normalizedCommand   = $Command.ToLower()
$isReadOnlyCommand   = $readOnlySubcommands -contains $normalizedCommand
if (-not $isReadOnlyCommand) {
    # Rebuild the original argv as a single string for the retry hint so
    # users can copy-paste exactly what they ran. PSBoundParameters covers
    # named params; $Rest covers passthrough flags after the subcommand.
    $retryParts = @()
    if (-not [string]::IsNullOrWhiteSpace($Command)) { $retryParts += $Command }
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -in @('Command','Rest','Help')) { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $retryParts += "-$k" }
        } elseif ($null -ne $v -and "$v" -ne '') {
            $retryParts += "-$k"
            $retryParts += "`"$v`""
        }
    }
    if ($null -ne $Rest -and $Rest.Count -gt 0) { $retryParts += $Rest }
    $retryArgs = ($retryParts -join ' ').Trim()

    Assert-Elevated `
        -ScriptPath  $PSCommandPath `
        -ScriptArgs  $retryArgs `
        -Reason      'Script 52 writes HKEY_CLASSES_ROOT\Directory\shell\VSCode entries -- requires Administrator.'
}

# --------------------------------------------------------------------------
# Subcommand dispatcher
#
# All "manual" workflows that used to require calling manual-repair.ps1
# directly with long parameter lists are now exposed as named subcommands
# of run.ps1. The dispatcher forwards to the right helper and exits.
# Anything not matched here falls through to the legacy folder-only
# repair flow below (kept for backwards compatibility).
# --------------------------------------------------------------------------
function Invoke-ManualRepair {
    param([hashtable]$Extra = @{})

    $manual = Join-Path $scriptDir "manual-repair.ps1"
    if (-not (Test-Path -LiteralPath $manual)) {
        Write-Host "FATAL: manual-repair.ps1 not found at $manual" -ForegroundColor Red
        exit 2
    }

    $args = @{}
    if (-not [string]::IsNullOrWhiteSpace($Edition))         { $args['Edition']           = $Edition }
    if (-not [string]::IsNullOrWhiteSpace($SnapshotDir))     { $args['SnapshotDir']       = $SnapshotDir }
    if (-not [string]::IsNullOrWhiteSpace($RestoreFromFile)) { $args['RestoreFromFile']   = $RestoreFromFile }
    if ($RequireSignature)                                   { $args['RequireSignature']  = $true }
    if ($NonInteractive)                                     { $args['NonInteractive']    = $true }
    foreach ($k in $Extra.Keys) { $args[$k] = $Extra[$k] }

    & $manual @args
    exit $LASTEXITCODE
}

function Invoke-Rollback {
    $rb = Join-Path $scriptDir "rollback.ps1"
    if (-not (Test-Path -LiteralPath $rb)) {
        Write-Host "FATAL: rollback.ps1 not found at $rb" -ForegroundColor Red
        exit 2
    }
    $args = @{}
    if (-not [string]::IsNullOrWhiteSpace($Edition)) { $args['Edition'] = $Edition }
    & $rb @args
    exit $LASTEXITCODE
}

function Show-RefreshHelp {
    param([PSObject]$LogMsgs)

    $hasBlock = $LogMsgs.help.PSObject.Properties.Name -contains 'refresh'
    if (-not $hasBlock) {
        Write-Host "ERROR: refresh help block missing from log-messages.json (key: help.refresh)" -ForegroundColor Red
        return
    }
    $r = $LogMsgs.help.refresh

    Write-Host ""
    Write-Host $r.title   -ForegroundColor Cyan
    Write-Host ""
    Write-Host $r.summary -ForegroundColor Gray
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host ("  " + $r.usage) -ForegroundColor White
    Write-Host ""
    Write-Host "STEPS (each is independent and controlled by its own flag)" -ForegroundColor Yellow
    foreach ($s in $r.steps) {
        Write-Host ""
        Write-Host ("  " + $s.name) -ForegroundColor Green
        Write-Host ("    What:         " + $s.what)         -ForegroundColor Gray
        Write-Host ("    When to use:  " + $s.when)         -ForegroundColor Gray
        Write-Host ("    Enabled by:   " + $s.enabledBy)    -ForegroundColor White
        Write-Host ("    Side effects: " + $s.sideEffects)  -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "FLAGS" -ForegroundColor Yellow
    foreach ($f in $r.flags) {
        $label = "{0,-22}" -f $f.flag
        Write-Host ("  " + $label + "  " + $f.effect) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "RULES" -ForegroundColor Yellow
    foreach ($rule in $r.rules) {
        Write-Host ("  - " + $rule) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "EXAMPLES" -ForegroundColor Yellow
    foreach ($ex in $r.examples) {
        Write-Host ("  " + $ex) -ForegroundColor DarkGray
    }
    Write-Host ""
}

switch ($Command.ToLower()) {
    'help'       { Show-ScriptHelp -LogMessages $logMessages; return }
    'dry-run'    { Invoke-ManualRepair -Extra @{ WhatIf = $true } }
    'whatif'     { Invoke-ManualRepair -Extra @{ WhatIf = $true } }
    'trace'      { Invoke-ManualRepair -Extra @{ VerboseRegistry = $true } }
    'verify'     { Invoke-ManualRepair -Extra @{ WhatIf = $true; VerboseRegistry = $true } }
    'restore'    { Invoke-ManualRepair -Extra @{ RestoreDefaultEntries = $true } }
    'rollback'   { Invoke-Rollback }
    'verify-handlers' {
        # Optional --report flag (off by default for standalone read-only runs).
        $isReportRequested = $false
        if ($null -ne $Rest -and $Rest.Count -gt 0) {
            foreach ($a in $Rest) {
                $low = "$a".Trim().ToLower()
                if ($low -in @('--report','-report','report')) { $isReportRequested = $true }
            }
        }

        $result = Test-VsCodeHandlersRegistered -Config $config -LogMsgs $logMessages -EditionFilter $Edition
        if ($isReportRequested) {
            $null = Save-VerificationReport -Result $result -Trigger 'verify-handlers' -EditionFilter $Edition -ScriptDir $scriptDir -LogMsgs $logMessages
        } else {
            Write-Log $logMessages.messages.verifyReportSkipped -Level "info"
        }
        if ($result.ok) { exit 0 } else { exit 1 }
    }
    'refresh'    {
        # Per-subcommand help: '.\run.ps1 refresh --help' / '-help' / 'help'
        $isRefreshHelp = $false
        if ($Help) { $isRefreshHelp = $true }
        if ($null -ne $Rest -and $Rest.Count -gt 0) {
            foreach ($a in $Rest) {
                $low = "$a".Trim().ToLower()
                if ($low -in @('--help','-help','-h','/?','help','?')) { $isRefreshHelp = $true }
            }
        }
        if ($isRefreshHelp) { Show-RefreshHelp -LogMsgs $logMessages; exit 0 }

        # Minimum-components shell refresh.
        # Flags (parsed from $Rest):
        #   --assoc-only      Only SHChangeNotify(SHCNE_ASSOCCHANGED)
        #   --broadcast-only  Only WM_SETTINGCHANGE 'Environment' broadcast
        #   --both            Send both (default)
        #   --restart|--full  Also kill+relaunch explorer.exe (fallback)
        #   --verify          After refresh, run handler PASS/FAIL check
        #   --verify-repair   Like --verify, but on FAIL auto-rerun refresh
        #                     with --both --restart and verify a second time
        $isAssocOnly     = $false
        $isBroadcastOnly = $false
        $isExplicitBoth  = $false
        $isFullRestart   = $false
        $isPostVerify    = $false
        $isVerifyRepair  = $false
        if ($null -ne $Rest -and $Rest.Count -gt 0) {
            foreach ($a in $Rest) {
                $low = "$a".Trim().ToLower()
                switch ($low) {
                    { $_ -in @('--assoc-only','-assoc-only','assoc-only','--assoc','-assoc','assoc') }         { $isAssocOnly = $true }
                    { $_ -in @('--broadcast-only','-broadcast-only','broadcast-only','--broadcast','broadcast') } { $isBroadcastOnly = $true }
                    { $_ -in @('--both','-both','both') }                                                       { $isExplicitBoth = $true }
                    { $_ -in @('--restart','-restart','restart','--full','-full','full') }                       { $isFullRestart = $true }
                    { $_ -in @('--verify','-verify','verify') }                                                  { $isPostVerify = $true }
                    { $_ -in @('--verify-repair','-verify-repair','verify-repair') }                            { $isVerifyRepair = $true; $isPostVerify = $true }
                    default { }
                }
            }
        }
        $hasConflict = $isAssocOnly -and $isBroadcastOnly
        if ($hasConflict) {
            Write-Host "ERROR: --assoc-only and --broadcast-only are mutually exclusive. Use --both (or no flag) to send both." -ForegroundColor Red
            exit 2
        }
        $sendAssoc     = $true
        $sendBroadcast = $true
        if ($isAssocOnly)     { $sendBroadcast = $false }
        if ($isBroadcastOnly) { $sendAssoc     = $false }
        # --both is the default; flag is accepted explicitly for clarity.
        if ($isExplicitBoth)  { $sendAssoc = $true; $sendBroadcast = $true }

        $waitMs = 800
        $hasWait = $config.PSObject.Properties.Match('restartExplorerWaitMs').Count -gt 0
        if ($hasWait) { $waitMs = [int]$config.restartExplorerWaitMs }

        # ---- Pass 1: refresh as requested by user flags ----------------------
        $ok = Invoke-ShellRefresh `
                -LogMsgs       $logMessages `
                -FullRestart:$isFullRestart `
                -WaitMs        $waitMs `
                -SendAssoc     $sendAssoc `
                -SendBroadcast $sendBroadcast

        $verifyOk = $true
        if ($isPostVerify) {
            $result   = Test-VsCodeHandlersRegistered -Config $config -LogMsgs $logMessages -EditionFilter $Edition
            $verifyOk = $result.ok
            $trigger  = if ($isVerifyRepair) { 'refresh-verify-repair-pass1' } else { 'refresh-verify' }
            $null = Save-VerificationReport -Result $result -Trigger $trigger -EditionFilter $Edition -ScriptDir $scriptDir -LogMsgs $logMessages

            # ---- Pass 2: auto-repair if --verify-repair and pass 1 FAILED ----
            $shouldRetry = $isVerifyRepair -and (-not $verifyOk)
            if ($shouldRetry) {
                Write-Log $logMessages.messages.verifyRepairTriggered -Level "warn"
                Write-Log $logMessages.messages.verifyRepairRetryPlan -Level "info"

                $okRetry = Invoke-ShellRefresh `
                            -LogMsgs       $logMessages `
                            -FullRestart:$true `
                            -WaitMs        $waitMs `
                            -SendAssoc     $true `
                            -SendBroadcast $true

                Write-Log $logMessages.messages.verifyRepairSecondVerify -Level "info"
                $result2   = Test-VsCodeHandlersRegistered -Config $config -LogMsgs $logMessages -EditionFilter $Edition
                $verifyOk2 = $result2.ok
                $null = Save-VerificationReport -Result $result2 -Trigger 'refresh-verify-repair-pass2' -EditionFilter $Edition -ScriptDir $scriptDir -LogMsgs $logMessages

                if ($verifyOk2) {
                    Write-Log $logMessages.messages.verifyRepairRecovered -Level "success"
                    $ok = $okRetry
                    $verifyOk = $true
                } else {
                    Write-Log $logMessages.messages.verifyRepairStillFailing -Level "error"
                    $ok = $okRetry
                    $verifyOk = $false
                }
            }
        }
        if ($ok -and $verifyOk) { exit 0 } else { exit 1 }
    }
    'repair'     { Invoke-ManualRepair }
    default      { } # 'all' / 'no-restart' / unknown -> fall through to legacy path
}

# -- Banner -------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "VS Code folder right-click repair" `
    -Action "Repair" `
    -Source "registry HKCR\Directory\shell + Background\shell entries" `
    -Temp   ($env:TEMP + "\scripts-fixer\vscode-folder-repair") `
    -Target ("HKCR:\Directory\shell\VSCode  +  HKCR:\Directory\Background\shell\VSCode")

# -- Initialize logging -------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

    # -- Git pull -------------------------------------------------------------
    Invoke-GitPull

    # -- Disabled check -------------------------------------------------------
    $isDisabled = -not $config.enabled
    if ($isDisabled) {
        Write-Log $logMessages.messages.scriptDisabled -Level "warn"
        return
    }

    # -- Assert admin (defense-in-depth; primary gate is at top of script) ---
    Write-Log $logMessages.messages.checkingAdmin -Level "info"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log ($logMessages.messages.currentUser     -replace '\{name\}',  $identity.Name) -Level "info"
    Write-Log ($logMessages.messages.isAdministrator -replace '\{value\}', (Test-IsElevated)) -Level "success"
    Assert-Elevated `
        -ScriptPath $PSCommandPath `
        -Reason     'Script 52 writes HKEY_CLASSES_ROOT\Directory\shell\VSCode entries -- requires Administrator.'

    # -- Per-edition processing ----------------------------------------------
    # Auto-detect installed editions (Stable vs Insiders) and skip the ones
    # that are not present so we never try to write Insiders registry keys
    # on a Stable-only machine, etc. The shared helper also surfaces the
    # exact registry paths + Code.exe path per detected edition.
    $installType     = $config.installationType
    $configEditions  = @($config.enabledEditions)
    $removeTargets   = @($config.removeFromTargets)
    $ensureTargets   = @($config.ensureOnTargets)
    $isAllSuccessful     = $true
    $verificationResults = @()

    # -- Backup + change ledger setup ----------------------------------------
    # Snapshot every key we might touch BEFORE any write so the user can
    # roll back with `reg import`. The change ledger collects one row per
    # write/delete/skip/fail, persisted to JSON and printed at the end.
    $backupRoot   = Join-Path $scriptDir ".logs\registry-backups"
    $backupResult = $null
    Start-RegistryChangeLog

    Write-Log ($logMessages.messages.installTypePref -replace '\{type\}', $installType) -Level "info"
    Write-Log ($logMessages.messages.enabledEditions -replace '\{editions\}', ($configEditions -join ', ')) -Level "info"

    $detectedEditions = @(Get-InstalledVsCodeEditions -EnabledEditions $configEditions -LogMsgs $logMessages)
    $hasNoneInstalled = ($detectedEditions.Count -eq 0)
    if ($hasNoneInstalled) {
        Write-Log "[edition-detect] no enabled VS Code editions are installed -- nothing to repair." -Level "warn"
        return
    }

    foreach ($editionName in $detectedEditions) {
        $edition = $config.editions.$editionName

        $isEditionMissing = -not $edition
        if ($isEditionMissing) {
            Write-Log ($logMessages.messages.unknownEdition -replace '\{name\}', $editionName) -Level "warn"
            $isAllSuccessful = $false
            continue
        }

        Write-Host ""
        Write-Host $logMessages.messages.editionBorderLine -ForegroundColor DarkCyan
        Write-Host ($logMessages.messages.editionLabel -replace '\{label\}', $edition.contextMenuLabel) -ForegroundColor Cyan
        Write-Host $logMessages.messages.editionBorderLine -ForegroundColor DarkCyan

        # Resolve VS Code exe (only required if we have ensureTargets)
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
            # Still proceed with removal -- removal does not need the exe.
        } elseif ($vsCodeExe) {
            Write-Log ($logMessages.messages.usingExe -replace '\{path\}', $vsCodeExe) -Level "success"
        }

        # 0. BEFORE backup -- snapshot every key we might touch for this
        #    edition into one timestamped .reg file. This is the user's
        #    rollback artifact: `reg import <file>` restores the previous
        #    state for ALL keys, even ones we ended up not changing.
        $editionKeys = @()
        foreach ($t in ($removeTargets + $ensureTargets)) {
            $rp = $edition.registryPaths.$t
            if (-not [string]::IsNullOrWhiteSpace($rp)) { $editionKeys += $rp }
        }
        $hasKeysToBackup = $editionKeys.Count -gt 0
        if ($hasKeysToBackup) {
            Write-Log ("Creating registry backup for edition '$editionName' ({0} key(s))..." -f $editionKeys.Count) -Level "info"
            $editionBackup = New-RegistryBackup -Keys $editionKeys -OutputDir $backupRoot -Tag "script52-$editionName"
            if ($editionBackup -and $editionBackup.FilePath) {
                Write-Log ("Backup written: {0}" -f $editionBackup.FilePath) -Level "success"
                # Keep the most recent successful backup as the primary
                # rollback artifact for the end-of-run summary.
                $backupResult = $editionBackup
                foreach ($kr in $editionBackup.Keys) {
                    $detail = if ($kr.Present) { if ($kr.Exported) { 'exported' } else { 'export FAILED' } } else { 'absent at backup time' }
                    Add-RegistryChange -Operation 'BACKUP' -Edition $editionName -Target '-' `
                        -Path $kr.Path -Detail $detail -Success ([bool]$kr.Exported -or -not $kr.Present)
                }
            } else {
                Write-Log "Backup step failed -- aborting writes for this edition to avoid an unrecoverable state." -Level "error"
                Add-RegistryChange -Operation 'FAIL' -Edition $editionName -Target '-' `
                    -Path $backupRoot -Detail 'backup failed; writes skipped' -Success $false
                $isAllSuccessful = $false
                continue
            }
        }

        # 1. Remove unwanted targets
        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            $hasPath = -not [string]::IsNullOrWhiteSpace($regPath)
            if (-not $hasPath) { continue }
            $ok = Remove-ContextMenuTarget -TargetName $target -RegistryPath $regPath -LogMsgs $logMessages
            if (-not $ok) { $isAllSuccessful = $false }
            $op     = if ($ok) { 'DELETE' } else { 'FAIL' }
            $detail = if ($ok) { 'context menu entry removed (or already absent)' } else { 'reg.exe delete failed -- see log above' }
            Add-RegistryChange -Operation $op -Edition $editionName -Target $target `
                -Path $regPath -Detail $detail -Success ([bool]$ok)
        }

        # 2. Ensure desired targets (folder)
        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            $hasPath = -not [string]::IsNullOrWhiteSpace($regPath)
            if (-not $hasPath) { continue }
            if ($isExeMissing) {
                Write-Log ("Cannot ensure target '$target' -- VS Code executable missing for edition '$editionName' (path: $regPath)") -Level "error"
                Add-RegistryChange -Operation 'SKIP' -Edition $editionName -Target $target `
                    -Path $regPath -Detail 'VS Code executable not found' -Success $false
                $isAllSuccessful = $false
                continue
            }
            $ok = Set-FolderContextMenuEntry `
                -TargetName   $target `
                -RegistryPath $regPath `
                -Label        $edition.contextMenuLabel `
                -VsCodeExe    $vsCodeExe `
                -LogMsgs      $logMessages
            if (-not $ok) { $isAllSuccessful = $false }
            $op     = if ($ok) { 'WRITE' } else { 'FAIL' }
            $detail = if ($ok) { ("ensured '{0}' -> {1}" -f $edition.contextMenuLabel, $vsCodeExe) } else { 'CreateSubKey/SetValue failed -- see log above' }
            Add-RegistryChange -Operation $op -Edition $editionName -Target $target `
                -Path $regPath -Detail $detail -Success ([bool]$ok)
        }

        # 3. Verify (per-target log + structured collection for the summary)
        Write-Log $logMessages.messages.verify -Level "info"
        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Test-TargetState -TargetName $target -RegistryPath $regPath -Expected "absent" -LogMsgs $logMessages
            $actual = if ($ok) { 'absent' } else { 'present' }
            $verificationResults += @{
                Edition  = $editionName
                Target   = $target
                Expected = 'absent'
                Actual   = $actual
                Pass     = [bool]$ok
                Path     = $regPath
            }
            if (-not $ok) { $isAllSuccessful = $false }
        }
        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Test-TargetState -TargetName $target -RegistryPath $regPath -Expected "present" -LogMsgs $logMessages
            $actual = if ($ok) { 'present' } else { 'absent' }
            $verificationResults += @{
                Edition  = $editionName
                Target   = $target
                Expected = 'present'
                Actual   = $actual
                Pass     = [bool]$ok
                Path     = $regPath
            }
            if (-not $ok) { $isAllSuccessful = $false }
        }
    }

    # -- Pass/fail verification summary (folder vs empty-space vs file) -------
    $hasResults = $verificationResults.Count -gt 0
    if ($hasResults) {
        $summaryOk = Write-VerificationSummary -Results $verificationResults
        if (-not $summaryOk) { $isAllSuccessful = $false }
    }

    # -- Registry change ledger (persist JSON + render colored table) --------
    $changeLogPath = Save-RegistryChangeLog -OutputDir $backupRoot -Tag 'script52'
    $primaryBackup = if ($backupResult) { $backupResult.FilePath } else { '' }
    $logPathArg    = if ($changeLogPath) { $changeLogPath } else { '' }
    Write-RegistryChangeLog -BackupFilePath $primaryBackup -JsonLogPath $logPathArg

    $isNoRestartCommand = $Command.ToLower() -eq "no-restart"
    $shouldRestart      = $config.restartExplorer -and -not $isNoRestartCommand
    if ($shouldRestart) {
        $waitMs = if ($config.PSObject.Properties.Match('restartExplorerWaitMs').Count) { [int]$config.restartExplorerWaitMs } else { 800 }
        $null = Restart-Explorer -WaitMs $waitMs -LogMsgs $logMessages
    } else {
        Write-Log $logMessages.messages.explorerSkipped -Level "info"
    }

    # -- Summary --------------------------------------------------------------
    if ($isAllSuccessful) {
        Write-Log $logMessages.messages.done -Level "success"
    } else {
        Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
    }

    # -- Save resolved state --------------------------------------------------
    Save-ResolvedData -ScriptFolder "52-vscode-folder-repair" -Data @{
        editions        = ($enabledEditions -join ',')
        removeTargets   = ($removeTargets   -join ',')
        ensureTargets   = ($ensureTargets   -join ',')
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
