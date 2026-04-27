<#
.SYNOPSIS
    os revoke-key -- Remove a specific SSH public key from a Windows
    user's authorized_keys, by fingerprint or by exact key body.

.DESCRIPTION
    Usage:
      .\run.ps1 os revoke-key --fingerprint "SHA256:..."  [--user <name>]
      .\run.ps1 os revoke-key --key "<full-pubkey-line>"  [--user <name>]
      .\run.ps1 os revoke-key --comment "alice@laptop"    [--user <name>]
      .\run.ps1 os revoke-key --ask                        [--user <name>]
      Common flags:
        --user <name>     Target local user (default: current user)
        --dry-run         Print the diff, change nothing
        --backup          Save authorized_keys.<ts>.bak (default: on)
        --no-backup       Skip backup
        --all             Revoke ALL keys for the user (requires --yes)
        --yes             Skip confirmation for --all

    Idempotent: keys not present are reported as "already revoked", not
    treated as errors. Removal logged to ~/.lovable/ssh-keys-state.json.

    CODE-RED: every file/path error logs the EXACT path + reason.
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv = @())

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
$promptHelper = Join-Path $helpersDir "_prompt.ps1"
if (Test-Path $promptHelper) { . $promptHelper }
$ledgerHelper = Join-Path $helpersDir "_ssh-ledger.ps1"
if (Test-Path $ledgerHelper) { . $ledgerHelper }

Initialize-Logging -ScriptName "Revoke Key"

# ---- Parse ----
$fingerprints = @(); $keyLines = @(); $comments = @(); $targetUser = $null
$hasAsk = $false; $hasDryRun = $false; $doBackup = $true
$revokeAll = $false; $autoYes = $false

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--fingerprint$' { $i++; if ($i -lt $Argv.Count) { $fingerprints += $Argv[$i] } }
        '^--key$'         { $i++; if ($i -lt $Argv.Count) { $keyLines += $Argv[$i] } }
        '^--comment$'     { $i++; if ($i -lt $Argv.Count) { $comments += $Argv[$i] } }
        '^--user$'        { $i++; if ($i -lt $Argv.Count) { $targetUser = $Argv[$i] } }
        '^--ask$'         { $hasAsk = $true }
        '^--dry-run$'     { $hasDryRun = $true }
        '^--backup$'      { $doBackup = $true }
        '^--no-backup$'   { $doBackup = $false }
        '^--all$'         { $revokeAll = $true }
        '^--yes$|^-y$'    { $autoYes = $true }
        '^--' {
            Write-Log "Unknown flag: '$a' (failure: see --help)" -Level "fail"
            Save-LogFile -Status "fail"; exit 64
        }
        default {
            Write-Log "Unexpected positional: '$a'" -Level "fail"
            Save-LogFile -Status "fail"; exit 64
        }
    }
    $i++
}

# ---- --ask ----
if ($hasAsk -and (Get-Command Read-PromptString -ErrorAction SilentlyContinue)) {
    if (-not $targetUser) { $targetUser = Read-PromptString -Prompt "Target user (blank = current)" }
    if ($fingerprints.Count + $keyLines.Count + $comments.Count -eq 0 -and -not $revokeAll) {
        $fp = Read-PromptString -Prompt "Fingerprint to revoke (blank = skip)"
        if ($fp) { $fingerprints += $fp }
    }
}

if (-not $targetUser) { $targetUser = $env:USERNAME }

# ---- Resolve authorized_keys path ----
$profilePath = $null
if ($targetUser -eq $env:USERNAME) {
    $profilePath = $env:USERPROFILE
} else {
    try {
        $u = Get-LocalUser -Name $targetUser -ErrorAction Stop
        $sid = $u.SID.Value
        $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
    } catch {
        Write-Log "Failed to resolve profile path for user '$targetUser' (failure: $($_.Exception.Message))" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}
$authFile = Join-Path $profilePath ".ssh\authorized_keys"

if (-not (Test-Path -LiteralPath $authFile)) {
    Write-Log "No authorized_keys at exact path: '$authFile' (failure: nothing to revoke for '$targetUser')" -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}

# ---- Validation ----
$totalSelectors = $fingerprints.Count + $keyLines.Count + $comments.Count
if (-not $revokeAll -and $totalSelectors -eq 0) {
    Write-Log "No selector given (failure: pass --fingerprint, --key, --comment, or --all)" -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}
if ($revokeAll -and -not $autoYes -and -not $hasDryRun) {
    Write-Host "  About to revoke ALL keys for '$targetUser'. Pass --yes to confirm." -ForegroundColor Yellow
    Save-LogFile -Status "fail"; exit 1
}

# ---- Helpers (same as install-key) ----
function Get-KeyBody {
    param([string]$Line)
    $parts = ($Line.Trim() -split '\s+', 3)
    if ($parts.Count -ge 2) { return $parts[1] }
    return $Line.Trim()
}
function Get-KeyComment {
    param([string]$Line)
    $parts = ($Line.Trim() -split '\s+', 3)
    if ($parts.Count -ge 3) { return $parts[2] }
    return ""
}
function Get-KeyFingerprint {
    param([string]$Line)
    $keygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if (-not $keygen) { return $null }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value $Line -Encoding ASCII -ErrorAction Stop
        $out = & ssh-keygen -lf $tmp 2>&1
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out -split '\s+')[1] }
    } catch {} finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return $null
}

