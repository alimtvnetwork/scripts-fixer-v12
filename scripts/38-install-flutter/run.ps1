# --------------------------------------------------------------------------
#  Script 38 -- Install Flutter
#  Installs Flutter SDK, Android Studio, Chrome, and VS Code extensions.
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
. (Join-Path $scriptDir "helpers\flutter.ps1")

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
    -Tool   "Flutter SDK" `
    -Source "https://chocolatey.org/install (pkg: flutter)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\tools\flutter"
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
        Install-Flutter    -Config $config -LogMessages $logMessages
        Install-AndroidStudio -Config $config -LogMessages $logMessages
        Install-Chrome     -Config $config -LogMessages $logMessages
        Install-FlutterVscodeExtensions -Config $config -LogMessages $logMessages
        Invoke-FlutterDoctor -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-Flutter -Config $config -LogMessages $logMessages
    }
    "android" {
        Install-AndroidStudio -Config $config -LogMessages $logMessages
    }
    "chrome" {
        Install-Chrome -Config $config -LogMessages $logMessages
    }
    "extensions" {
        Install-FlutterVscodeExtensions -Config $config -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-Flutter -Config $config -LogMessages $logMessages
        return
    }
    "doctor" {
        Invoke-FlutterDoctor -Config $config -LogMessages $logMessages
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$flutterVersion = & flutter --version --machine 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
$dartVersion    = & dart --version 2>$null

Save-ResolvedData -ScriptFolder "38-install-flutter" -Data @{
    flutterVersion = if ($flutterVersion) { $flutterVersion.frameworkVersion } else { "unknown" }
    dartVersion    = $dartVersion
    channel        = if ($flutterVersion) { $flutterVersion.channel } else { "unknown" }
    timestamp      = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.flutterSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
