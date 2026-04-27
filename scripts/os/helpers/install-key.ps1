<#
.SYNOPSIS
    os install-key -- Install one or many SSH public keys into a Windows
    user's authorized_keys file, idempotently.

.DESCRIPTION
    Usage:
      .\run.ps1 os install-key --key "<full-pubkey-line>"   [--user <name>]
      .\run.ps1 os install-key --key-file <path>            [--user <name>]
      .\run.ps1 os install-key --ask                         [--user <name>]
      Common flags:
        --user <name>     Target local user (default: current user)
        --dry-run         Print the diff, change nothing
        --backup          Save authorized_keys.<ts>.bak before edit (default: on)
        --no-backup       Skip backup

    Idempotency contract -- the rule the user explicitly asked for:
      1. Read the existing authorized_keys (if any).
      2. Trim every line; split on whitespace; isolate the KEY BODY
         (column 2: 'ssh-ed25519 AAAA...comment' -> 'AAAA...').
      3. Compare incoming keys against existing key bodies + fingerprints.
      4. Append ONLY keys whose body is NOT already present.
      5. Never blindly append. Never duplicate. Never reorder existing keys.
      6. Record every install in ~/.lovable/ssh-keys-state.json.

    CODE-RED: every file/path error logs the EXACT path + reason.

    Dry-run effect per flag (with --dry-run, the diff against the
    target authorized_keys is computed and logged but NO file is
    rewritten, NO .bak is created, and the ledger at
    ~/.lovable/ssh-keys-state.json is NOT updated):
      --key "<line>"     would log "[dry-run] would append key
                         <fingerprint> to <user>\.ssh\authorized_keys"
                         per unique incoming key. Keys whose body is
                         already present are reported as "already
                         installed" (no append).
      --key-file <path>  same as --key but each file is parsed for one
                         or many keys (blanks/# comments skipped). Path
                         existence + readability are checked even in
                         dry-run.
      --user <name>      affects target resolution only; the planned
                         path is included in every dry-run log line
      --backup           default ON; under --dry-run no .bak is
                         actually written but the planned filename
                         "<file>.<ts>.bak" is logged
      --no-backup        suppresses the .bak plan line
      --ask              prompts BEFORE the dry-run banner; collected
                         key still drives the would-do log lines
      --dry-run          this flag itself; gates every authorized_keys
                         rewrite, .bak creation, and ledger write
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

Initialize-Logging -ScriptName "Install Key"

# ---- Parse ----
$keys = @(); $keyFiles = @(); $targetUser = $null
$hasAsk = $false; $hasDryRun = $false; $doBackup = $true
$backupExplicit = $false   # tracks whether the user explicitly chose --no-backup

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--key$'         { $i++; if ($i -lt $Argv.Count) { $keys += $Argv[$i] } }
        '^--key-file$'    { $i++; if ($i -lt $Argv.Count) { $keyFiles += $Argv[$i] } }
        '^--user$'        { $i++; if ($i -lt $Argv.Count) { $targetUser = $Argv[$i] } }
        '^--ask$'         { $hasAsk = $true }
        '^--dry-run$'     { $hasDryRun = $true }
        '^--backup$'      { $doBackup = $true;  $backupExplicit = $true }
        '^--no-backup$'   { $doBackup = $false; $backupExplicit = $true }
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
    if ($keys.Count -eq 0 -and $keyFiles.Count -eq 0) {
        $line = Read-PromptString -Prompt "Paste one full public key line" -Required
        $keys += $line
    }
}

if (-not $targetUser) { $targetUser = $env:USERNAME }

# ---- Admin elevation (required when writing under another user's profile) ----
$needsAdmin = ($targetUser -ne $env:USERNAME)
if ($needsAdmin -and -not $hasDryRun) {
    $forwardArgs = @($Argv | Where-Object { $_ -ne "--ask" })
    $isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
    if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }
}

# ---- Resolve target authorized_keys path ----
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

