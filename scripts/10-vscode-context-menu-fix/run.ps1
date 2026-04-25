# --------------------------------------------------------------------------
#  Script 10 -- VS Code Context Menu Fix
#  Restores "Open with Code" to the Windows right-click context menu.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [string]$Edition,

    [switch]$ExitCodeMap,

    [switch]$SkipRollbackVerify,

    [string[]]$Only = @(),

    # -- Interactive check prompts (opt-in; off by default to preserve CI) --
    [switch]$Interactive,
    [switch]$PromptEach,
    [switch]$PromptOneShot,
    [switch]$AssumeYes,
    [switch]$DryRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),

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

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\registry.ps1")
. (Join-Path $scriptDir "helpers\audit-snapshot.ps1")
. (Join-Path $scriptDir "helpers\repair.ps1")
. (Join-Path $scriptDir "helpers\check.ps1")
. (Join-Path $scriptDir "helpers\rollback-verify.ps1")
. (Join-Path $scriptDir "helpers\check-interactive.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {


# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Disabled check ------------------------------------------------------------
$isDisabled = -not $config.enabled
if ($isDisabled) {
    Write-Log $logMessages.messages.scriptDisabled -Level "warn"
    return
}

# -- Read-only verbs (no admin needed) ----------------------------------------
$cmdLower = $Command.ToLower()
if ($cmdLower -eq 'check') {
    Write-Log $logMessages.messages.checkStart -Level "info"
    # Reset MISS collector ONCE so both passes accumulate into a single
    # consolidated action summary printed at the end.
    Reset-Check10MissActions
    $checkA = Invoke-Script10MenuCheck -Config $config -EditionFilter $Edition
    $checkB = Invoke-Script10RepairInvariantCheck -Config $config -EditionFilter $Edition
    $totalMiss = $checkA.totalMiss + $checkB.totalMiss
    $totalPass = $checkA.totalPass + $checkB.totalPass
    Write-Log "" -Level "info"
    Write-Log ("Combined check totals: PASS=" + $totalPass + ", MISS=" + $totalMiss) -Level $(if ($totalMiss -eq 0) { 'success' } else { 'error' })
    $oneShot = if ([string]::IsNullOrWhiteSpace($Edition)) { ".\run.ps1 repair" } else { ".\run.ps1 repair -Edition " + $Edition }
    Write-Check10MissActionSummary -ScriptInvocationHint $oneShot

    # ---- Interactive prompt block (opt-in; preserves all existing exits)----
    # Only engages when at least one of the flags is set AND we have misses
    # to act on. CI is preserved: -ExitCodeMap suppresses prompts unless
    # -AssumeYes is also explicitly passed.
    $wantInteractive = ($Interactive -or $PromptEach -or $PromptOneShot)
    $hasMisses       = $totalMiss -gt 0
    $isCiMode        = $ExitCodeMap -and (-not $AssumeYes)
    if ($wantInteractive -and $hasMisses -and -not $isCiMode) {
        $mode = 'oneshot'
        if ($PromptEach -and $PromptOneShot) { $mode = 'both' }
        elseif ($PromptEach)                 { $mode = 'each' }
        elseif ($PromptOneShot)              { $mode = 'oneshot' }
        # Bare -Interactive defaults to one-shot prompt only.

        $thisRunPs1 = Join-Path $scriptDir "run.ps1"
        $null = Invoke-Check10Interactive `
            -Mode $mode `
            -OneShotCommand $oneShot `
            -RunScriptPath $thisRunPs1 `
            -AssumeYes:$AssumeYes `
            -DryRun:$DryRun
    } elseif ($wantInteractive -and $isCiMode) {
        Write-Log "Interactive flags ignored: -ExitCodeMap is on (CI mode). Pass -AssumeYes alongside -ExitCodeMap to force non-interactive auto-fix." -Level "warn"
    }

    if ($totalMiss -le 0) { exit 0 }
    if (-not $ExitCodeMap) { exit 1 }

    # CI-friendly granular exit codes. Buckets:
    #   10 = install-state, 20 = file-target, 21 = suppression,
    #   22 = legacy, 30 = multi-invariant, 40 = mixed.
    # Drives off the MISS action collector populated by both check passes.
    $actions = Get-Check10MissActions
    $hasInstall = @($actions | Where-Object { $_.category -eq 'install' }).Count -gt 0
    $invariantBuckets = @()
    foreach ($a in $actions) {
        if ($a.category -ne 'invariant') { continue }
        if ($a.target -eq 'file')                          { $invariantBuckets += 20 }
        elseif ($a.target -in @('directory','background')) { $invariantBuckets += 21 }
        elseif ($a.target -like 'legacy:*')                { $invariantBuckets += 22 }
    }
    $invariantBuckets = @($invariantBuckets | Sort-Object -Unique)
    $hasInvariant     = $invariantBuckets.Count -gt 0
    $isMixed          = $hasInstall -and $hasInvariant
    $isMultiInvariant = (-not $hasInstall) -and ($invariantBuckets.Count -ge 2)

    $code = 1
    if ($isMixed)              { $code = 40 }
    elseif ($isMultiInvariant) { $code = 30 }
    elseif ($hasInvariant)     { $code = $invariantBuckets[0] }
    elseif ($hasInstall)       { $code = 10 }

    Write-Log "" -Level "info"
    Write-Log ("CI exit code (ExitCodeMap=on): " + $code) -Level "warn"
    Write-Log "  Legend: 10=install-state, 20=file-target, 21=suppression, 22=legacy, 30=multi-invariant, 40=mixed" -Level "info"
    exit $code
}

# -- Smoke verb -- runs install + check end-to-end and asserts exit codes ----
# The smoke harness has its OWN admin check (and a -DryRun bypass), so we
# dispatch to it BEFORE the global admin assertion below. Passes -Edition
# and any unrecognised -<switch> args through via $Rest.
if ($cmdLower -eq 'smoke') {
    $smokeScript = Join-Path $scriptDir "tests\smoke-install-check.ps1"
    $isSmokeMissing = -not (Test-Path -LiteralPath $smokeScript)
    if ($isSmokeMissing) {
        Write-Log ("Smoke harness not found at: " + $smokeScript + " (failure: cannot run smoke verb without tests/smoke-install-check.ps1)") -Level "error"
        exit 2
    }
    $smokeArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Edition)) { $smokeArgs += @('-Edition', $Edition) }
    if ($Rest.Count -gt 0) { $smokeArgs += $Rest }
    & $smokeScript @smokeArgs
    exit $LASTEXITCODE
}

# -- Assert admin --------------------------------------------------------------
$hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isNotAdmin = -not $hasAdminRights
if ($isNotAdmin) {
    Write-Log $logMessages.messages.notAdmin -Level "error"
    Write-Host $script:SharedLogMessages.messages.adminTip -ForegroundColor Yellow
    return
}

# -- Repair verb (admin) ------------------------------------------------------
if ($cmdLower -eq 'repair') {
    Initialize-RegistryAudit -Action 'install' -ScriptDir $scriptDir | Out-Null
    $snap = New-PreInstallSnapshot -Config $config -ScriptDir $scriptDir
    if ($snap) { Write-Log ("Pre-repair snapshot saved: " + $snap + " (manual restore: reg.exe import `"<path>`")") -Level "info" }
    $stats = Invoke-Script10Repair -Config $config -LogMessages $logMessages -ScriptDir $scriptDir `
        -InstallType $config.installationType -EditionFilter $Edition -OnlySelectors $Only
    Write-Log ("Audit log: " + (Get-RegistryAuditPath)) -Level "info"
    if ($stats.errors -gt 0) { exit 1 } else { exit 0 }
    return
}

# -- Rollback verb (admin) ----------------------------------------------------
if ($cmdLower -eq 'rollback') {
    $latestSnap = Get-LatestSnapshotPath -ScriptDir $scriptDir
    if ($latestSnap) {
        Write-Log ("Most recent pre-install snapshot (manual import option): " + $latestSnap) -Level "info"
        Write-Log ("  reg.exe import """ + $latestSnap + """") -Level "info"
    } else {
        Write-Log "No pre-install snapshot found under .audit\snapshots\ -- proceeding with surgical removal of keys we created." -Level "warn"
    }

    if ($SkipRollbackVerify) {
        Write-Log "Rollback verification SKIPPED (-SkipRollbackVerify). Running surgical uninstall only." -Level "warn"
        Initialize-RegistryAudit -Action 'uninstall' -ScriptDir $scriptDir | Out-Null
        Uninstall-VsCodeContextMenu -Config $config -LogMessages $logMessages
        Write-Log ("Audit log: " + (Get-RegistryAuditPath)) -Level "info"
        return
    }

    # ---- Phase 1: pre-rollback snapshot of CURRENT state -------------------
    $preRollbackSnap = New-PreRollbackSnapshot -Config $config -ScriptDir $scriptDir
    if ($preRollbackSnap) {
        Write-Log ("Pre-rollback snapshot saved: " + $preRollbackSnap) -Level "info"
        Write-Log ("  Manual undo of THIS rollback: reg.exe import """ + $preRollbackSnap + """") -Level "info"
    } else {
        Write-Log "Pre-rollback snapshot was NOT created (failure: see preceding warnings; rollback will continue but cannot be reverted via .reg import)" -Level "warn"
    }

    # ---- Phase 2: invariant baseline (read-only) ---------------------------
    $beforeSnap = Invoke-RollbackInvariantBaseline -Config $config

    # ---- Phase 3: actually roll back (surgical uninstall) ------------------
    Initialize-RegistryAudit -Action 'uninstall' -ScriptDir $scriptDir | Out-Null
    Uninstall-VsCodeContextMenu -Config $config -LogMessages $logMessages
    Write-Log ("Audit log: " + (Get-RegistryAuditPath)) -Level "info"

    # ---- Phase 4: re-run the same invariants on post-rollback state -------
    $afterSnap = Invoke-RollbackInvariantPost -Config $config

    # ---- Phase 5: print verdict, set exit code ----------------------------
    $report = Write-RollbackVerificationReport -Before $beforeSnap -After $afterSnap -SnapshotPath $preRollbackSnap
    if ($report.verified) { exit 0 } else { exit 1 }
}

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Initialize-RegistryAudit -Action 'uninstall' -ScriptDir $scriptDir | Out-Null
    Uninstall-VsCodeContextMenu -Config $config -LogMessages $logMessages
    Write-Log ("Audit log: " + (Get-RegistryAuditPath)) -Level "info"
    return
}

# -- Process editions ----------------------------------------------------------
# Auto-snapshot every install run (per spec: always, automatically).
Initialize-RegistryAudit -Action 'install' -ScriptDir $scriptDir | Out-Null
$snapPath = New-PreInstallSnapshot -Config $config -ScriptDir $scriptDir
if ($snapPath) {
    Write-Log ("Pre-install snapshot saved: " + $snapPath + " (manual restore: reg.exe import `"<path>`")") -Level "info"
} else {
    Write-Log "Pre-install snapshot was NOT created (failure: see preceding warnings; install will continue)" -Level "warn"
}

$installType     = $config.installationType
$enabledEditions = $config.enabledEditions
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

    $result = Invoke-Edition `
        -Edition     $edition `
        -EditionName $editionName `
        -InstallType $installType `
        -ScriptDir   $scriptDir `
        -Steps       @{
            detectInstall = $logMessages.messages.detectInstall
            regFile       = $logMessages.messages.regFile
            regDir        = $logMessages.messages.regDir
            regBg         = $logMessages.messages.regBg
            verify        = $logMessages.messages.verify
        }

    $hasFailed = -not $result
    if ($hasFailed) { $isAllSuccessful = $false }
}

# -- Summary -------------------------------------------------------------------
if ($isAllSuccessful) {
    Write-Log $logMessages.messages.done -Level "success"
} else {
    Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
}

Write-Log ("Audit log: " + (Get-RegistryAuditPath)) -Level "info"

# -- Save resolved state -------------------------------------------------------
Save-ResolvedData -ScriptFolder "10-vscode-context-menu-fix" -Data @{
    editions  = ($enabledEditions -join ',')
    timestamp = (Get-Date -Format "o")
}

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}