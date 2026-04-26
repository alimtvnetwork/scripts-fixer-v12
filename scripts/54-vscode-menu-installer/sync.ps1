# --------------------------------------------------------------------------
#  Script 54 -- sync.ps1  (auto-detect + heal context-menu commands)
#
#  For every enabled edition:
#    1. Auto-detect the current VS Code exe path on disk.
#    2. Read the exe path currently baked into each registered \command.
#    3. If they differ (or the registered path no longer exists on disk),
#       rewrite the three target keys with the freshly resolved exe path.
#    4. Print a clear drift report and post-op verification.
#
#  Pure write-on-drift: keys that are already correct are left untouched.
#  Honors -Scope just like install/uninstall (Auto / CurrentUser / AllUsers).
# --------------------------------------------------------------------------
param(
    [string]$Edition,
    [string]$VsCodePath,
    [ValidateSet('Auto','CurrentUser','AllUsers')]
    [string]$Scope = 'Auto',
    [switch]$DryRun,
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
. (Join-Path $scriptDir "helpers\audit-log.ps1")
. (Join-Path $scriptDir "helpers\vscode-check.ps1")

$configPath = Join-Path $scriptDir "config.json"
$isConfigMissing = -not (Test-Path -LiteralPath $configPath)
if ($isConfigMissing) {
    Write-Host "FATAL: config.json not found at $configPath" -ForegroundColor Red
    exit 1
}
$config      = Import-JsonConfig $configPath
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help) { Show-ScriptHelp -LogMessages $logMessages; return }

Write-Banner -Title ($logMessages.scriptName + " -- sync")
Initialize-Logging -ScriptName ($logMessages.scriptName + " -- sync")

