# --------------------------------------------------------------------------
#  Script 54 -- run.ps1 (router)
#
#  Routes to install.ps1 / uninstall.ps1 so the project's master -I 54
#  dispatcher can invoke this script with a verb.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "install",

    [string]$Edition,
    [string]$VsCodePath,
    [ValidateSet('Auto','CurrentUser','AllUsers')]
    [string]$Scope = 'Auto',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# -- Help (router-level: lists ALL commands, not just install) --------------
function Show-RouterHelp {
    $sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"
    . (Join-Path $sharedDir "logging.ps1")
    . (Join-Path $sharedDir "help.ps1")
    $logMsgs = Get-Content -LiteralPath (Join-Path $scriptDir "log-messages.json") -Raw | ConvertFrom-Json
    Show-ScriptHelp -LogMessages $logMsgs
    Write-Host ""
    Write-Host "  Privilege summary:" -ForegroundColor Yellow
    Write-Host "    install / uninstall / repair -- AllUsers needs Administrator;" -ForegroundColor Gray
    Write-Host "                                    CurrentUser runs as any user." -ForegroundColor Gray
    Write-Host "    check / verify              -- read-only, run as any user." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Scope (-Scope flag, default Auto):" -ForegroundColor Yellow
    Write-Host "    Auto         -- AllUsers when elevated, else CurrentUser" -ForegroundColor Gray
    Write-Host "    CurrentUser  -- writes to HKCU\Software\Classes (only this user)" -ForegroundColor Gray
    Write-Host "    AllUsers     -- writes to HKEY_CLASSES_ROOT (all users; needs admin)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Tip: launch an elevated PowerShell with:" -ForegroundColor Yellow
    Write-Host "    Start-Process pwsh -Verb RunAs -ArgumentList '-NoExit','-Command','cd ""$((Split-Path -Parent (Split-Path -Parent $scriptDir)))""'" -ForegroundColor DarkGray
    Write-Host ""
}

if ($Help -or $Command -ieq "help" -or $Command -ieq "--help" -or $Command -ieq "-h") {
    Show-RouterHelp
    return
}

