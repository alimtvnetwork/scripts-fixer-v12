<#
.SYNOPSIS
    os add-user-json -- Bulk-create local Windows users from a JSON file.

.DESCRIPTION
    Mirrors the bash side (scripts-linux/68-user-mgmt/add-user-from-json.sh):
    auto-detects three JSON shapes and dispatches each entry to add-user.ps1.

    Shapes:
      1. Single object:   { "name": "alice", "password": "...", "role": "admin", ... }
      2. Array:           [ { ... }, { ... } ]
      3. Wrapped:         { "users": [ ... ] }

    User record fields (verbatim from readme.md "User record fields";
    every field optional except 'name'):
      name          string    REQUIRED
      password      string    plain text (never logged; masked in console)
      passwordFile  string    path to a 0600/0400 file containing the password (preferred)
      uid           number    explicit UID (auto-allocated on macOS if omitted; ignored on Windows)
      primaryGroup  string    primary group; created if missing on Linux (no-op on Windows)
      groups        string[]  supplementary groups
      shell         string    login shell (default: /bin/bash Linux, /bin/zsh macOS; ignored on Windows)
      home          string    home dir (default: /home/<name> | /Users/<name>; ignored on Windows)
      comment       string    GECOS / RealName (becomes account FullName on Windows)
      sudo          bool      also add to 'sudo' (Linux) / 'admin' (macOS) / 'Administrators' (Windows)
      system        bool      system account (Linux only; ignored on macOS + Windows)
      sshKeys       string[]  inline OpenSSH public keys to install in ~/.ssh/authorized_keys
      sshKeyFiles   string[]  host paths to .pub files (one or many keys per file; comments ok)

    Windows-only convenience fields (no-op on Linux/macOS):
      role             "admin" | "standard" (alias for sudo:true / sudo:false)
      pin              Windows Hello PIN hint
      microsoftAccount Outlook/Live email -- triggers MS account RunOnce hint
      msAccountOnLogon true -> queue MS-account RunOnce on first logon

    JSON examples (each record below would pass schema validation):
      // 1) minimal single object
      { "name": "dan", "password": "Welcome1!" }

      // 2) array of mixed shapes
      [
        { "name": "alice", "password": "P@ss",       "groups": ["sudo","docker"] },
        { "name": "bob",   "passwordFile": "C:\\secrets\\bob.pw",
          "comment": "Bob the Builder", "role": "admin" },
        { "name": "carol", "password": "x", "sudo": true,
          "sshKeys":     ["ssh-ed25519 AAAA... carol@laptop"],
          "sshKeyFiles": ["C:\\keys\\carol.pub"] }
      ]

      // 3) wrapped (legal at the top level only)
      { "users": [ { "name": "dan", "password": "..." } ] }

    Usage:
      .\run.ps1 os add-user-json <file.json> [--dry-run]
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv = @())

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")

Initialize-Logging -ScriptName "Add User (JSON)"

$jsonPath = $null; $hasDryRun = $false
foreach ($a in $Argv) {
    if ($a -eq "--dry-run") { $hasDryRun = $true; continue }
    if ($a -like "--*") {
        Write-Log "Unknown flag: '$a'" -Level "fail"; Save-LogFile -Status "fail"; exit 64
    }
    if (-not $jsonPath) { $jsonPath = $a }
}

if (-not $jsonPath) {
    Write-Log "Missing <file.json>. Usage: .\run.ps1 os add-user-json <file.json> [--dry-run]" -Level "fail"
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

# Normalise to an array of entries
$entries = @()
if ($parsed -is [System.Array]) {
    $entries = @($parsed)
} elseif ($parsed.PSObject.Properties.Name -contains "users") {
    $entries = @($parsed.users)
} elseif ($parsed.PSObject.Properties.Name -contains "name") {
    $entries = @($parsed)
} else {
    Write-Log "Unknown JSON shape. Path: $jsonPath. Reason: must be a single user object, an array, or { users: [...] }." -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

if ($entries.Count -eq 0) {
    Write-Log "No user entries found in '$jsonPath'." -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}

Write-Host ""
Write-Host "  Bulk add-user from: $jsonPath  ($($entries.Count) entries)" -ForegroundColor Cyan
if ($hasDryRun) { Write-Host "  Mode: DRY-RUN (no changes)" -ForegroundColor Yellow }
Write-Host ""

$leaf = Join-Path $helpersDir "add-user.ps1"
$failCount = 0; $okCount = 0
$idx = 0
foreach ($e in $entries) {
    $idx++
    $name = $null; try { $name = $e.name } catch {}
    $pass = $null; try { $pass = $e.password } catch {}
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($pass)) {
        Write-Log "Entry #${idx}: missing name or password (skipped). Path: $jsonPath" -Level "fail"
        $failCount++
        continue
    }
    $childArgs = @($name, $pass)
    try { if ($e.pin)   { $childArgs += [string]$e.pin } }   catch {}
    try { if ($e.email) { $childArgs += [string]$e.email } } catch {}
    $role = $null; try { $role = [string]$e.role } catch {}
    if ($role -match '^(?i)admin')    { $childArgs += "--admin" }
    if ($role -match '^(?i)standard') { $childArgs += "--standard" }
    $msa = $null; try { $msa = [string]$e.microsoftAccount } catch {}
    if ($msa) { $childArgs += @("--microsoft-account", $msa) }
    $onLogon = $false; try { $onLogon = [bool]$e.msAccountOnLogon } catch {}
    if ($onLogon) { $childArgs += "--ms-account-on-logon" }
    if ($hasDryRun) { $childArgs += "--dry-run" }

    Write-Host "  --- Entry ${idx}: $name ---" -ForegroundColor DarkCyan
    & $leaf @childArgs
    if ($LASTEXITCODE -eq 0) { $okCount++ } else { $failCount++ }
}

Write-Host ""
Write-Host "  Bulk summary: $okCount ok, $failCount fail (of $($entries.Count))" -ForegroundColor Cyan
Write-Host ""
$status = if ($failCount -eq 0) { "ok" } else { "fail" }
Save-LogFile -Status $status
if ($failCount -eq 0) { exit 0 } else { exit 1 }
