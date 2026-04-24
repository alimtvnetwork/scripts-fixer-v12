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

switch ($Command.ToLower()) {
    'help'       { Show-ScriptHelp -LogMessages $logMessages; return }
    'dry-run'    { Invoke-ManualRepair -Extra @{ WhatIf = $true } }
    'whatif'     { Invoke-ManualRepair -Extra @{ WhatIf = $true } }
    'trace'      { Invoke-ManualRepair -Extra @{ VerboseRegistry = $true } }
    'verify'     { Invoke-ManualRepair -Extra @{ WhatIf = $true; VerboseRegistry = $true } }
    'restore'    { Invoke-ManualRepair -Extra @{ RestoreDefaultEntries = $true } }
    'rollback'   { Invoke-Rollback }
    'verify-handlers' {
        $ok = Test-VsCodeHandlersRegistered -Config $config -LogMsgs $logMessages -EditionFilter $Edition
        if ($ok) { exit 0 } else { exit 1 }
    }
    'refresh'    {
        # Minimum-components shell refresh.
        # Flags (parsed from $Rest):
        #   --assoc-only      Only SHChangeNotify(SHCNE_ASSOCCHANGED)
        #   --broadcast-only  Only WM_SETTINGCHANGE 'Environment' broadcast
        #   --both            Send both (default)
        #   --restart|--full  Also kill+relaunch explorer.exe (fallback)
        #   --verify          After refresh, run handler PASS/FAIL check
        $isAssocOnly     = $false
        $isBroadcastOnly = $false
        $isExplicitBoth  = $false
        $isFullRestart   = $false
        $isPostVerify    = $false
        if ($null -ne $Rest -and $Rest.Count -gt 0) {
            foreach ($a in $Rest) {
                $low = "$a".Trim().ToLower()
                switch ($low) {
                    { $_ -in @('--assoc-only','-assoc-only','assoc-only','--assoc','-assoc','assoc') }         { $isAssocOnly = $true }
                    { $_ -in @('--broadcast-only','-broadcast-only','broadcast-only','--broadcast','broadcast') } { $isBroadcastOnly = $true }
                    { $_ -in @('--both','-both','both') }                                                       { $isExplicitBoth = $true }
                    { $_ -in @('--restart','-restart','restart','--full','-full','full') }                       { $isFullRestart = $true }
                    { $_ -in @('--verify','-verify','verify') }                                                  { $isPostVerify = $true }
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
        $ok = Invoke-ShellRefresh `
                -LogMsgs       $logMessages `
                -FullRestart:$isFullRestart `
                -WaitMs        $waitMs `
                -SendAssoc     $sendAssoc `
                -SendBroadcast $sendBroadcast
        $verifyOk = $true
        if ($isPostVerify) {
            $verifyOk = Test-VsCodeHandlersRegistered -Config $config -LogMsgs $logMessages -EditionFilter $Edition
        }
        if ($ok -and $verifyOk) { exit 0 } else { exit 1 }
    }
    'repair'     { Invoke-ManualRepair }
    default      { } # 'all' / 'no-restart' / unknown -> fall through to legacy path
}

# -- Banner -------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

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

    # -- Assert admin ---------------------------------------------------------
    Write-Log $logMessages.messages.checkingAdmin -Level "info"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $hasAdminRights = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ($logMessages.messages.currentUser -replace '\{name\}', $identity.Name) -Level "info"
    Write-Log ($logMessages.messages.isAdministrator -replace '\{value\}', $hasAdminRights) -Level $(if ($hasAdminRights) { "success" } else { "error" })

    $isNotAdmin = -not $hasAdminRights
    if ($isNotAdmin) {
        Write-Log $logMessages.messages.notAdmin -Level "error"
        return
    }

    # -- Per-edition processing ----------------------------------------------
    $installType     = $config.installationType
    $enabledEditions = $config.enabledEditions
    $removeTargets   = @($config.removeFromTargets)
    $ensureTargets   = @($config.ensureOnTargets)
    $isAllSuccessful = $true

    Write-Log ($logMessages.messages.installTypePref -replace '\{type\}', $installType) -Level "info"
    Write-Log ($logMessages.messages.enabledEditions -replace '\{editions\}', ($enabledEditions -join ', ')) -Level "info"

    foreach ($editionName in $enabledEditions) {
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

        # 1. Remove unwanted targets
        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            $hasPath = -not [string]::IsNullOrWhiteSpace($regPath)
            if (-not $hasPath) { continue }
            $ok = Remove-ContextMenuTarget -TargetName $target -RegistryPath $regPath -LogMsgs $logMessages
            if (-not $ok) { $isAllSuccessful = $false }
        }

        # 2. Ensure desired targets (folder)
        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            $hasPath = -not [string]::IsNullOrWhiteSpace($regPath)
            if (-not $hasPath) { continue }
            if ($isExeMissing) {
                Write-Log ("Cannot ensure target '$target' -- VS Code executable missing for edition '$editionName' (path: $regPath)") -Level "error"
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
        }

        # 3. Verify
        Write-Log $logMessages.messages.verify -Level "info"
        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Test-TargetState -TargetName $target -RegistryPath $regPath -Expected "absent" -LogMsgs $logMessages
            if (-not $ok) { $isAllSuccessful = $false }
        }
        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $ok = Test-TargetState -TargetName $target -RegistryPath $regPath -Expected "present" -LogMsgs $logMessages
            if (-not $ok) { $isAllSuccessful = $false }
        }
    }

    # -- Restart Explorer -----------------------------------------------------
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
