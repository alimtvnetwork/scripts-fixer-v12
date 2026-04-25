<#
.SYNOPSIS
    Thin re-export wrapper. Script 10 reuses the audit log + pre-install
    snapshot helpers shipped by Script 54 (54-vscode-menu-installer)
    so both context-menu installers share one tested implementation.

.DESCRIPTION
    Both modules are pure functions parameterised by $ScriptDir, so they
    transparently write to scripts/10-vscode-context-menu-fix/.audit/
    when called from this script. The snapshot helper uses
    $Config.enabledEditions + $Config.editions.<n>.registryPaths -- the
    same keys Script 10's config already exposes, so no shape-mapping is
    needed.

    Re-exported functions:
      Initialize-RegistryAudit
      Write-RegistryAuditEvent
      Get-RegistryAuditPath
      New-PreInstallSnapshot
      Get-LatestSnapshotPath
#>

Set-StrictMode -Version Latest

$_script10HelperDir = $PSScriptRoot
$_script54HelperDir = Join-Path (Split-Path -Parent (Split-Path -Parent $_script10HelperDir)) "54-vscode-menu-installer\helpers"

foreach ($peer in @("audit-log.ps1","registry-snapshot.ps1")) {
    $peerPath = Join-Path $_script54HelperDir $peer
    $isPeerMissing = -not (Test-Path -LiteralPath $peerPath)
    if ($isPeerMissing) {
        Write-Log "Script 54 helper not found: $peerPath (failure: cannot reuse audit/snapshot module from Script 10)" -Level "warn"
        continue
    }
    . $peerPath
}