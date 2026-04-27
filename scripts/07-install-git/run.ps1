# --------------------------------------------------------------------------
#  Script 07 -- Install Git, Git LFS, and GitHub CLI
#  Installs Git + Git LFS + GitHub CLI via Chocolatey and configures settings.
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
. (Join-Path $sharedDir "tool-version.ps1")
. (Join-Path $sharedDir "ensure-tool.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\git.ps1")

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
        Install-Git -Config $config -LogMessages $logMessages
        Install-GitLfs -Config $config -LogMessages $logMessages
        Install-GitHubCli -Config $config -LogMessages $logMessages
        Configure-GitGlobal -Config $config -LogMessages $logMessages
        Update-GitPath -Config $config -LogMessages $logMessages
    }
    "install" {
        Install-Git -Config $config -LogMessages $logMessages
        Install-GitLfs -Config $config -LogMessages $logMessages
        Install-GitHubCli -Config $config -LogMessages $logMessages
    }
    "configure" {
        Configure-GitGlobal -Config $config -LogMessages $logMessages
        Update-GitPath -Config $config -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-Git -Config $config -LogMessages $logMessages
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"
$gitVersion    = & git --version 2>$null
$lfsVersion    = & git lfs version 2>$null
$userName      = & git config --global user.name 2>$null
$userEmail     = & git config --global user.email 2>$null
$credHelper    = & git config --global credential.helper 2>$null
$autocrlf      = & git config --global core.autocrlf 2>$null
$defaultBranch = & git config --global init.defaultBranch 2>$null
$editor        = & git config --global core.editor 2>$null
$pushAutoSetup = & git config --global push.autoSetupRemote 2>$null
$ghVersion     = & gh --version 2>$null | Select-Object -First 1
$ghUser        = & gh api user --jq '.login' 2>$null

Save-ResolvedData -ScriptFolder "07-install-git" -Data @{
    gitVersion       = $gitVersion
    lfsVersion       = $lfsVersion
    ghVersion        = $ghVersion
    ghUser           = $ghUser
    userName         = $userName
    userEmail        = $userEmail
    credentialHelper = $credHelper
    autocrlf         = $autocrlf
    defaultBranch    = $defaultBranch
    editor           = $editor
    pushAutoSetup    = $pushAutoSetup
    timestamp        = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.gitSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}