try {
    $isDisabled = -not $config.enabled
    if ($isDisabled) { Write-Log $logMessages.messages.scriptDisabled -Level "warn"; return }

    # Audit log: every rewrite is recorded as add/fail in the same JSONL
    # format install.ps1 uses, so the registry change report works for
    # sync runs too.
    $auditPath = Initialize-RegistryAudit -Action "install" -ScriptDir $scriptDir

    # Scope + admin gate (same rules as install).
    Write-Log $logMessages.messages.checkingAdmin -Level "info"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ($logMessages.messages.currentUser -replace '\{name\}', $identity.Name) -Level "info"
    Write-Log ($logMessages.messages.isAdministrator -replace '\{value\}', $isAdmin) -Level $(if ($isAdmin) { "success" } else { "warn" })

    $resolvedScope = Resolve-MenuScope -Requested $Scope -IsAdmin $isAdmin
    Write-Log ("Resolved scope: requested='" + $Scope + "', resolved='" + $resolvedScope + "'") -Level "info"

    # Audit log was opened before scope resolution -- back-fill the scope
    # so every event and the change report show the correct hive.
    Set-RegistryAuditScope -Scope $resolvedScope

    $mayProceed = Write-ScopeAdminGuidance -Action 'sync' -RequestedScope $Scope `
        -ResolvedScope $resolvedScope -IsAdmin $isAdmin
    if (-not $mayProceed) { return }

    Write-Log ("Sync mode: " + $(if ($DryRun) { 'DRY-RUN (no writes)' } else { 'apply changes when drift detected' })) -Level $(if ($DryRun) { 'warn' } else { 'info' })

    $editions = if ([string]::IsNullOrWhiteSpace($Edition)) { @($config.enabledEditions) } else { @($Edition) }

    $rewritten     = 0
    $inSync        = 0
    $orphaned      = 0
    $failed        = 0
    $scopedEditions = @{}
    $driftReport    = @()

    foreach ($editionName in $editions) {
        $editionCfg = $config.editions.$editionName
        if ($null -eq $editionCfg) {
            Write-Log ($logMessages.messages.editionUnknown -replace '\{name\}', $editionName) -Level "warn"
            continue
        }
        $editionCfg = Convert-EditionPathsForScope -EditionConfig $editionCfg -Scope $resolvedScope
        $scopedEditions[$editionName] = $editionCfg

        Write-Log (($logMessages.messages.editionStart -replace '\{name\}', $editionName) -replace '\{label\}', $editionCfg.label) -Level "info"

        # 1) Detect the current exe (override > config > auto-discovery)
        $currentExe = Resolve-VsCodeExecutable `
            -EditionName $editionName `
            -ConfigPath  $editionCfg.vsCodePath `
            -Override    $VsCodePath `
            -LogMsgs     $logMessages

        if (-not $currentExe) {
            # No VS Code on disk at all -- registered keys are now ORPHANS.
            Write-Log ("Edition '" + $editionName + "': VS Code not found on disk -- registered context-menu entries are orphaned. Run uninstall to remove, or reinstall VS Code.") -Level "error"
            $orphaned++
            continue
        }

        $repoRoot   = Split-Path -Parent (Split-Path -Parent $scriptDir)
        $confirmCfg = $null
        if ($config.PSObject.Properties.Name -contains 'confirmBeforeLaunch') {
            $confirmCfg = $config.confirmBeforeLaunch
        }

        # 2) Per target: read installed exe, compare, rewrite if drifted
        foreach ($target in @('file','directory','background')) {
            $regPath = $editionCfg.registryPaths.$target
            $cmdTpl  = $editionCfg.commandTemplates.$target

            $installedExe = Get-InstalledMenuExePath -RegistryPath $regPath
            $hasInstalled = -not [string]::IsNullOrWhiteSpace($installedExe)

            $isMissingKey      = -not $hasInstalled
            $isInstalledOnDisk = $hasInstalled -and (Test-Path -LiteralPath $installedExe)
            $isDifferentPath   = $hasInstalled -and ($installedExe -ne $currentExe)
            $isDrift           = $isMissingKey -or $isDifferentPath -or (-not $isInstalledOnDisk)

            $reasonBits = @()
            if ($isMissingKey)              { $reasonBits += "no \\command key registered" }
            if ($isDifferentPath)           { $reasonBits += ("path drift: '" + $installedExe + "' -> '" + $currentExe + "'") }
            if ($hasInstalled -and -not $isInstalledOnDisk) { $reasonBits += ("registered exe not on disk: " + $installedExe) }
            $reasonText = ($reasonBits -join "; ")

            $driftReport += [pscustomobject]@{
                edition      = $editionName
                target       = $target
                regPath      = $regPath
                installedExe = $installedExe
                currentExe   = $currentExe
                drift        = $isDrift
                reason       = $reasonText
            }

            if (-not $isDrift) {
                Write-Log ("  [in-sync]  " + $target + " -- " + $regPath) -Level "success"
                $inSync++
                continue
            }

            Write-Log ("  [drift]    " + $target + " -- " + $regPath) -Level "warn"
            Write-Log ("             " + $reasonText) -Level "warn"

            if ($DryRun) {
                Write-Log ("             [dry-run] would rewrite to: " + $currentExe) -Level "info"
                continue
            }

            $ok = Register-VsCodeMenuEntry `
                -TargetName      $target `
                -RegistryPath    $regPath `
                -Label           $editionCfg.label `
                -VsCodeExe       $currentExe `
                -CommandTemplate $cmdTpl `
                -RepoRoot        $repoRoot `
                -ConfirmCfg      $confirmCfg `
                -LogMsgs         $logMessages `
                -EditionName     $editionName
            if ($ok) { $rewritten++ } else { $failed++ }
        }
    }

    # Drift report
    Write-Log "" -Level "info"
    Write-Log "------------------------------------------------------------" -Level "info"
    Write-Log " SYNC DRIFT REPORT" -Level "info"
    Write-Log "------------------------------------------------------------" -Level "info"
    foreach ($d in $driftReport) {
        $tag = if ($d.drift) { 'DRIFT' } else { 'OK   ' }
        $lvl = if ($d.drift) { 'warn'  } else { 'success' }
        Write-Log ("  [{0}] {1,-10} {2}" -f $tag, $d.target, $d.regPath) -Level $lvl
        if ($d.drift -and $d.reason) {
            Write-Log ("         reason: " + $d.reason) -Level "warn"
        }
    }

    $summary = "Sync summary -- rewritten: $rewritten, in-sync: $inSync, orphaned: $orphaned, failed: $failed" + $(if ($DryRun) { ' (DRY-RUN)' } else { '' })
    $sumLevel = if ($failed -eq 0 -and $orphaned -eq 0) { 'success' } else { 'error' }
    Write-Log $summary -Level $sumLevel

    $hasAuditPath = -not [string]::IsNullOrWhiteSpace($auditPath)
    if ($hasAuditPath -and -not $DryRun) {
        Write-Log ($logMessages.messages.auditWritten -replace '\{path\}', $auditPath) -Level "info"
    }

    # Post-sync verification: confirm every (rewritten or already-good) key
    # is present and the audit change-report block.
    $hasScopedEditions = $scopedEditions.Count -gt 0
    if ($hasScopedEditions -and -not $DryRun) {
        $auditSummary = Get-RegistryAuditSummary
        Write-RegistryAuditReport -Summary $auditSummary -Action 'install'

        $verifyResult = Invoke-PostOpVerification `
            -Action         'install' `
            -Config         $config `
            -ResolvedScope  $resolvedScope `
            -LogMsgs        $logMessages `
            -ScopedEditions $scopedEditions

        if ($verifyResult.fail -gt 0) {
            Write-Log ("Post-sync verification reported " + $verifyResult.fail + " failing key(s) -- review the table above.") -Level "error"
        }
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasErrors) { "fail" } else { "ok" })
}