# --------------------------------------------------------------------------
#  Script 39 -- Install .NET SDK
#  Installs .NET SDK via Chocolatey with version selection.
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
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\dotnet.ps1")

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
    -Tool   ".NET SDK" `
    -Source "https://chocolatey.org/install (pkg: dotnet-sdk)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\dotnet"
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

# -- Resolve dev directory -----------------------------------------------------
$hasPathParam = -not [string]::IsNullOrWhiteSpace($Path)
if ($hasPathParam) {
    $devDir = $Path
    Write-Log ($logMessages.messages.devDirFromParam -replace '\{path\}', $devDir) -Level "info"
} elseif ($env:DEV_DIR) {
    $devDir = $env:DEV_DIR
} else {
    $devDir = $null
}

# -- Log install location ------------------------------------------------------
$installDir = if ($devDir) { Join-Path $devDir $config.devDirSubfolder } else { "(system default)" }
Write-Log ($logMessages.messages.installLocationInfo -replace '\{path\}', $installDir) -Level "info"

# -- Parse version from command ------------------------------------------------
# Support: "all", "all 8", "install", "install 8", "install latest"
$requestedVersion = $null
$actualCommand = $Command.ToLower()

# Check if command itself is a version number
$isVersionNumber = $Command -match '^\d+$'
if ($isVersionNumber) {
    $requestedVersion = $Command
    $actualCommand = "all"
}

# -- Execute subcommand --------------------------------------------------------
switch ($actualCommand) {
    "all" {
        Install-DotnetSdk -Config $config -LogMessages $logMessages -Version $requestedVersion
        Update-DotnetPath -Config $config -LogMessages $logMessages -DevDir $devDir
    }
    "install" {
        # Check if $Path looks like a version number (positional arg confusion)
        $isPathAVersion = $Path -match '^\d+$' -or $Path -eq 'latest'
        if ($isPathAVersion) {
            $requestedVersion = $Path
            $devDir = if ($env:DEV_DIR) { $env:DEV_DIR } else { $null }
        }
        Install-DotnetSdk -Config $config -LogMessages $logMessages -Version $requestedVersion
    }
    "uninstall" {
        Uninstall-DotnetSdk -Config $config -LogMessages $logMessages -DevDir $devDir
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"

# Refresh PATH so dotnet is discoverable
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

$dotnetVersion = try { & dotnet --version 2>$null } catch { $null }
$dotnetInfo    = try { & dotnet --list-sdks 2>$null } catch { $null }

Save-ResolvedData -ScriptFolder "39-install-dotnet" -Data @{
    dotnetVersion = if ($dotnetVersion) { $dotnetVersion } else { "unknown" }
    installedSdks = if ($dotnetInfo) { $dotnetInfo } else { "unknown" }
    timestamp     = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.dotnetSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
