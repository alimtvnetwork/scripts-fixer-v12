# --------------------------------------------------------------------------
#  Script 54 -- repair.ps1 (folder-only repair entry point)
#
#  Ensures the VS Code right-click context menu shows on folders + folder
#  background, NOT on files. Cleans up legacy duplicate VSCode-ish keys
#  and strips suppression values that hide the entry.
#
#  Reuses the same audit log + pre-install snapshot infrastructure as
#  install.ps1 so every change is forensically traceable.
# --------------------------------------------------------------------------
param(
    [string]$Edition,
    [string]$VsCodePath,
    [ValidateSet('Auto','CurrentUser','AllUsers')]
    [string]$Scope = 'Auto',
    [ValidateSet('Quiet','Normal','Debug')]
    [string]$Verbosity = 'Normal',
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "help.ps1")

. (Join-Path $scriptDir "helpers\vscode-install.ps1")
. (Join-Path $scriptDir "helpers\vscode-uninstall.ps1")
. (Join-Path $scriptDir "helpers\vscode-repair.ps1")
. (Join-Path $scriptDir "helpers\audit-log.ps1")
. (Join-Path $scriptDir "helpers\registry-snapshot.ps1")
. (Join-Path $scriptDir "helpers\verbosity.ps1")

$configPath = Join-Path $scriptDir "config.json"
$isConfigMissing = -not (Test-Path -LiteralPath $configPath)
if ($isConfigMissing) {
    Write-Host "FATAL: config.json not found at $configPath (failure: cannot repair without config)" -ForegroundColor Red
    exit 1
}
$config      = Import-JsonConfig $configPath
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help) { Show-ScriptHelp -LogMessages $logMessages; return }

Write-Banner -Title ($logMessages.scriptName + " -- repair")
Initialize-Logging -ScriptName ($logMessages.scriptName + " -- repair")

try {
    # -- Verbosity (controls verification + audit-report loudness) -----------
    Set-VerbosityLevel -Level $Verbosity

    # -- Resolve scope + admin gate (repair mirrors install/uninstall) -------
    Write-Log $logMessages.messages.checkingAdmin -Level "info"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ($logMessages.messages.currentUser    -replace '\{name\}',  $identity.Name) -Level "info"
    Write-Log ($logMessages.messages.isAdministrator -replace '\{value\}', $isAdmin)       -Level $(if ($isAdmin) { "success" } else { "warn" })

    $resolvedScope = Resolve-MenuScope -Requested $Scope -IsAdmin $isAdmin
    Write-Log ("Resolved scope: requested='" + $Scope + "', resolved='" + $resolvedScope + "'") -Level "info"

    $mayProceed = Write-ScopeAdminGuidance -Action 'repair' -RequestedScope $Scope `
        -ResolvedScope $resolvedScope -IsAdmin $isAdmin
    if (-not $mayProceed) { return }

    # -- Audit log + pre-repair snapshot -------------------------------------
    # Repair resolves scope BEFORE opening the audit, so we can stamp it
    # into the session-start header directly.
    $auditPath = Initialize-RegistryAudit -Action "install" -ScriptDir $scriptDir -Scope $resolvedScope
    $snapshotPath = New-PreInstallSnapshot -Config $config -ScriptDir $scriptDir
    $hasSnapshot = -not [string]::IsNullOrWhiteSpace($snapshotPath)
    if ($hasSnapshot) {
        Write-Log ($logMessages.messages.snapshotWritten -replace '\{path\}', $snapshotPath) -Level "info"
    } else {
        Write-Log $logMessages.messages.snapshotSkipped -Level "warn"
    }

    Write-Log $logMessages.messages.repairStart -Level "info"

    $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
    $stats = Invoke-VsCodeMenuRepair -Config $config -LogMsgs $logMessages `
        -RepoRoot $repoRoot -EditionFilter $Edition -VsCodePathOverride $VsCodePath -Scope $resolvedScope

    if ($auditPath) {
        Write-Log ($logMessages.messages.auditWritten -replace '\{path\}', $auditPath) -Level "info"
    }
} catch {
    Write-Log "Unhandled error in repair: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasErrors) { "fail" } else { "ok" })
}
