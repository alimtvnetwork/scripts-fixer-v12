<#
.SYNOPSIS
    os remove-user-json -- Bulk-remove local Windows users from a JSON file.

.DESCRIPTION
    Mirrors scripts-linux/68-user-mgmt/remove-user-from-json.sh. Each record
    is applied IN-PROCESS via Invoke-UserDelete + Invoke-PurgeHome (defined in
    helpers/_common.ps1) rather than forking remove-user.ps1 per row.

    Confirmation prompts are auto-bypassed (this loader is non-interactive
    by design). Use --dry-run to preview without mutation.

    Shapes (auto-detected):
      1. Single object:   { "name": "alice", "purgeHome": true }
      2. Array:           [ { ... }, { ... } ]
      3. Wrapped:         { "users": [ ... ] }
      4. Bare strings:    [ "alice", "bob" ]   (shorthand: name only)

    Per-record schema (every field optional except 'name'):
      name           (required)         account to remove
      purgeHome      true/false         also delete C:\Users\<name> (DESTRUCTIVE)
      purgeProfile   true/false         alias of purgeHome (Windows-native name)
      removeMailSpool                   accepted but ignored (Linux-only concept)

    Removing a missing user is a no-op (idempotent), so this is safe to re-run.

    Usage:
      .\run.ps1 os remove-user-json <file.json> [--dry-run]
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv = @())

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $helpersDir "_common.ps1")

$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages
Initialize-Logging -ScriptName "Remove User (JSON)"

$jsonPath = $null; $hasDryRun = $false
foreach ($a in $Argv) {
    if ($a -eq "--dry-run") { $hasDryRun = $true; continue }
    if ($a -like "--*") {
        Write-Log "Unknown flag: '$a'" -Level "fail"; Save-LogFile -Status "fail"; exit 64
    }
    if (-not $jsonPath) { $jsonPath = $a }
}

if (-not $jsonPath) {
    Write-Log "Missing <file.json>. Usage: .\run.ps1 os remove-user-json <file.json> [--dry-run]" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}
if (-not (Test-Path -LiteralPath $jsonPath)) {
    Write-Log "JSON file not found. Path: $jsonPath. Reason: file does not exist or is not accessible." -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$raw = $null
try { $raw = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop }
catch {
    Write-Log "Failed to read JSON. Path: $jsonPath. Reason: $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$parsed = $null
try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop }
catch {
    Write-Log "Invalid JSON. Path: $jsonPath. Reason: $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

# Normalise: arrays of strings become {name: ...} records (parity with --allow-strings on bash).
$entries = @()
if ($parsed -is [System.Array]) {
    foreach ($item in $parsed) {
        if ($item -is [string]) { $entries += [PSCustomObject]@{ name = $item } }
        else                    { $entries += $item }
    }
} elseif ($parsed.PSObject.Properties.Name -contains "users") {
    foreach ($item in @($parsed.users)) {
        if ($item -is [string]) { $entries += [PSCustomObject]@{ name = $item } }
        else                    { $entries += $item }
    }
} elseif ($parsed.PSObject.Properties.Name -contains "name") {
    $entries = @($parsed)
} else {
    Write-Log "Unknown JSON shape. Path: $jsonPath. Reason: must be a single object, array, { users: [...] }, or [\"name1\",\"name2\"]." -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

if ($entries.Count -eq 0) {
    Write-Log "No removal records found in '$jsonPath'." -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}

if (-not $hasDryRun) {
    $forwardArgs = @($jsonPath)
    $isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
    if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }
}

Write-Host ""
Write-Host "  Bulk remove-user from: $jsonPath  ($($entries.Count) records)" -ForegroundColor Cyan
if ($hasDryRun) { Write-Host "  Mode: DRY-RUN (no host mutation)" -ForegroundColor Yellow }
Write-Host ""

function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $names = @()
    try { $names = $Obj.PSObject.Properties.Name } catch { return $null }
    if ($names -contains $Name) { return $Obj.$Name }
    return $null
}

$failCount = 0; $okCount = 0
$idx = 0
foreach ($e in $entries) {
    $idx++
    $name = Get-Prop $e "name"
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Log "Record #${idx}: missing 'name' (skipped). Path: $jsonPath" -Level "fail"
        $failCount++; continue
    }
    $isPurge = ([bool](Get-Prop $e "purgeHome")) -or ([bool](Get-Prop $e "purgeProfile"))

    Write-Host "  --- Record ${idx}/$($entries.Count): remove '$name'$(if ($isPurge) { ' (+purge profile)' }) ---" -ForegroundColor DarkCyan
    Write-Host "    - delete user account" -ForegroundColor Gray
    if ($isPurge) { Write-Host "    - delete profile folder (DESTRUCTIVE)" -ForegroundColor Yellow }

    $result = Invoke-UserDelete -Name $name -DryRun:$hasDryRun -PassThru
    if (-not $result.Success) { $failCount++; continue }

    if ($isPurge) {
        if (-not (Invoke-PurgeHome -ProfilePath $result.ProfilePath -DryRun:$hasDryRun)) {
            $failCount++; continue
        }
    }
    $okCount++
}

Write-Host ""
Write-Host "  Bulk remove-user summary: $okCount ok, $failCount fail (of $($entries.Count))" -ForegroundColor Cyan
Write-Host ""
$status = if ($failCount -eq 0) { "ok" } else { "fail" }
Save-LogFile -Status $status
if ($failCount -eq 0) { exit 0 } else { exit 1 }