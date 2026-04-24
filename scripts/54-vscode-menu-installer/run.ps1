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
    Write-Host "    install / uninstall  -- require Administrator (write to HKEY_CLASSES_ROOT)" -ForegroundColor Gray
    Write-Host "    check / verify       -- read-only, run as any user (HKCR is world-readable)" -ForegroundColor Gray
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
        & (Join-Path $scriptDir "uninstall.ps1") -Edition $Edition
    }
    "check" {
        # Quick read-only registry verification for folder + background +
        # file context-menu entries. Independent of the heavier 'verify'
        # test harness -- safe to run without admin (read-only HKCR).
        $sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"
        . (Join-Path $sharedDir "logging.ps1")
        . (Join-Path $scriptDir "helpers\vscode-check.ps1")

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
        $hasMisses = $result.totalMiss -gt 0
        if ($hasMisses) { exit 1 } else { exit 0 }
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
        & (Join-Path $scriptDir "install.ps1") -Edition $Edition -VsCodePath $VsCodePath
    }
}
