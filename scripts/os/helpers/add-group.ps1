<#
.SYNOPSIS
    os add-group -- Create a single local Windows group.

.DESCRIPTION
    Usage:
      .\run.ps1 os add-group <name> [--description "..."] [--ask] [--dry-run]

    Mirrors scripts-linux/68-user-mgmt/add-group.sh on the Windows side.
    Idempotent: re-running on an existing group is a no-op (warn + skip).
    The --gid / --system flags from the Unix side are intentionally OMITTED:
    Windows local groups have no numeric GID and no system/normal split.

    CODE-RED: every file/path/group error MUST log the exact identifier and
    failure reason via Write-Log -Level "fail".

    Dry-run effect per flag (with --dry-run, no group is created and the
    host is not modified; admin rights are not strictly required to
    PREVIEW the plan):
      <name>            would call New-LocalGroup -Name <name>; existing
                        group -> [WARN] + skip (idempotent)
      --description "." would pass -Description "..." to New-LocalGroup;
                        in dry-run the planned property is logged
      --ask             prompts BEFORE the dry-run banner; collected
                        values still drive the would-do log lines
      --dry-run         this flag itself; emits the dry-run banner and
                        gates the New-LocalGroup call
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

$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages
Initialize-Logging -ScriptName "Add Group"

# ---- Parse ----
$Name = $null; $Description = $null
$hasAsk = $false; $hasDryRun = $false
$positional = @()

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--description$'      { $i++; if ($i -lt $Argv.Count) { $Description = $Argv[$i] } }
        '^--description=(.+)$' { $Description = $Matches[1] }
        '^--ask$'              { $hasAsk = $true }
        '^--dry-run$'          { $hasDryRun = $true }
        '^--gid$|^--system$'   {
            Write-Log "Flag '$a' is Unix-only and ignored on Windows (failure: not applicable)." -Level "warn"
            if ($a -eq '--gid') { $i++ }  # consume the value too
        }
        '^--' {
            Write-Log "Unknown flag: '$a' (failure: see --help on add-group.sh)" -Level "fail"
            Save-LogFile -Status "fail"; exit 64
        }
        default { $positional += $a }
    }
    $i++
}
if ($positional.Count -ge 1) { $Name = $positional[0] }
if ($positional.Count -gt 1) {
    Write-Log "Unexpected positional args: '$($positional[1..($positional.Count-1)] -join ' ')' (failure: only <name> is positional)" -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}

# ---- --ask ----
if ($hasAsk -and (Get-Command Read-PromptString -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-PromptString -Prompt "Group name" -Required }
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = Read-PromptString -Prompt "Description (optional, blank to skip)"
    }
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Log "Missing <name> (failure: nothing to create). Usage: .\run.ps1 os add-group <name>" -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}

# ---- Dry-run short-circuit ----
if ($hasDryRun) {
    Write-Host ""
    Write-Host "  DRY-RUN -- would create group:" -ForegroundColor Cyan
    Write-Host "    Name        : $Name"
    if ($Description) { Write-Host "    Description : $Description" }
    Write-Host ""
    Save-LogFile -Status "ok"; exit 0
}

# ---- Elevation ----
$forwardArgs = @($Name)
if ($Description) { $forwardArgs += @("--description", $Description) }
$isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }

# ---- Idempotent create ----
$existing = $null
try { $existing = Get-LocalGroup -Name $Name -ErrorAction SilentlyContinue } catch {}
if ($existing) {
    Write-Log "Group '$Name' already exists -- skipping create." -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}

try {
    $createParams = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($Description) { $createParams['Description'] = $Description }
    New-LocalGroup @createParams | Out-Null
    Write-Log "Created local group '$Name'." -Level "success"
} catch {
    Write-Log "Failed to create group '$Name': $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

Write-Host ""
Write-Host "  Group Setup Summary" -ForegroundColor Cyan
Write-Host "  ===================" -ForegroundColor DarkGray
Write-Host "    Group created : $Name"
if ($Description) { Write-Host "    Description   : $Description" }
Write-Host ""

Save-LogFile -Status "ok"
exit 0
