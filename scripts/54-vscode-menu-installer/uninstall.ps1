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
. (Join-Path $sharedDir "installed.ps1")

. (Join-Path $scriptDir "helpers\vscode-uninstall.ps1")
. (Join-Path $scriptDir "helpers\audit-log.ps1")
# Pull in scope helpers (Resolve-MenuScope, Convert-EditionPathsForScope).
. (Join-Path $scriptDir "helpers\vscode-install.ps1")
. (Join-Path $scriptDir "helpers\vscode-check.ps1")
. (Join-Path $scriptDir "helpers\verbosity.ps1")

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
    # -- Verbosity (controls verification + audit-report loudness) -----------
    Set-VerbosityLevel -Level $Verbosity

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

    $mayProceed = Write-ScopeAdminGuidance -Action 'uninstall' -RequestedScope $Scope `
        -ResolvedScope $resolvedScope -IsAdmin $isAdmin
    if (-not $mayProceed) { return }

    Write-Log $logMessages.messages.uninstallStart -Level "info"

    # -- Open audit log (timestamped, one file per run) ----------------------
    $auditPath = Initialize-RegistryAudit -Action "uninstall" -ScriptDir $scriptDir -Scope $resolvedScope

    $editions = if ([string]::IsNullOrWhiteSpace($Edition)) {
        @($config.enabledEditions)
    } else {
        @($Edition)
    }

    $removed = 0
    $absent  = 0
    $failed  = 0
    # Per-edition scope-rewritten configs -- needed by the post-op
    # verification so it probes the exact hive we just touched.
    $scopedEditions = @{}

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
        $scopedEditions[$editionName] = $editionCfg

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

    # ------------------------------------------------------------------
    # Dedicated post-uninstall verification step.
    #   1) Print the registry CHANGE report from the run's audit JSONL
    #      so the user sees exactly what was removed / skipped / failed.
    #   2) Re-probe every (scope-rewritten) target key and confirm it
    #      is now ABSENT -- catches any leftover key the surgical
    #      removal missed.
    # ------------------------------------------------------------------
    $hasScopedEditions = $scopedEditions.Count -gt 0
    if ($hasScopedEditions) {
        $auditSummary = Get-RegistryAuditSummary
        Write-RegistryAuditReport -Summary $auditSummary -Action 'uninstall'

        $verifyResult = Invoke-PostOpVerification `
            -Action         'uninstall' `
            -Config         $config `
            -ResolvedScope  $resolvedScope `
            -LogMsgs        $logMessages `
            -ScopedEditions $scopedEditions

        if ($verifyResult.fail -gt 0) {
            Write-Log ("Post-uninstall verification reported " + $verifyResult.fail + " key(s) still present -- review the table above (failure path: see per-row regPath).") -Level "error"
        }
    } else {
        Write-Log "Post-uninstall verification skipped: no editions were processed this run." -Level "warn"
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasErrors) { "fail" } else { "ok" })
}