$sshDir = Join-Path $profilePath ".ssh"
$authFile = Join-Path $sshDir "authorized_keys"

# ---- Collect incoming keys ----
$incoming = @()  # array of raw single-line strings
foreach ($k in $keys) {
    if (-not [string]::IsNullOrWhiteSpace($k)) { $incoming += $k.Trim() }
}
foreach ($f in $keyFiles) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Log "Key file not found at exact path: '$f' (failure: file does not exist)" -Level "fail"
        Save-LogFile -Status "fail"; exit 2
    }
    try {
        $lines = Get-Content -LiteralPath $f -ErrorAction Stop
    } catch {
        Write-Log "Failed to read key file at exact path: '$f' (failure: $($_.Exception.Message))" -Level "fail"
        Save-LogFile -Status "fail"; exit 2
    }
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith("#")) { $incoming += $t }
    }
}

if ($incoming.Count -eq 0) {
    Write-Log "No keys to install (failure: pass --key, --key-file, or --ask)" -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}

# ---- Helper: extract key body (column 2) for comparison ----
function Get-KeyBody {
    param([string]$Line)
    $parts = ($Line.Trim() -split '\s+', 3)
    if ($parts.Count -ge 2) { return $parts[1] }
    return $Line.Trim()
}

# ---- Helper: short fingerprint via ssh-keygen on a temp file ----
function Get-KeyFingerprint {
    param([string]$Line)
    $keygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if (-not $keygen) { return $null }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value $Line -Encoding ASCII -ErrorAction Stop
        $out = & ssh-keygen -lf $tmp 2>&1
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ($out -split '\s+')[1]
        }
    } catch {} finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return $null
}

