# --------------------------------------------------------------------------
#  Script 04 -- Install pnpm
#  Installs pnpm globally via npm and configures the global store.
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
. (Join-Path $sharedDir "path-utils.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\pnpm.ps1")

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
    -Tool   "pnpm" `
    -Source "https://get.pnpm.io/install.ps1" `
    -Temp   ($env:TEMP + "\scripts-fixer\pnpm") `
    -Target ($env:LOCALAPPDATA + "\pnpm")

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

# -- Note: No admin required for pnpm -----------------------------------------

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
        Install-Pnpm -Config $config -LogMessages $logMessages
        $storePath = Configure-PnpmStore -Config $config -LogMessages $logMessages -DevDir $devDir
        Update-PnpmPath -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-Pnpm -Config $config -LogMessages $logMessages
    }
    "configure" {
        $storePath = Configure-PnpmStore -Config $config -LogMessages $logMessages -DevDir $devDir
        Update-PnpmPath -Config $config -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-Pnpm -Config $config -LogMessages $logMessages -DevDir $devDir
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$pnpmVersion = & pnpm --version 2>$null
$storeDir    = & pnpm config get store-dir 2>$null

Save-ResolvedData -ScriptFolder "04-install-pnpm" -Data @{
    pnpmVersion = $pnpmVersion
    storeDir    = $storeDir
    pnpmHome    = $env:PNPM_HOME
    timestamp   = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.pnpmSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}