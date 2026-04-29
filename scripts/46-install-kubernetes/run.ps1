# --------------------------------------------------------------------------
#  Script 46 -- Install Kubernetes Tools
#  Installs kubectl, minikube, and Helm via Chocolatey.
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
. (Join-Path $scriptDir "helpers\kubernetes.ps1")

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
    -Tool   "Kubernetes CLI (kubectl)" `
    -Source "https://chocolatey.org/install (pkg: kubernetes-cli)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\ProgramData\chocolatey\lib\kubernetes-cli\tools"
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
        Install-Kubectl -Config $config -LogMessages $logMessages
        Install-Minikube -Config $config -LogMessages $logMessages
        Install-Helm -Config $config -LogMessages $logMessages
        Install-Lens -Config $config -LogMessages $logMessages
        Update-KubePath -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-Kubectl -Config $config -LogMessages $logMessages
        Install-Minikube -Config $config -LogMessages $logMessages
        Install-Helm -Config $config -LogMessages $logMessages
        Install-Lens -Config $config -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-KubeTools -Config $config -LogMessages $logMessages
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$kubectlVersion  = try { & kubectl version --client --short 2>$null } catch { $null }
$minikubeVersion = try { & minikube version --short 2>$null } catch { $null }
$helmVersion     = try { & helm version --short 2>$null } catch { $null }

Save-ResolvedData -ScriptFolder "46-install-kubernetes" -Data @{
    kubectlVersion  = $kubectlVersion
    minikubeVersion = $minikubeVersion
    helmVersion     = $helmVersion
    timestamp       = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.kubeSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