switch ($Command.ToLower()) {
    "uninstall" {
        & (Join-Path $scriptDir "uninstall.ps1") -Edition $Edition -Scope $Scope
    }
    "repair" {
        & (Join-Path $scriptDir "repair.ps1") -Edition $Edition -VsCodePath $VsCodePath -Scope $Scope
    }
    "sync" {
        # Auto-detect current VS Code path and rewrite drifted \command
        # values. Pass --dry-run via $Rest to preview changes.
        $isDryRun = ($Rest -contains '-DryRun') -or ($Rest -contains '--dry-run')
        $syncArgs = @{ Edition = $Edition; VsCodePath = $VsCodePath; Scope = $Scope }
        if ($isDryRun) { $syncArgs['DryRun'] = $true }
        & (Join-Path $scriptDir "sync.ps1") @syncArgs
    }
    "rollback" {
        # Per spec: rollback is a surgical "remove what we added" -- it does
        # NOT auto-import the pre-install snapshot. We point the user at the
        # snapshot file so they can manually restore prior third-party
        # entries with `reg.exe import` if they want to.
        $sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"
        . (Join-Path $sharedDir "logging.ps1")
        . (Join-Path $scriptDir "helpers\registry-snapshot.ps1")
        $snap = Get-LatestSnapshotPath -ScriptDir $scriptDir
        $hasSnap = -not [string]::IsNullOrWhiteSpace($snap)
        if ($hasSnap) {
            Write-Host ""
            Write-Host "  Pre-install snapshot available: $snap" -ForegroundColor Cyan
            Write-Host "  To restore the EXACT pre-install registry state (incl. any third-party entries):" -ForegroundColor Gray
            Write-Host "      reg.exe import `"$snap`"" -ForegroundColor DarkGray
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "  No pre-install snapshot found under .audit\snapshots\." -ForegroundColor Yellow
            Write-Host "  Proceeding with surgical removal of keys we created." -ForegroundColor Gray
            Write-Host ""
        }
        & (Join-Path $scriptDir "uninstall.ps1") -Edition $Edition -Scope $Scope
    }
    "check" {
        # Quick read-only registry verification for folder + background +
        # file context-menu entries. Independent of the heavier 'verify'
        # test harness -- safe to run without admin (read-only HKCR).
        $sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"
        . (Join-Path $sharedDir "logging.ps1")
        . (Join-Path $scriptDir "helpers\vscode-check.ps1")
        . (Join-Path $scriptDir "helpers\vscode-repair-check.ps1")

        $configPath = Join-Path $scriptDir "config.json"
        $isConfigMissing = -not (Test-Path -LiteralPath $configPath)
        if ($isConfigMissing) {
            Write-Host "FATAL: config.json not found at: $configPath (failure: cannot run check without config)" -ForegroundColor Red
            exit 2
        }
        $logPath = Join-Path $scriptDir "log-messages.json"
        $config  = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $logMsgs = Get-Content -LiteralPath $logPath    -Raw | ConvertFrom-Json

        Write-Log $logMsgs.messages.checkStart -Level "info"
        $result = Invoke-VsCodeMenuCheck -Config $config -LogMsgs $logMsgs -EditionFilter $Edition

        # Repair invariants: file ABSENT, no suppression values, no legacy
        # duplicates. Driven by config.repair.enforceInvariants (default true).
        # Misses are added to the rollup so `check` exits 1 when the menu
        # state diverges from what `repair` is supposed to guarantee.
        $repairResult = Invoke-VsCodeRepairInvariantCheck -Config $config -EditionFilter $Edition

        $totalMiss = $result.totalMiss + $repairResult.totalMiss
        $totalPass = $result.totalPass + $repairResult.totalPass
        Write-Log "" -Level "info"
        Write-Log ("Combined check totals: PASS=" + $totalPass + ", MISS=" + $totalMiss) -Level $(if ($totalMiss -eq 0) { 'success' } else { 'error' })
        $hasMisses = $totalMiss -gt 0
        # CI-friendly granular exit codes (opt-in via -ExitCodeMap in $Rest).
        # Default contract is preserved: 0 = green, 1 = any miss.
        $useExitCodeMap = ($Rest -contains '-ExitCodeMap') -or ($Rest -contains '--exit-code-map')
        if (-not $hasMisses) { exit 0 }
        if (-not $useExitCodeMap) { exit 1 }

        # Map: 10 = install-state, 20 = file-target present, 21 = suppression,
        #      22 = legacy, 30 = multi-invariant, 40 = mixed.
        $hasInstall = $result.totalMiss -gt 0
        $invariantBuckets = @()
        foreach ($ed in $repairResult.editions) {
            foreach ($d in $ed.details) {
                if ($d.ok) { continue }
                switch ($d.invariant) {
                    'file-absent'    { $invariantBuckets += 20 }
                    'no-suppression' { $invariantBuckets += 21 }
                    'no-legacy'      { $invariantBuckets += 22 }
                }
            }
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
    "verify" {
        $harness = Join-Path $scriptDir "tests\run-tests.ps1"
        $isHarnessMissing = -not (Test-Path -LiteralPath $harness)
        if ($isHarnessMissing) {
            Write-Host "FATAL: test harness not found -- expected at: $harness" -ForegroundColor Red
            exit 2
        }
        $passthrough = @()
        if (-not [string]::IsNullOrWhiteSpace($Edition)) { $passthrough += @('-Edition', $Edition) }
        if ($Rest.Count -gt 0) { $passthrough += $Rest }
        & $harness @passthrough
        exit $LASTEXITCODE
    }
    default {
        & (Join-Path $scriptDir "install.ps1") -Edition $Edition -VsCodePath $VsCodePath -Scope $Scope
    }
}
