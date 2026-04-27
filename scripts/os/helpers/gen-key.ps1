<#
.SYNOPSIS
    os gen-key -- Generate a new SSH keypair for the current Windows user.

.DESCRIPTION
    Usage:
      .\run.ps1 os gen-key [--type ed25519|rsa] [--bits 4096]
                           [--out <path>] [--comment "..."]
                           [--passphrase <pw> | --no-passphrase | --ask]
                           [--force] [--dry-run]

    Defaults:
      type        = ed25519
      out         = %USERPROFILE%\.ssh\id_<type>
      comment     = <user>@<host>
      passphrase  = prompted (use --no-passphrase or --passphrase to skip)

    Idempotent: refuses to overwrite an existing private key unless --force
    is passed. When generated, the new public key's SHA-256 fingerprint is
    appended to the cross-OS ledger at $HOME\.lovable\ssh-keys-state.json
    so future install-key / revoke-key calls can correlate it.

    CODE RED: every file/path error logs the EXACT path + reason.
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

Initialize-Logging -ScriptName "Gen Key"

# ---- Parse ----
$type = "ed25519"; $bits = $null; $out = $null; $comment = $null
$passphrase = $null; $hasNoPass = $false; $hasAsk = $false
$hasForce = $false; $hasDryRun = $false

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--type$'         { $i++; $type = $Argv[$i] }
        '^--type=(.+)$'    { $type = $Matches[1] }
        '^--bits$'         { $i++; $bits = [int]$Argv[$i] }
        '^--out$'          { $i++; $out = $Argv[$i] }
        '^--comment$'      { $i++; $comment = $Argv[$i] }
        '^--passphrase$'   { $i++; $passphrase = $Argv[$i] }
        '^--no-passphrase$' { $hasNoPass = $true }
        '^--ask$'          { $hasAsk = $true }
        '^--force$'        { $hasForce = $true }
        '^--dry-run$'      { $hasDryRun = $true }
        '^--' {
            Write-Log "Unknown flag: '$a' (failure: see --help)" -Level "fail"
            Save-LogFile -Status "fail"; exit 64
        }
        default {
            Write-Log "Unexpected positional: '$a' (failure: gen-key takes only flags)" -Level "fail"
            Save-LogFile -Status "fail"; exit 64
        }
    }
    $i++
}

# ---- Resolve defaults ----
if ($type -notin @("ed25519", "rsa", "ecdsa")) {
    Write-Log "Unsupported --type '$type' (failure: pick ed25519|rsa|ecdsa)" -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}
if ($type -eq "rsa" -and -not $bits) { $bits = 4096 }

$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not $out) { $out = Join-Path $sshDir "id_$type" }
if (-not $comment) { $comment = "$env:USERNAME@$env:COMPUTERNAME" }

# Re-derive $sshDir from --out so cross-user / non-default --out paths get
# the same hardening as the default %USERPROFILE%\.ssh path.
$sshDir = Split-Path -Parent $out

# Detect "owning user" of $sshDir for cross-user ACL hardening:
# if the parent of $sshDir is C:\Users\<u>, treat <u> as target.
# Mirrors the Linux /home/<u> + /Users/<u> detection in gen-key.sh.
$targetUser = $null
$sshParent  = Split-Path -Parent $sshDir
if ($sshParent -and (Split-Path -Leaf (Split-Path -Parent $sshParent)) -eq "Users") {
    $targetUser = Split-Path -Leaf $sshParent
}

# Resolve interactive passphrase.
if ($hasAsk -and -not $hasNoPass -and [string]::IsNullOrEmpty($passphrase)) {
    if (Get-Command Read-PromptSecret -ErrorAction SilentlyContinue) {
        $passphrase = Read-PromptSecret -Prompt "Passphrase (blank = none)"
    }
}

