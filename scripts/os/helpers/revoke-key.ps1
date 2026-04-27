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

    Dry-run effect per flag (with --dry-run, the diff against the
    target authorized_keys is computed and logged but NO file is
    rewritten, NO .bak is created, and the ledger at
    ~/.lovable/ssh-keys-state.json is NOT updated):
      --fingerprint "SHA256:..."  would log "[dry-run] would remove key
                                  <fingerprint> from <user>\.ssh\
                                  authorized_keys" per match. Keys not
                                  present are reported as "already
                                  revoked" (warning, not error).
      --key "<line>"              same as --fingerprint but matched by
                                  literal key body
      --comment "<text>"          same as --fingerprint but matched by
                                  the trailing comment column
      --all                       would log every key currently in
                                  authorized_keys as a planned removal;
                                  REQUIRES --yes (real-run only) but the
                                  prompt is auto-bypassed under --dry-run
      --user <name>               affects target resolution only; the
                                  planned path is included in every
                                  dry-run log line
      --backup                    default ON; under --dry-run no .bak is
                                  actually written but the planned
                                  filename "<file>.<ts>.bak" is logged
      --no-backup                 suppresses the .bak plan line
      --yes                       no dry-run effect on its own (only
                                  needed for --all in real-run)
      --ask                       prompts BEFORE the dry-run banner;
                                  collected match-spec still drives the
                                  would-do log lines
      --dry-run                   this flag itself; gates every
                                  authorized_keys rewrite, .bak creation,
                                  and ledger write
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
$promptHelper = Join-Path $helpersDir "_prompt.ps1"
if (Test-Path $promptHelper) { . $promptHelper }
$ledgerHelper = Join-Path $helpersDir "_ssh-ledger.ps1"
if (Test-Path $ledgerHelper) { . $ledgerHelper }

$logMessages = $null
$logMsgPath = Join-Path $scriptDir "log-messages.json"
if (Test-Path $logMsgPath) { $logMessages = Import-JsonConfig $logMsgPath }

Initialize-Logging -ScriptName "Revoke Key"

# ---- Parse ----
$fingerprints = @(); $keyLines = @(); $comments = @(); $targetUser = $null
$hasAsk = $false; $hasDryRun = $false; $doBackup = $true
$backupExplicit = $false
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
        '^--backup$'      { $doBackup = $true;  $backupExplicit = $true }
        '^--no-backup$'   { $doBackup = $false; $backupExplicit = $true }
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

# ---- Admin elevation when targeting another user's profile ----
$needsAdmin = ($targetUser -ne $env:USERNAME)
if ($needsAdmin -and -not $hasDryRun) {
    $forwardArgs = @($Argv | Where-Object { $_ -ne "--ask" })
    $isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
    if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }
}

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
$sshDir   = Split-Path -Parent $authFile

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
        # Revocation is destructive -- we MUST have a rollback path. Abort
        # unless the operator explicitly opted out of backups.
        Write-Log "Failed to back up authorized_keys at exact path: '$backupPath' (failure: $($_.Exception.Message)). Tool: Copy-Item. Aborting -- pass --no-backup to override." -Level "fail"
        Save-LogFile -Status "fail"; exit 1
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

# ---- Re-assert ACL on .ssh\ dir AND the file after Move-Item -Force ----
# Parity with install-key.ps1 / gen-key.ps1: harden the parent directory too,
# otherwise sshd StrictModes can silently reject the rewritten file if the
# parent dir was widened out-of-band. Move-Item -Force can also reset
# inheritance flags on the destination, so we re-harden the file unconditionally.
if (-not (Set-SshFileAcl -Path $sshDir -User $targetUser)) {
    Write-Log "Aborting: authorized_keys was rewritten but parent .ssh dir ACL hardening failed at exact path: '$sshDir' for user='$targetUser' (failure: see preceding icacls error). Roll back from the .bak created above." -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}
if (-not (Set-SshFileAcl -Path $authFile -User $targetUser)) {
    Write-Log "Aborting: authorized_keys was rewritten but ACL hardening failed -- the file is in an unsafe state at '$authFile'. Roll back from the .bak created above." -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Ledger ----
$hasLedger = [bool](Get-Command Add-SshLedgerEntry -ErrorAction SilentlyContinue)
if (-not $hasLedger) {
    Write-Log "SSH ledger helper not loaded -- audit trail at '~/.lovable/ssh-keys-state.json' will NOT record this revocation. Path: $ledgerHelper" -Level "warn"
}
foreach ($r in $removed) {
    $fp = Get-KeyFingerprint -Line $r
    $cmt = Get-KeyComment -Line $r
    if ($hasLedger) {
        Add-SshLedgerEntry -Action "revoke" -Fingerprint $fp -KeyPath $authFile -Source "revoke-key" -Comment $cmt | Out-Null
    }
    Write-Log "Revoked key $(if ($fp) { $fp } else { '(no fp)' }) for user '$targetUser'." -Level "success"
}

Write-Host ""
Write-Host "  Done. $($removed.Count) key(s) revoked, $($kept.Count) kept." -ForegroundColor Green
Write-Host ""

Save-LogFile -Status "ok"
exit 0
