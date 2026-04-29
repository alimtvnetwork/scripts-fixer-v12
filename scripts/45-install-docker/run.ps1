# --------------------------------------------------------------------------
#  Script 45 -- Install Docker Desktop
#  Installs Docker Desktop via Chocolatey with WSL2 backend support.
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

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "path-utils.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\docker.ps1")

# -- Load config & log messages -----------------------------------------------
$config       = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages  = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Docker Desktop" `
    -Source "https://chocolatey.org/install (pkg: docker-desktop)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\Docker\Docker"
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

# -- Assert Chocolatey ---------------------------------------------------------
Assert-Choco

# -- Execute subcommand --------------------------------------------------------
switch ($Command.ToLower()) {
    "all" {
        Test-Wsl2 -Config $config -LogMessages $logMessages
        Install-DockerDesktop -Config $config -LogMessages $logMessages
        Test-DockerDaemon -Config $config -LogMessages $logMessages
        Update-DockerPath -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-DockerDesktop -Config $config -LogMessages $logMessages
    }
    "status" {
        Test-DockerDaemon -Config $config -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-Docker -Config $config -LogMessages $logMessages
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$dockerVersion  = try { & docker --version 2>$null } catch { $null }
$composeVersion = try { & docker compose version 2>$null } catch { $null }

Save-ResolvedData -ScriptFolder "45-install-docker" -Data @{
    dockerVersion  = $dockerVersion
    composeVersion = $composeVersion
    timestamp      = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.dockerSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
