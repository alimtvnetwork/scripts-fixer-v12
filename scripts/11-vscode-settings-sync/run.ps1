# --------------------------------------------------------------------------
#  Script 11 -- VS Code Settings Sync
#  Imports settings, keybindings, and extensions for VS Code.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Merge,
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
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\sync.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "VS Code settings" `
    -Action "Sync" `
    -Source "$scriptDir\settings.json (repo-tracked)" `
    -Temp   ($env:TEMP + "\scripts-fixer\vscode-sync") `
    -Target ($env:APPDATA + "\Code\User")

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

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-VsCodeSync -Config $config -LogMessages $logMessages
    return
}

# -- Export check --------------------------------------------------------------
$isExport = $Command.ToLower() -eq "export"
if ($isExport) {
    Export-VsCodeSettings -Config $config -LogMessages $logMessages -ScriptDir $scriptDir
    return
}

# -- Resolve source files ------------------------------------------------------
$sources = Resolve-SourceFiles -ScriptDir $scriptDir -LogMessages $logMessages

$hasNoSettings = -not $sources.Settings
if ($hasNoSettings) {
    Write-Log $logMessages.messages.noSettingsSource -Level "error"
    return
}

$enabledEditions = $config.enabledEditions

# Override editions from orchestrator env var if available
$hasEditionsEnv = -not [string]::IsNullOrWhiteSpace($env:VSCODE_EDITIONS)
if ($hasEditionsEnv) {
    $enabledEditions = @($env:VSCODE_EDITIONS -split ',')
    Write-Log "Using VS Code editions from questionnaire: $($enabledEditions -join ', ')" -Level "info"
}

# Override merge mode from orchestrator env var
$hasSyncModeEnv = -not [string]::IsNullOrWhiteSpace($env:VSCODE_SYNC_MODE)
if ($hasSyncModeEnv) {
    $isSyncSkip = $env:VSCODE_SYNC_MODE -eq "skip"
    if ($isSyncSkip) {
        Write-Log "VS Code settings sync skipped (questionnaire choice)" -Level "skip"

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
        return
    }
    $isMergeMode = $env:VSCODE_SYNC_MODE -eq "merge"
    if ($isMergeMode) { $Merge = [switch]::new($true) }
    Write-Log "Sync mode from questionnaire: $($env:VSCODE_SYNC_MODE)" -Level "info"
}

$isAllSuccessful = $true

Write-Log ($logMessages.messages.enabledEditions -replace '\{editions\}', ($enabledEditions -join ', ')) -Level "info"
Write-Log ($logMessages.messages.extensionCount -replace '\{count\}', $sources.Extensions.Count) -Level "info"
if ($Merge) {
    Write-Log $logMessages.messages.mergeEnabled -Level "info"
} else {
    Write-Log $logMessages.messages.replaceMode -Level "info"
}

# -- Process each edition ------------------------------------------------------
foreach ($editionName in $enabledEditions) {
    $edition = $config.editions.$editionName

    $isEditionMissing = -not $edition
    if ($isEditionMissing) {
        Write-Log ($logMessages.messages.unknownEdition -replace '\{name\}', $editionName) -Level "warn"
        $isAllSuccessful = $false
        continue
    }

    $result = Invoke-Edition `
        -Edition      $edition `
        -EditionName  $editionName `
        -Sources      $sources `
        -BackupSuffix $config.backupSuffix `
        -MergeMode    $Merge.IsPresent `
        -ScriptDir    $scriptDir `
        -LogMessages  $logMessages

    $hasFailed = -not $result
    if ($hasFailed) { $isAllSuccessful = $false }
}

# -- Summary -------------------------------------------------------------------
if ($isAllSuccessful) {
    Write-Log $logMessages.messages.done -Level "success"
} else {
    Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
}

# -- Save resolved state -------------------------------------------------------
Save-ResolvedData -ScriptFolder "11-vscode-settings-sync" -Data @{
    editions   = ($enabledEditions -join ',')
    mergeMode  = $Merge.IsPresent
    extensions = $sources.Extensions.Count
    timestamp  = (Get-Date -Format "o")
}

# -- Save log ------------------------------------------------------------------
Save-LogFile -Status $(if ($isAllSuccessful) { "ok" } else { "fail" })
