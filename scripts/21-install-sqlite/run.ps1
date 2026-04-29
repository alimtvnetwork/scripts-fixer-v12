# --------------------------------------------------------------------------
#  Script 21 -- Install SQLite
#  File-based embedded SQL database
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
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "symlink-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\sqlite.ps1")

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
    -Tool   "SQLite" `
    -Source "https://chocolatey.org/install (pkg: sqlite)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\ProgramData\chocolatey\lib\SQLite\tools"
# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {


# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Assert admin --------------------------------------------------------------
$hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isNotAdmin = -not $hasAdminRights
if ($isNotAdmin) {
    Write-Log $logMessages.messages.notAdmin -Level "error"
    return
}

# -- Resolve dev directory -----------------------------------------------------
$hasPathParam = -not [string]::IsNullOrWhiteSpace($Path)
if ($hasPathParam) {
    $devDir = $Path
    Write-Log "Using user-specified dev directory: $devDir" -Level "info"
} else {
    $devDir = Resolve-DevDir -Config $config.devDir
}
Initialize-DevDir -Path $devDir
$env:DEV_DIR = $devDir

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-Sqlite -DbConfig $config.database -LogMessages $logMessages
    return
}

# -- Install -------------------------------------------------------------------
$ok = Install-Sqlite -DbConfig $config.database -LogMessages $logMessages 

# -- Create symlink to dev directory ------------------------------------------
if ($ok) {
    New-DbSymlink -Name ($config.database.chocoPackage) -VerifyCommand ($config.database.verifyCommand) -DevDir $devDir
}

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