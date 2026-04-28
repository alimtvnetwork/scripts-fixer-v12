# --------------------------------------------------------------------------
#  Script 31 -- PowerShell Context Menu
#  Adds "Open PowerShell Here" (normal + admin) to the right-click menu.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

$script:ScriptDir = $scriptDir

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\pwsh-menu.ps1")

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

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "PowerShell 7 right-click menu" `
    -Action "Configure" `
    -Source "$scriptDir\helpers\pwsh-ctx.ps1" `
    -Temp   ($env:TEMP + "\scripts-fixer\pwsh-ctx") `
    -Target ("HKCR:\Directory\Background\shell\PowerShell7")

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

# -- Assert admin --------------------------------------------------------------
$hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isNotAdmin = -not $hasAdminRights
if ($isNotAdmin) {
    Write-Log $logMessages.messages.notAdmin -Level "error"
    return
}

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-PwshContextMenu -Config $config -LogMessages $logMessages
    return
}

# -- Detect PowerShell exe -----------------------------------------------------
$pwshExe = Resolve-PwshPath `
    -PwshPaths       $config.pwshPaths `
    -VerifyCommand   $config.verifyCommand `
    -VersionFlag     $config.versionFlag `
    -FallbackToLegacy $config.fallbackToLegacy `
    -LogMessages     $logMessages

$isPwshMissing = -not $pwshExe
if ($isPwshMissing) {
    return
}

# -- Process modes (normal + admin) --------------------------------------------
$enabledModes    = $config.enabledModes
$isAllSuccessful = $true

foreach ($modeName in $enabledModes) {
    $mode = $config.modes.$modeName

    $isModeMissing = -not $mode
    if ($isModeMissing) {
        Write-Log "Unknown mode '$modeName' in enabledModes -- skipping" -Level "warn"
        $isAllSuccessful = $false
        continue
    }

    $result = Invoke-PwshMode `
        -Mode        $mode `
        -ModeName    $modeName `
        -PwshExe     $pwshExe `
        -LogMessages $logMessages

    $hasFailed = -not $result
    if ($hasFailed) { $isAllSuccessful = $false }
}

# -- Summary -------------------------------------------------------------------
if ($isAllSuccessful) {
    Write-Log $logMessages.messages.done -Level "success"
} else {
    Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
}

# -- Save resolved state -------------------------------------------------------
Save-ResolvedData -ScriptFolder "31-pwsh-context-menu" -Data @{
    pwshExe   = $pwshExe
    modes     = ($enabledModes -join ',')
    timestamp = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.setupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}