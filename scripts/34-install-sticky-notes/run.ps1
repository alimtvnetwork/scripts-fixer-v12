# --------------------------------------------------------------------------
#  Script 34 -- Install Simple Sticky Notes
#  Lightweight desktop sticky notes for Windows
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
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\sticky-notes.ps1")

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
    -Tool   "Microsoft Sticky Notes" `
    -Action "Install" `
    -Source "https://www.microsoft.com/store/productId/9NBLGGH4QGHW" `
    -Temp   ($env:TEMP + "\scripts-fixer\sticky-notes") `
    -Target ("WindowsApps\Microsoft.MicrosoftStickyNotes_*")

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

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-StickyNotes -StickyConfig $config.stickyNotes -LogMessages $logMessages
    return
}

# -- Install -------------------------------------------------------------------
$ok = Install-StickyNotes -StickyConfig $config.stickyNotes -LogMessages $logMessages

$isSuccess = $ok -eq $true
if ($isSuccess) {
    # -- Custom data folder ----------------------------------------------------
    $hasDataFolderConfig = $null -ne $config.stickyNotes.dataFolder
    if ($hasDataFolderConfig) {
        $dataOk = Set-StickyNotesDataFolder -DataFolderConfig $config.stickyNotes.dataFolder -LogMessages $logMessages
        $isDataFail = -not $dataOk
        if ($isDataFail) {
            $isSuccess = $false
        }
    }
}

if ($isSuccess) {
    Write-Log $logMessages.messages.setupComplete -Level "success"
} else {
    Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
}

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