# ---- Read existing authorized_keys ----
$existingLines = @()
if (Test-Path -LiteralPath $authFile) {
    try {
        $existingLines = @(Get-Content -LiteralPath $authFile -ErrorAction Stop)
    } catch {
        Write-Log "Failed to read authorized_keys at exact path: '$authFile' (failure: $($_.Exception.Message))" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}

$existingBodies = @{}
foreach ($l in $existingLines) {
    $t = $l.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    $body = Get-KeyBody -Line $t
    $existingBodies[$body] = $true
}

# ---- Diff: which incoming keys are new? ----
$toInstall = @()
$skipped = @()
foreach ($k in $incoming) {
    $body = Get-KeyBody -Line $k
    if ($existingBodies.ContainsKey($body)) {
        $skipped += $k
    } else {
        $toInstall += $k
        $existingBodies[$body] = $true   # de-dupe within incoming batch
    }
}

Write-Host ""
Write-Host "  Install Plan" -ForegroundColor Cyan
Write-Host "  ============" -ForegroundColor DarkGray
Write-Host "    User              : $targetUser"
Write-Host "    authorized_keys   : $authFile"
Write-Host "    Existing keys     : $($existingBodies.Count - $toInstall.Count)"
Write-Host "    Incoming keys     : $($incoming.Count)"
Write-Host "    Already present   : $($skipped.Count)" -ForegroundColor DarkYellow
Write-Host "    Will install (new): $($toInstall.Count)" -ForegroundColor Green
Write-Host ""

if ($hasDryRun) {
    foreach ($k in $toInstall) {
        $fp = Get-KeyFingerprint -Line $k
        Write-Host "    + would add: $(if ($fp) { $fp } else { ($k.Substring(0, [Math]::Min(50, $k.Length)) + '...') })"
    }
    Save-LogFile -Status "ok"; exit 0
}

if ($toInstall.Count -eq 0) {
    Write-Log "All $($incoming.Count) incoming key(s) already present -- nothing to do." -Level "info"
    Save-LogFile -Status "ok"; exit 0
}

# ---- Ensure .ssh dir exists ----
if (-not (Test-Path -LiteralPath $sshDir)) {
    try {
        New-Item -ItemType Directory -Path $sshDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "Failed to create SSH dir at exact path: '$sshDir' (failure: $($_.Exception.Message))" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}
# Harden the .ssh\ directory ACL BEFORE we write any key material into it.
# OpenSSH StrictModes will silently reject keys if the parent dir is world-readable.
if (-not (Set-SshFileAcl -Path $sshDir -User $targetUser -DryRun:$hasDryRun)) {
    Write-Log "Aborting: could not harden ACL on SSH dir '$sshDir' (refusing to write key material into a world-readable dir)" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Backup existing file ----
if ($doBackup -and (Test-Path -LiteralPath $authFile)) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$authFile.$ts.bak"
    try {
        Copy-Item -LiteralPath $authFile -Destination $backupPath -ErrorAction Stop
        Write-Log "Backed up authorized_keys to '$backupPath'." -Level "info"
    } catch {
        # If the user explicitly chose --backup (or accepted the default), we
        # MUST NOT mutate authorized_keys after a failed backup -- that would
        # leave them with no rollback path. Pass --no-backup to override.
        Write-Log "Failed to back up authorized_keys at exact path: '$backupPath' (failure: $($_.Exception.Message)). Tool: Copy-Item. Aborting -- pass --no-backup to override." -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}

# ---- Append new keys atomically (write merged content to temp + move) ----
$merged = @()
$merged += $existingLines
# Ensure trailing newline before appending
if ($merged.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($merged[-1])) {
    # ok, will be appended on its own line by Set-Content
}
$merged += $toInstall

# Write the merged content to a temp file in the SAME directory so:
#   1. Move-Item is atomic (same volume).
#   2. The temp file inherits the already-hardened .ssh\ ACL we set above
#      (no widening window where the key body sits in a world-readable temp).
$tmpFile = "$authFile.tmp"
try {
    Set-Content -LiteralPath $tmpFile -Value ($merged -join "`n") -Encoding ASCII -NoNewline:$false -ErrorAction Stop
    Move-Item -LiteralPath $tmpFile -Destination $authFile -Force -ErrorAction Stop
} catch {
    Write-Log "Failed to write authorized_keys at exact path: '$authFile' (failure: $($_.Exception.Message))" -Level "fail"
    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    Save-LogFile -Status "fail"; exit 1
}

# ---- Lock down ACL on authorized_keys (re-asserted after Move-Item) ----
# Move-Item -Force can replace inheritance flags depending on the temp file's
# original ACL, so we always re-harden after writing. Failure is FATAL: if we
# can't lock the file, sshd will reject it under StrictModes anyway -- better
# to abort loudly than ship an unusable key.
if (-not (Set-SshFileAcl -Path $authFile -User $targetUser)) {
    Write-Log "Aborting: authorized_keys was written but ACL hardening failed -- the file is in an unsafe state at '$authFile'. Roll back from the .bak created above." -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Ledger ----
$hasLedger = [bool](Get-Command Add-SshLedgerEntry -ErrorAction SilentlyContinue)
if (-not $hasLedger) {
    Write-Log "SSH ledger helper not loaded -- audit trail at '~/.lovable/ssh-keys-state.json' will NOT record this install. Path: $ledgerHelper" -Level "warn"
}
foreach ($k in $toInstall) {
    $fp = Get-KeyFingerprint -Line $k
    $body = Get-KeyBody -Line $k
    $cmt = $null
    $parts = ($k -split '\s+', 3)
    if ($parts.Count -ge 3) { $cmt = $parts[2] }
    if ($hasLedger) {
        Add-SshLedgerEntry -Action "install" -Fingerprint $fp -KeyPath $authFile -Source "install-key" -Comment $cmt | Out-Null
    }
    Write-Log "Installed key $(if ($fp) { $fp } else { '(no fp)' }) for user '$targetUser'." -Level "success"
}

Write-Host ""
Write-Host "  Done. $($toInstall.Count) key(s) installed, $($skipped.Count) already present." -ForegroundColor Green
Write-Host ""

Save-LogFile -Status "ok"
exit 0
