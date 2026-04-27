<#
.SYNOPSIS
    os add-group-json -- Bulk create local Windows groups from a JSON file.

.DESCRIPTION
    Mirrors scripts-linux/68-user-mgmt/add-group-from-json.sh.

    Input shapes (auto-detected):
      1) Single object:  { "name": "devs", "description": "Developers" }
      2) Array:          [ { ... }, { ... } ]
      3) Wrapped:        { "groups": [ ... ] }

    Group record fields (verbatim from readme.md "Group record fields";
    every field optional except 'name'):
      name    string  REQUIRED
      gid     number  explicit GID (auto-allocated on macOS if omitted; ignored on Windows)
      system  bool    system group (Linux only; ignored on macOS + Windows)

    Windows-only convenience field (no-op on Linux/macOS):
      description  string  becomes the local group's Description property

    JSON examples (each record below would pass schema validation):
      // 1) minimal single object
      { "name": "devs" }

      // 2) array with explicit GID + Windows description
      [
        { "name": "devs", "gid": 2000, "description": "Developers" },
        { "name": "ops",  "gid": 2001 }
      ]

      // 3) wrapped (legal at the top level only)
      { "groups": [ { "name": "devs", "gid": 2000 } ] }

    Each record is dispatched to add-group.ps1. Per-record failures are
    counted but do NOT abort the run -- the script continues and exits with
    rc=1 if any record failed.

    CODE-RED: every file/path error logs the EXACT path + reason.

    Dry-run effect per JSON field (--dry-run is passed through to
    add-group.ps1 per record; see that script's .DESCRIPTION for the
    underlying "[dry-run] <cmd>" wording. Schema validation ALWAYS runs.):
      name         would call New-LocalGroup -Name <name>; existing group
                   -> [WARN] + skip (idempotent)
      gid          IGNORED on Windows (Linux/macOS only; no log line)
      system       IGNORED on Windows (Linux only; no log line)
      description  would pass -Description "..." to New-LocalGroup; in
                   dry-run the planned property is logged
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv = @())

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")

$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages
Initialize-Logging -ScriptName "Add Groups (JSON)"

# ---- Parse ----
$JsonFile = $null; $hasDryRun = $false
$positional = @()
$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--dry-run$' { $hasDryRun = $true }
        '^--' {
            Write-Log "Unknown flag: '$a'" -Level "fail"; Save-LogFile -Status "fail"; exit 64
        }
        default { $positional += $a }
    }
    $i++
}
if ($positional.Count -ge 1) { $JsonFile = $positional[0] }

if ([string]::IsNullOrWhiteSpace($JsonFile)) {
    Write-Log "Missing <file.json> (failure: nothing to read). Usage: .\run.ps1 os add-group-json <file.json> [--dry-run]" -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}
if (-not (Test-Path -LiteralPath $JsonFile)) {
    Write-Log "JSON input not found at exact path: '$JsonFile' (failure: file does not exist on disk)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

# ---- Load + normalise ----
try {
    $raw = Get-Content -LiteralPath $JsonFile -Raw -ErrorAction Stop
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Log "Failed to parse JSON at '$JsonFile' (failure: $($_.Exception.Message))" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$records = @()
if ($parsed -is [System.Array]) {
    $records = $parsed
} elseif ($parsed.PSObject.Properties.Name -contains 'groups' -and $parsed.groups -is [System.Array]) {
    $records = $parsed.groups
} elseif ($parsed -is [PSCustomObject]) {
    $records = @($parsed)
} else {
    Write-Log "Top-level JSON must be an object or array at '$JsonFile' (failure: unsupported shape)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$count = $records.Count
Write-Log "Loaded $count group record(s) from '$JsonFile'." -Level "info"

$addGroup = Join-Path $helpersDir "add-group.ps1"
if (-not (Test-Path -LiteralPath $addGroup)) {
    Write-Log "Helper not found at exact path: '$addGroup' (failure: add-group.ps1 missing from helpers dir)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$rcTotal = 0
for ($idx = 0; $idx -lt $count; $idx++) {
    $rec = $records[$idx]
    $name = $null; $desc = $null
    if ($rec.PSObject.Properties.Name -contains 'name')        { $name = [string]$rec.name }
    if ($rec.PSObject.Properties.Name -contains 'description') { $desc = [string]$rec.description }

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Log "Record $($idx+1)/$count in '$JsonFile' is missing required field 'name' (failure: skipped)" -Level "fail"
        $rcTotal = 1
        continue
    }

    $childArgs = @($name)
    if (-not [string]::IsNullOrWhiteSpace($desc)) { $childArgs += @("--description", $desc) }
    if ($hasDryRun) { $childArgs += "--dry-run" }

    Write-Log "--- record $($idx+1)/$count: group='$name' ---" -Level "info"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $addGroup @childArgs
    if ($LASTEXITCODE -ne 0) { $rcTotal = 1 }
}

Save-LogFile -Status $(if ($rcTotal -eq 0) { "ok" } else { "fail" })
exit $rcTotal
