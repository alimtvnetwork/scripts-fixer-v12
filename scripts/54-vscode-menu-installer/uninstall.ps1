# --------------------------------------------------------------------------
#  Script 54 -- uninstall.ps1 (standalone surgical uninstaller)
#
#  Removes ONLY the registry keys listed in config.json::editions.<name>.
#  registryPaths. Never enumerates, never reads sibling keys, never deletes
#  anything that is not on the allow-list. Safe to run repeatedly.
# --------------------------------------------------------------------------
param(
    [string]$Edition,
    [ValidateSet('Auto','CurrentUser','AllUsers')]
    [string]$Scope = 'Auto',
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")

. (Join-Path $scriptDir "helpers\vscode-uninstall.ps1")
. (Join-Path $scriptDir "helpers\audit-log.ps1")
# Pull in scope helpers (Resolve-MenuScope, Convert-EditionPathsForScope).
. (Join-Path $scriptDir "helpers\vscode-install.ps1")

$configPath = Join-Path $scriptDir "config.json"
$isConfigMissing = -not (Test-Path -LiteralPath $configPath)
if ($isConfigMissing) {
    Write-Host "FATAL: config.json not found at $configPath" -ForegroundColor Red
    exit 1
}
$config      = Import-JsonConfig $configPath
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help) { Show-ScriptHelp -LogMessages $logMessages; return }

Write-Banner -Title ($logMessages.scriptName + " -- uninstall")
Initialize-Logging -ScriptName ($logMessages.scriptName + " -- uninstall")

try {
    # -- Resolve scope + admin gate ------------------------------------------
    # Uninstall mirrors install's scope rules: AllUsers needs admin,
    # CurrentUser does not. Auto = AllUsers when admin, else CurrentUser.
    Write-Log $logMessages.messages.checkingAdmin -Level "info"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ($logMessages.messages.currentUser -replace '\{name\}', $identity.Name) -Level "info"
    Write-Log ($logMessages.messages.isAdministrator -replace '\{value\}', $isAdmin) -Level $(if ($isAdmin) { "success" } else { "warn" })

    $resolvedScope = Resolve-MenuScope -Requested $Scope -IsAdmin $isAdmin
    Write-Log ("Resolved scope: requested='" + $Scope + "', resolved='" + $resolvedScope + "'") -Level "info"

    $isAllUsersRequested = ($Scope -ieq 'AllUsers' -or $Scope -ieq 'Machine' -or $Scope -ieq 'HKLM')
    if ($isAllUsersRequested -and -not $isAdmin) {
        Write-Log "Scope=AllUsers requires Administrator. Re-run from an elevated PowerShell, or pass -Scope CurrentUser to uninstall the current user's entries only." -Level "error"
        return
    }
    if ($resolvedScope -eq 'AllUsers' -and -not $isAdmin) {
        Write-Log $logMessages.messages.notAdmin -Level "error"; return
    }

    Write-Log $logMessages.messages.uninstallStart -Level "info"

    # -- Open audit log (timestamped, one file per run) ----------------------
    $auditPath = Initialize-RegistryAudit -Action "uninstall" -ScriptDir $scriptDir

    $editions = if ([string]::IsNullOrWhiteSpace($Edition)) {
        @($config.enabledEditions)
    } else {
        @($Edition)
    }

    $removed = 0
    $absent  = 0
    $failed  = 0

    foreach ($editionName in $editions) {
        $editionCfg = $config.editions.$editionName
        $isUnknown = $null -eq $editionCfg
        if ($isUnknown) {
            Write-Log ($logMessages.messages.editionUnknown -replace '\{name\}', $editionName) -Level "warn"
            continue
        }

        # Apply the scope rewrite BEFORE the allow-list is built so the
        # surgical removal targets the right hive.
        $editionCfg = Convert-EditionPathsForScope -EditionConfig $editionCfg -Scope $resolvedScope

        Write-Log ($logMessages.messages.uninstallEdition -replace '\{name\}', $editionName) -Level "info"

        # SURGICAL: only iterate over the explicit allow-list from config.
        $allowList = Get-EditionAllowList -EditionConfig $editionCfg
        foreach ($entry in $allowList) {
            $status = Remove-VsCodeMenuEntry `
                -TargetName   $entry.Target `
                -RegistryPath $entry.Path `
                -LogMsgs      $logMessages `
                -EditionName  $editionName
            switch ($status) {
                'removed' { $removed++ }
                'absent'  { $absent++  }
                'failed'  { $failed++  }
            }
        }
    }

    # Purge tracking only when nothing failed
    if ($failed -eq 0) {
        Remove-InstalledRecord -Name "vscode-menu-installer" -ErrorAction SilentlyContinue
        Remove-ResolvedData    -ScriptFolder "54-vscode-menu-installer" -ErrorAction SilentlyContinue
    }

    $msg = ((($logMessages.messages.summaryUninstall -replace '\{removed\}', $removed) -replace '\{absent\}', $absent) -replace '\{failed\}', $failed)
    Write-Log $msg -Level $(if ($failed -eq 0) { "success" } else { "error" })
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
