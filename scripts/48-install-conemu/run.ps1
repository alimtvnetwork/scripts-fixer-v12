# --------------------------------------------------------------------------
#  Script 48 -- Install ConEmu (+ optional settings sync)
#  Modes via -Mode parameter:
#    install+settings  (default) -- ConEmu + ConEmu.xml
#    settings-only               -- ConEmu.xml only
#    install-only                -- ConEmu only
#  Special command: 'export' -- copy %APPDATA%\ConEmu\ConEmu.xml to repo
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [switch]$Help,
    [ValidateSet("install+settings", "settings-only", "install-only")]
    [string]$Mode = ""
)

# -- Resolve mode: param > env var > default ---------------------------------
if ([string]::IsNullOrWhiteSpace($Mode)) {
    $envMode = $env:CONEMU_MODE
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

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

. (Join-Path $scriptDir "helpers\conemu.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "ConEmu" `
    -Source "https://chocolatey.org/install (pkg: conemu)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\ConEmu"
Initialize-Logging -ScriptName $logMessages.scriptName

try {

    $isUninstall = $Command.ToLower() -eq "uninstall"
    if ($isUninstall) {
        Uninstall-ConEmu -ConEmuConfig $config.conemu -LogMessages $logMessages
        return
    }

    $isExport = $Command.ToLower() -eq "export"
    if ($isExport) {
        Export-ConEmuSettings -ConEmuConfig $config.conemu -LogMessages $logMessages
        return
    }

    Invoke-GitPull

    $ok = Install-ConEmu -ConEmuConfig $config.conemu -LogMessages $logMessages -Mode $Mode

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
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
