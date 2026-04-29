# --------------------------------------------------------------------------
#  Script 33 -- Install Notepad++
#  Supports 3 modes via -Mode parameter:
#    install+settings  (default) -- NPP + Settings
#    settings-only               -- NPP Settings
#    install-only                -- Install NPP
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

# -- Resolve mode: param > env var > default -----------------------------------
if ([string]::IsNullOrWhiteSpace($Mode)) {
    $envMode = $env:NPP_MODE
    $hasEnvMode = -not [string]::IsNullOrWhiteSpace($envMode)
    if ($hasEnvMode) {
        $Mode = $envMode
    } else {
        $Mode = "install+settings"
    }
}

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
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\notepadpp.ps1")

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
    -Tool   "Notepad++" `
    -Source "https://chocolatey.org/install (pkg: notepadplusplus)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\Notepad++"
# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-NotepadPP -NppConfig $config.notepadpp -LogMessages $logMessages
    return
}

# -- Export check --------------------------------------------------------------
$isExport = $Command.ToLower() -eq "export"
if ($isExport) {
    Export-NotepadPPSettings -LogMessages $logMessages
    return
}

# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Install -------------------------------------------------------------------
$ok = Install-NotepadPP -NppConfig $config.notepadpp -LogMessages $logMessages -Mode $Mode

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
