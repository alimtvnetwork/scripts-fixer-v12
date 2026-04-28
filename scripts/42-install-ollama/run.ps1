# --------------------------------------------------------------------------
#  Script 42 -- Install Ollama
#  Downloads Ollama from ollama.com, configures models directory and PATH.
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
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "download-retry.ps1")
. (Join-Path $sharedDir "disk-space.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\ollama.ps1")

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
    -Tool   "Ollama" `
    -Source "https://ollama.com/download/OllamaSetup.exe" `
    -Temp   ($env:TEMP + "\scripts-fixer\ollama") `
    -Target ($env:LOCALAPPDATA + "\Programs\Ollama")

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
    Write-Log "Using user-specified dev directory: $devDir" -Level "info"
} elseif ($env:DEV_DIR) {
    $devDir = $env:DEV_DIR
} else {
    $devDir = Resolve-DevDir
}

# -- Execute subcommand --------------------------------------------------------
switch ($Command.ToLower()) {
    "all" {
        # Pre-check disk space for installer + models (~12 GB)
        $downloadDir = if ($devDir) { Join-Path $devDir $config.devDirSubfolder } else { $env:TEMP }
        $isDiskOk = Test-DiskSpace -TargetPath $downloadDir -RequiredGB 12 -Label "Ollama (installer + models)" -WarnOnly
        Install-Ollama -Config $config -LogMessages $logMessages -DevDir $devDir
        Configure-OllamaModels -Config $config -LogMessages $logMessages -DevDir $devDir
        Pull-OllamaModels -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-Ollama -Config $config -LogMessages $logMessages -DevDir $devDir
    }
    "models" {
        Configure-OllamaModels -Config $config -LogMessages $logMessages -DevDir $devDir
    }
    "pull" {
        Pull-OllamaModels -Config $config -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-Ollama -Config $config -LogMessages $logMessages -DevDir $devDir
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$ollamaVersion = try { & ollama --version 2>$null } catch { $null }
$modelsDir = [System.Environment]::GetEnvironmentVariable("OLLAMA_MODELS", "User")

Save-ResolvedData -ScriptFolder "42-install-ollama" -Data @{
    ollamaVersion = $ollamaVersion
    modelsDir     = $modelsDir
    timestamp     = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.ollamaSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}