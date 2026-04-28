# --------------------------------------------------------------------------
#  Script 35 -- Install GitMap
#  Git repository navigator CLI tool
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [string]$Version,

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
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "path-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\gitmap.ps1")

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
    -Tool   "GitMap" `
    -Action "Install" `
    -Source "https://raw.githubusercontent.com/alimtvnetwork/gitmap-v8/main/install-quick.ps1 (irm | iex)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target ("C:\Program Files\GitExtensions")

# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-Gitmap -GitmapConfig $config.gitmap -DevDirConfig $config.devDir -LogMessages $logMessages
    return
}

# -- Install -------------------------------------------------------------------
# -- Version flag override -- if user passed -Version, override fallbackTag
$hasVersionFlag = -not [string]::IsNullOrWhiteSpace($Version)
if ($hasVersionFlag) {
    Write-Log "Version pinned via --Version flag: $Version" -Level "info"
    $config.gitmap.fallbackTag = $Version
}

$ok = Install-Gitmap -GitmapConfig $config.gitmap -DevDirConfig $config.devDir -LogMessages $logMessages

$isSuccess = $ok -eq $true
if ($isSuccess) {
    Write-Log $logMessages.messages.setupComplete -Level "success"
} else {
    Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
}

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
