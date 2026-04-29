# --------------------------------------------------------------------------
#  Script 03 -- Install Node.js
#  Installs Node.js (LTS) via Chocolatey, configures npm, installs extras.
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
. (Join-Path $scriptDir "helpers\nodejs.ps1")

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
    -Tool   "Node.js (LTS)" `
    -Source "https://chocolatey.org/install (pkg: nodejs-lts)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\nodejs"

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
    Write-Log "Using user-specified dev directory: $devDir" -Level "info"
} elseif ($env:DEV_DIR) {
    $devDir = $env:DEV_DIR
} else {
    $devDir = $null
}

# -- Execute subcommand --------------------------------------------------------
switch ($Command.ToLower()) {
    "all" {
        Install-NodeJs -Config $config -LogMessages $logMessages
        $prefixPath = Configure-NpmPrefix -Config $config -LogMessages $logMessages -DevDir $devDir
        Update-NodePath -Config $config -LogMessages $logMessages -PrefixPath $prefixPath
        Install-NodeExtras -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-NodeJs -Config $config -LogMessages $logMessages
    }
    "configure" {
        $prefixPath = Configure-NpmPrefix -Config $config -LogMessages $logMessages -DevDir $devDir
        Update-NodePath -Config $config -LogMessages $logMessages -PrefixPath $prefixPath
    }
    "uninstall" {
        Uninstall-NodeJs -Config $config -LogMessages $logMessages -DevDir $devDir
        return
    }
    "extras" {
        Install-NodeExtras -Config $config -LogMessages $logMessages
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$nodeVersion = & node --version 2>$null
$npmVersion  = & npm --version 2>$null
$npmPrefix   = & npm config get prefix 2>$null
$yarnVersion = if (Get-Command yarn -ErrorAction SilentlyContinue) { & yarn --version 2>$null } else { $null }
$bunVersion  = if (Get-Command bun -ErrorAction SilentlyContinue) { & bun --version 2>$null } else { $null }

Save-ResolvedData -ScriptFolder "03-install-nodejs" -Data @{
    nodeVersion = $nodeVersion
    npmVersion  = $npmVersion
    npmPrefix   = $npmPrefix
    yarnVersion = $yarnVersion
    bunVersion  = $bunVersion
    timestamp   = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.nodeSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}