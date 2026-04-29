# --------------------------------------------------------------------------
#  Script 32 -- Install DBeaver Community
#  Universal database visualization and management tool
#  Supports 3 modes: install+settings, settings-only, install-only
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Help,
    [ValidateSet("install+settings", "settings-only", "install-only")]
    [string]$Mode = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\dbeaver.ps1")

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

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "DBeaver Community" `
    -Source "https://chocolatey.org/install (pkg: dbeaver)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\DBeaver"
# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {


# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-Dbeaver -DbConfig $config.database -LogMessages $logMessages
    return
}

# -- Export check --------------------------------------------------------------
$isExport = $Command.ToLower() -eq "export"
if ($isExport) {
    Export-DbeaverSettings -LogMessages $logMessages
    return
}

# -- Resolve mode --------------------------------------------------------------
$isModePassed = $Mode -ne ""
if (-not $isModePassed) {
    $Mode = $config.database.defaultMode
}

# -- Settings-only mode does not require admin ---------------------------------
$isSettingsOnly = $Mode -eq "settings-only"

if (-not $isSettingsOnly) {
    # -- Assert admin ----------------------------------------------------------
    $hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isNotAdmin = -not $hasAdminRights
    if ($isNotAdmin) {
        Write-Log $logMessages.messages.notAdmin -Level "error"
        return
    }
}

# -- Install -------------------------------------------------------------------
$ok = Install-Dbeaver -DbConfig $config.database -LogMessages $logMessages -Mode $Mode

$isSuccess = $ok -eq $true
if ($isSuccess) {
    Write-Log $logMessages.messages.setupComplete -Level "success"
} else {
    Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
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