# ---- Read existing ----
try {
    $existingLines = @(Get-Content -LiteralPath $authFile -ErrorAction Stop)
} catch {
    Write-Log "Failed to read authorized_keys at exact path: '$authFile' (failure: $($_.Exception.Message))" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Build target body set from --key flags ----
$targetBodies = @{}
foreach ($kl in $keyLines) { $targetBodies[(Get-KeyBody -Line $kl)] = $true }

# ---- Decide kept vs removed ----
$kept = @(); $removed = @()
foreach ($l in $existingLines) {
    $t = $l.Trim()
    if (-not $t -or $t.StartsWith("#")) { $kept += $l; continue }
    $shouldRemove = $false
    if ($revokeAll) { $shouldRemove = $true }
    if (-not $shouldRemove -and $targetBodies.ContainsKey((Get-KeyBody -Line $t))) { $shouldRemove = $true }
    if (-not $shouldRemove -and $comments.Count -gt 0) {
        $cmt = Get-KeyComment -Line $t
        foreach ($c in $comments) { if ($cmt -eq $c) { $shouldRemove = $true; break } }
    }
    if (-not $shouldRemove -and $fingerprints.Count -gt 0) {
        $fp = Get-KeyFingerprint -Line $t
        foreach ($f in $fingerprints) { if ($fp -eq $f) { $shouldRemove = $true; break } }
    }
    if ($shouldRemove) { $removed += $l } else { $kept += $l }
}

Write-Host ""
Write-Host "  Revoke Plan" -ForegroundColor Cyan
Write-Host "  ===========" -ForegroundColor DarkGray
Write-Host "    User              : $targetUser"
Write-Host "    authorized_keys   : $authFile"
Write-Host "    Lines before      : $($existingLines.Count)"
Write-Host "    Lines kept        : $($kept.Count)"
Write-Host "    Lines removed     : $($removed.Count)" -ForegroundColor Yellow
Write-Host ""

if ($removed.Count -eq 0) {
    Write-Log "No matching keys found -- nothing to revoke (already absent)." -Level "info"
    Save-LogFile -Status "ok"; exit 0
}

if ($hasDryRun) {
    foreach ($r in $removed) {
        $fp = Get-KeyFingerprint -Line $r
        Write-Host "    - would remove: $(if ($fp) { $fp } else { ($r.Substring(0, [Math]::Min(50, $r.Length)) + '...') })"
    }
    Save-LogFile -Status "ok"; exit 0
}

# ---- Backup + write ----
if ($doBackup) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$authFile.$ts.bak"
    try {
        Copy-Item -LiteralPath $authFile -Destination $backupPath -ErrorAction Stop
        Write-Log "Backed up authorized_keys to '$backupPath'." -Level "info"
    } catch {
        Write-Log "Failed to back up authorized_keys to exact path: '$backupPath' (failure: $($_.Exception.Message))" -Level "warn"
    }
}

$tmpFile = "$authFile.tmp"
try {
    Set-Content -LiteralPath $tmpFile -Value ($kept -join "`n") -Encoding ASCII -ErrorAction Stop
    Move-Item -LiteralPath $tmpFile -Destination $authFile -Force -ErrorAction Stop
} catch {
    Write-Log "Failed to write authorized_keys at exact path: '$authFile' (failure: $($_.Exception.Message))" -Level "fail"
    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    Save-LogFile -Status "fail"; exit 1
}

# ---- Ledger ----
foreach ($r in $removed) {
    $fp = Get-KeyFingerprint -Line $r
    $cmt = Get-KeyComment -Line $r
    if (Get-Command Add-SshLedgerEntry -ErrorAction SilentlyContinue) {
        Add-SshLedgerEntry -Action "revoke" -Fingerprint $fp -KeyPath $authFile -Source "revoke-key" -Comment $cmt | Out-Null
    }
    Write-Log "Revoked key $(if ($fp) { $fp } else { '(no fp)' }) for user '$targetUser'." -Level "success"
}

Write-Host ""
Write-Host "  Done. $($removed.Count) key(s) revoked, $($kept.Count) kept." -ForegroundColor Green
Write-Host ""

Save-LogFile -Status "ok"
exit 0
