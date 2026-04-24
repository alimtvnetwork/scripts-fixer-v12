# --------------------------------------------------------------------------
#  Script 54 -- install.ps1 (standalone installer)
#
#  Writes the classic "Open with Code" registry keys for every enabled
#  edition. Independent of script 10. Path allow-list lives in config.json.
# --------------------------------------------------------------------------
param(
    [string]$Edition,
    [string]$VsCodePath,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Shared helpers (lightweight: only logging + json + admin/help) ----------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "help.ps1")

# -- Script helpers -----------------------------------------------------------
. (Join-Path $scriptDir "helpers\vscode-install.ps1")
. (Join-Path $scriptDir "helpers\audit-log.ps1")

# -- Load config & log messages -----------------------------------------------
$configPath = Join-Path $scriptDir "config.json"
$isConfigMissing = -not (Test-Path -LiteralPath $configPath)
if ($isConfigMissing) {
    Write-Host "FATAL: config.json not found at $configPath" -ForegroundColor Red
    exit 1
}
$config      = Import-JsonConfig $configPath
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help) { Show-ScriptHelp -LogMessages $logMessages; return }

Write-Banner -Title ($logMessages.scriptName + " -- install")
Initialize-Logging -ScriptName ($logMessages.scriptName + " -- install")

try {
    # -- Disabled check -------------------------------------------------------
    $isDisabled = -not $config.enabled
    if ($isDisabled) { Write-Log $logMessages.messages.scriptDisabled -Level "warn"; return }

    # -- Open audit log (timestamped, one file per run) ----------------------
    $auditPath = Initialize-RegistryAudit -Action "install" -ScriptDir $scriptDir

    # -- Assert admin ---------------------------------------------------------
    Write-Log $logMessages.messages.checkingAdmin -Level "info"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ($logMessages.messages.currentUser -replace '\{name\}', $identity.Name) -Level "info"
    Write-Log ($logMessages.messages.isAdministrator -replace '\{value\}', $isAdmin) -Level $(if ($isAdmin) { "success" } else { "error" })
    if (-not $isAdmin) { Write-Log $logMessages.messages.notAdmin -Level "error"; return }

    # -- Decide editions ------------------------------------------------------
    $editions = if ([string]::IsNullOrWhiteSpace($Edition)) {
        @($config.enabledEditions)
    } else {
        @($Edition)
    }

    $processedCount = 0
    $skippedCount   = 0
    $resolvedSummary = @{}

    foreach ($editionName in $editions) {
        $editionCfg = $config.editions.$editionName
        $isUnknown = $null -eq $editionCfg
        if ($isUnknown) {
            Write-Log ($logMessages.messages.editionUnknown -replace '\{name\}', $editionName) -Level "warn"
            $skippedCount++
            continue
        }

        Write-Log (($logMessages.messages.editionStart -replace '\{name\}', $editionName) -replace '\{label\}', $editionCfg.label) -Level "info"

        # Resolve exe
        $vsCodeExe = Resolve-VsCodeExecutable `
            -EditionName $editionName `
            -ConfigPath  $editionCfg.vsCodePath `
            -Override    $VsCodePath `
            -LogMsgs     $logMessages
        $isExeMissing = -not $vsCodeExe
        if ($isExeMissing) { $skippedCount++; continue }

        # Resolve repo root (parent of scripts/) for confirm-launch wrapper
        $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
        $confirmCfg = $null
        if ($config.PSObject.Properties.Name -contains 'confirmBeforeLaunch') {
            $confirmCfg = $config.confirmBeforeLaunch
        }

        # Write each of the three targets
        $isAllOk = $true
        foreach ($target in @('file', 'directory', 'background')) {
            $regPath = $editionCfg.registryPaths.$target
            $cmdTpl  = $editionCfg.commandTemplates.$target
            $ok = Register-VsCodeMenuEntry `
                -TargetName      $target `
                -RegistryPath    $regPath `
                -Label           $editionCfg.label `
                -VsCodeExe       $vsCodeExe `
                -CommandTemplate $cmdTpl `
                -RepoRoot        $repoRoot `
                -ConfirmCfg      $confirmCfg `
                -LogMsgs         $logMessages `
                -EditionName     $editionName
            if (-not $ok) { $isAllOk = $false }
        }

        # Verify
        Write-Log ($logMessages.messages.verify -replace '\{name\}', $editionName) -Level "info"
        foreach ($target in @('file', 'directory', 'background')) {
            $regPath = $editionCfg.registryPaths.$target
            $ok = Test-VsCodeMenuEntry -TargetName $target -RegistryPath $regPath -LogMsgs $logMessages
            if (-not $ok) { $isAllOk = $false }
        }

        $resolvedSummary[$editionName] = @{
            vsCodeExe = $vsCodeExe
            ok        = $isAllOk
            at        = (Get-Date -Format "o")
        }
        $processedCount++
    }

    Save-ResolvedData -ScriptFolder "54-vscode-menu-installer" -Data @{
        action   = "install"
        editions = $resolvedSummary
        timestamp = (Get-Date -Format "o")
    }

    $msg = (($logMessages.messages.summaryInstall -replace '\{processed\}', $processedCount) -replace '\{skipped\}', $skippedCount)
    Write-Log $msg -Level $(if ($skippedCount -eq 0 -and $processedCount -gt 0) { "success" } else { "warn" })
    Write-Log $logMessages.messages.tip -Level "info"
    $hasAuditPath = -not [string]::IsNullOrWhiteSpace($auditPath)
    if ($hasAuditPath) {
        Write-Log ($logMessages.messages.auditWritten -replace '\{path\}', $auditPath) -Level "info"
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasErrors) { "fail" } else { "ok" })
}
