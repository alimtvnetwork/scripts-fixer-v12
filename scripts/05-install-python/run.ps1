# --------------------------------------------------------------------------
#  Script 05 -- Install Python
#  Installs Python from the official python.org installer and configures pip user site.
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
. (Join-Path $scriptDir "helpers\python.ps1")

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
    -Tool   "Python" `
    -Source "https://www.python.org/downloads/ (official installer)" `
    -Temp   ($env:TEMP + "\scripts-fixer\python") `
    -Target ($env:LocalAppData + "\Programs\Python")

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

# -- Resolve dev directory -----------------------------------------------------
$hasPathParam = -not [string]::IsNullOrWhiteSpace($Path)
if ($hasPathParam) {
    $devDir = $Path
    Write-Log ($logMessages.messages.devDirFromParam -replace '\{path\}', $devDir) -Level "info"
} elseif ($env:DEV_DIR) {
    $devDir = $env:DEV_DIR
} else {
    # Smart drive detection: pick drive with most free space
    $devDir = Resolve-SmartDevDir
    Write-Log "Resolved dev directory via smart detection: $devDir" -Level "info"
}

# -- Execute subcommand --------------------------------------------------------
switch ($Command.ToLower()) {
    "all" {
        Install-Python -Config $config -LogMessages $logMessages -DevDir $devDir
        $sitePath = Configure-PipSite -Config $config -LogMessages $logMessages -DevDir $devDir
        Update-PythonPath -Config $config -LogMessages $logMessages -SitePath $sitePath -DevDir $devDir
    }
    "install" {
        Install-Python -Config $config -LogMessages $logMessages -DevDir $devDir
    }
    "configure" {
        $sitePath = Configure-PipSite -Config $config -LogMessages $logMessages -DevDir $devDir
        Update-PythonPath -Config $config -LogMessages $logMessages -SitePath $sitePath -DevDir $devDir
    }
    "uninstall" {
        Uninstall-Python -Config $config -LogMessages $logMessages -DevDir $devDir
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"

# Refresh PATH so python/pip are discoverable after install/upgrade
Refresh-EnvPath

$pythonInfo = Resolve-PythonExe -ReturnInfo
$hasPythonInfo = $null -ne $pythonInfo -and $pythonInfo.IsValid

$pythonVersion = if ($hasPythonInfo) { $pythonInfo.Version } else { "unknown" }
$pipVersion    = if ($hasPythonInfo -and $pythonInfo.HasPip) { $pythonInfo.PipVersion } else { "unknown" }
$pythonExePath = if ($hasPythonInfo) { $pythonInfo.Path } else { $env:PYTHON_EXE }
$pythonUserBase = if (-not [string]::IsNullOrWhiteSpace($env:PYTHONUSERBASE)) {
    $env:PYTHONUSERBASE
} else {
    [System.Environment]::GetEnvironmentVariable("PYTHONUSERBASE", "User")
}

Save-ResolvedData -ScriptFolder "05-install-python" -Data @{
    pythonVersion  = if ($pythonVersion) { $pythonVersion } else { "unknown" }
    pipVersion     = if ($pipVersion) { $pipVersion } else { "unknown" }
    pythonExe      = $pythonExePath
    pythonUserBase = $pythonUserBase
    timestamp      = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.pythonSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}