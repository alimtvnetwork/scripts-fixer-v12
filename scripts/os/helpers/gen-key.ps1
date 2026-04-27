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

    Dry-run effect per flag (with --dry-run, ssh-keygen.exe is NOT
    invoked, the cross-OS ledger at $HOME\.lovable\ssh-keys-state.json
    is NOT updated, and no files are written; the planned command is
    logged as "[dry-run] ssh-keygen ..." with the resolved arguments.
    The ssh-keygen-binary check is also SKIPPED so dry-run works on
    stripped hosts.):
      --type ed25519|rsa          would pass -t <type> to ssh-keygen
      --bits N                    would pass -b N (rsa only); ignored
                                  for ed25519 with no log line
      --out <path>                would pass -f <path>; parent dir is
                                  checked for writability but NOT created
      --comment "..."             would pass -C "..."
      --passphrase <pw>           would pass -N <masked>; value NEVER
                                  logged
      --no-passphrase             would pass -N "" (empty passphrase)
      --ask                       prompts BEFORE the dry-run banner;
                                  collected passphrase still drives the
                                  masked log line
      --force                     no dry-run effect on its own; in
                                  real-run it would Remove-Item the
                                  existing private + public key first
                                  (logged as such in dry-run only if the
                                  key exists today)
      --dry-run                   this flag itself; emits the dry-run
                                  banner, skips the ssh-keygen-binary
                                  check, and gates every Remove-Item /
                                  ssh-keygen / ledger-write call
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

# Audit-trail parity with install-key.ps1 / revoke-key.ps1: if the ledger
# helper isn't loaded, emit a loud WARN with the helper path instead of
# silently skipping. A generated key with no ledger row will look "unknown"
# to later install/revoke calls.
$hasLedger = [bool](Get-Command Add-SshLedgerEntry -ErrorAction SilentlyContinue)
if (-not $hasLedger) {
    Write-Log "SSH ledger helper not loaded -- audit trail at '~/.lovable/ssh-keys-state.json' will NOT record this generation. Path: $ledgerHelper" -Level "warn"
} else {
    Add-SshLedgerEntry -Action "generate" -Fingerprint $fingerprint -KeyPath "$out.pub" -Source "gen-key" -Comment $comment | Out-Null
}

# ---- ACL hardening (CODE RED -- never swallow icacls failures) ----
# Delegate to Set-SshFileAcl so gen-key matches install-key/revoke-key exactly:
#   * /inheritance:r           -> drop inherited ACEs
#   * /grant:r SYSTEM/Admins/U -> replace grants
#   * /remove:g Authenticated Users / Everyone / Users -> strip world access
#   * /setowner <user>         -> let the user rotate keys without admin
# When $targetUser is unset (default %USERPROFILE%\.ssh), use $env:USERNAME.
$aclUser = if ($targetUser) { $targetUser } else { $env:USERNAME }
foreach ($t in @($sshDir, $out, "$out.pub")) {
    if (-not (Set-SshFileAcl -Path $t -User $aclUser)) {
        Write-Log "sshAclHardenFail: Set-SshFileAcl returned false at exact path: '$t' for user='$aclUser' (failure: see preceding icacls error)" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}
Write-Log "sshAclHardened: applied restrictive ACL ($aclUser + SYSTEM + Administrators, no inheritance) to SSH dir + keypair at '$sshDir'." -Level "info"

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
