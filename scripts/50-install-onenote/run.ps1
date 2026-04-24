# --------------------------------------------------------------------------
#  Script 50 -- Install OneNote (+ remove tray + disable OneDrive)
#  Mechanism: Chocolatey first, fallback to direct download from Microsoft.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")

. (Join-Path $scriptDir "helpers\onenote.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName
Initialize-Logging -ScriptName $logMessages.scriptName

try {

    Invoke-GitPull

    $isUninstall = $Command.ToLower() -eq "uninstall"
    if ($isUninstall) {
        Uninstall-OneNote -OneConfig $config.onenote -LogMessages $logMessages
        return
    }

    # Mode resolution -- decides whether post-install tweaks (tray + OneDrive) run.
    # Order of precedence:
    #   1) Explicit Command arg: install | with-tweaks | rm-onedrive | all
    #   2) Env var ONENOTE_MODE (set by keyword dispatcher for `onenote+rm-onedrive`)
    #   3) Falls back to config defaults (which ship as OFF -> install-only)
    $cmd     = $Command.ToLower()
    $envMode = if ($env:ONENOTE_MODE) { $env:ONENOTE_MODE.ToLower() } else { "" }

    $applyTweaks = $false
    switch ($cmd) {
        "install"     { $applyTweaks = $false }
        "with-tweaks" { $applyTweaks = $true }
        "rm-onedrive" { $applyTweaks = $true }
        "all"         { $applyTweaks = ($envMode -in @("with-tweaks","rm-onedrive","all")) }
        default       { $applyTweaks = ($envMode -in @("with-tweaks","rm-onedrive","all")) }
    }

    # Push resolved decision into config so the helper stays declarative.
    $config.onenote.tweaks.removeTrayIcon  = $applyTweaks
    $config.onenote.tweaks.disableOneDrive = $applyTweaks

    $modeLabel = if ($applyTweaks) { "install + rm-onedrive (tray + OneDrive autostart disabled)" } else { "install-only (no tweaks, OneDrive untouched)" }
    Write-Log "OneNote mode: $modeLabel" -Level "info"

    $ok = Install-OneNote -OneConfig $config.onenote -LogMessages $logMessages

    $isSuccess = $ok -eq $true
    if ($isSuccess) {
        Write-Log $logMessages.messages.setupComplete -Level "success"
    } else {
        Write-Log ($logMessages.messages.installFailed) -Level "error"
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