# ---- Idempotency check ----
if ((Test-Path -LiteralPath $out) -and -not $hasForce) {
    Write-Log "Private key already exists at exact path: '$out' (failure: pass --force to overwrite, or pick a different --out)" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Ensure .ssh dir exists with restrictive ACL ----
if (-not (Test-Path -LiteralPath $sshDir)) {
    try {
        New-Item -ItemType Directory -Path $sshDir -Force -ErrorAction Stop | Out-Null
        Write-Log "Created SSH dir at exact path: '$sshDir'." -Level "info"
    } catch {
        Write-Log "Failed to create SSH dir at exact path: '$sshDir' (failure: $($_.Exception.Message))" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}

# ---- Dry-run ----
if ($hasDryRun) {
    Write-Host ""
    Write-Host "  DRY-RUN -- would generate keypair:" -ForegroundColor Cyan
    Write-Host "    Type        : $type$(if ($bits) { " ($bits bits)" })"
    Write-Host "    Out         : $out  (+ ${out}.pub)"
    Write-Host "    Comment     : $comment"
    Write-Host "    Passphrase  : $(if ($hasNoPass -or [string]::IsNullOrEmpty($passphrase)) { '(none)' } else { '(set)' })"
    Write-Host "    Force       : $hasForce"
    if ($targetUser) { Write-Host "    Owner (post): $targetUser (ACL applied at apply time)" }
    Write-Host ""
    Save-LogFile -Status "ok"; exit 0
}

# ---- Validate ssh-keygen exists (after dry-run so dry-run works on stripped hosts) ----
$keygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $keygen) {
    Write-Log "ssh-keygen not found on PATH (failure: install OpenSSH client). Try: 'Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'" -Level "fail"
    Save-LogFile -Status "fail"; exit 127
}

# ---- Build ssh-keygen args ----
$pp = if ($hasNoPass -or [string]::IsNullOrEmpty($passphrase)) { "" } else { $passphrase }
$kgArgs = @("-t", $type, "-f", $out, "-C", $comment, "-N", $pp, "-q")
if ($bits) { $kgArgs += @("-b", $bits.ToString()) }
if ($hasForce -and (Test-Path -LiteralPath $out)) {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$out.pub" -Force -ErrorAction SilentlyContinue
}

try {
    & ssh-keygen @kgArgs
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen exited with code $LASTEXITCODE" }
} catch {
    Write-Log "ssh-keygen failed for out='$out' (failure: $($_.Exception.Message))" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

if (-not (Test-Path -LiteralPath "$out.pub")) {
    Write-Log "Public key was not produced at exact path: '$out.pub' (failure: ssh-keygen ran but output missing)" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Compute fingerprint + ledger entry ----
$fingerprint = $null
try {
    $fp = & ssh-keygen -lf "$out.pub" 2>&1
    if ($LASTEXITCODE -eq 0 -and $fp) {
        # Output: "256 SHA256:abcd... comment (ED25519)"
        $fingerprint = ($fp -split '\s+')[1]
    }
} catch {}

if (Get-Command Add-SshLedgerEntry -ErrorAction SilentlyContinue) {
    Add-SshLedgerEntry -Action "generate" -Fingerprint $fingerprint -KeyPath "$out.pub" -Source "gen-key" -Comment $comment | Out-Null
}

# ---- ACL hardening (CODE RED -- never swallow icacls failures) ----
# Same restrictive set the Linux numeric chown produces: only the
# owning user, SYSTEM, and Administrators may read. Inheritance disabled.
# When $targetUser is unset (default %USERPROFILE%\.ssh), use $env:USERNAME.
$aclUser = if ($targetUser) { $targetUser } else { $env:USERNAME }
$aclTargets = @($sshDir, $out, "$out.pub")
foreach ($t in $aclTargets) {
    # /inheritance:r  -> remove inherited ACEs
    # /grant:r        -> replace any existing grants for the principal
    & icacls $t /inheritance:r 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "sshAclHardenFail: icacls /inheritance:r failed at exact path: '$t' for user='$aclUser' (failure: icacls exit $LASTEXITCODE)" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
    & icacls $t /grant:r "${aclUser}:(F)" "SYSTEM:(F)" "Administrators:(F)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "sshAclHardenFail: icacls /grant:r failed at exact path: '$t' for user='$aclUser' (failure: icacls exit $LASTEXITCODE)" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}
Write-Log "sshAclHardened: applied restrictive ACL ($aclUser + SYSTEM + Administrators) to SSH dir + keypair at '$sshDir'." -Level "info"

Write-Host ""
Write-Host "  Key Generation Summary" -ForegroundColor Cyan
Write-Host "  ======================" -ForegroundColor DarkGray
Write-Host "    Private key : $out"
Write-Host "    Public key  : $out.pub"
Write-Host "    Type        : $type$(if ($bits) { " ($bits bits)" })"
Write-Host "    Comment     : $comment"
if ($fingerprint) { Write-Host "    Fingerprint : $fingerprint" }
Write-Host ""

Save-LogFile -Status "ok"
exit 0
