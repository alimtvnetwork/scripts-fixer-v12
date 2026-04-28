<#
.SYNOPSIS
    Profile dispatcher -- runs a multi-step install pipeline declared in config.json.

.DESCRIPTION
    Subcommands:
      list                       Show all available profiles
      <name>                     Run profile <name> (e.g. minimal, base, advance)
      <name> --dry-run           Print the expanded step list, do not execute
      <name> -Yes / -y           Skip confirmation prompts inside steps
      help                       Show usage

.EXAMPLES
    .\run.ps1 profile list
    .\run.ps1 profile minimal
    .\run.ps1 profile advance --dry-run
    .\run.ps1 install profile-minimal
#>
param(
    [Parameter(Position = 0)]
    [string]$Action,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $scriptDir  "helpers\expand.ps1")
. (Join-Path $scriptDir  "helpers\executor.ps1")
. (Join-Path $scriptDir  "helpers\inline.ps1")

# Load config + log-messages -- bail out if missing
$configPath  = Join-Path $scriptDir "config.json"
$logMsgPath  = Join-Path $scriptDir "log-messages.json"
$isConfigMissing = -not (Test-Path $configPath)
if ($isConfigMissing) {
    Write-Host ""
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "Profile config missing at: $configPath"
    exit 1
}

$config      = Import-JsonConfig $configPath
$logMessages = Import-JsonConfig $logMsgPath
$script:LogMessages = $logMessages

# ── Stale-config detector ────────────────────────────────────────────
# Warn loudly if scripts/profile/config.json is behind upstream so users see
# why a profile (e.g. 'dev') seems missing. Best-effort, never fatal.
try {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
    Push-Location $repoRoot
    $localSha   = (& git rev-parse "HEAD:scripts/profile/config.json" 2>$null) | Out-String
    $remoteSha  = (& git rev-parse "@{u}:scripts/profile/config.json" 2>$null) | Out-String
    Pop-Location
    $localSha  = $localSha.Trim()
    $remoteSha = $remoteSha.Trim()
    $hasLocal   = -not [string]::IsNullOrWhiteSpace($localSha)
    $hasRemote  = -not [string]::IsNullOrWhiteSpace($remoteSha)
    $isDrifted  = $hasLocal -and $hasRemote -and ($localSha -ne $remoteSha)
    if ($isDrifted) {
        Write-Host ""
        Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
        Write-Host "Profile config is BEHIND upstream:" -ForegroundColor Yellow
        Write-Host "          File   : " -NoNewline -ForegroundColor DarkGray
        Write-Host $configPath -ForegroundColor White
        Write-Host "          Local  : $localSha" -ForegroundColor DarkGray
        Write-Host "          Remote : $remoteSha" -ForegroundColor DarkGray
        Write-Host "          Fix    : " -NoNewline -ForegroundColor DarkGray
        Write-Host "git -C `"$repoRoot`" pull --ff-only" -ForegroundColor Cyan
        Write-Host ""
    }
} catch {
    # Silent: detector must never break the dispatcher
}

$sharedDirProf = Join-Path (Split-Path -Parent $scriptDir) "shared"
. (Join-Path $sharedDirProf "install-paths.ps1")

function Show-ProfileHelp {
    param([PSObject]$Config)
    Write-Host ""
    Write-Host "  Profile Dispatcher" -ForegroundColor Cyan
    Write-Host "  ==================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Usage: .\run.ps1 profile <name|list|help> [--dry-run] [-Yes]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Available profiles:" -ForegroundColor Yellow
    foreach ($prop in $Config.profiles.PSObject.Properties) {
        $name = $prop.Name
        $p    = $prop.Value
        $line = "    {0,-14}" -f $name
        Write-Host $line -NoNewline -ForegroundColor White
        $hasLabel = -not [string]::IsNullOrWhiteSpace($p.label)
        if ($hasLabel) { Write-Host "  $($p.label)" -ForegroundColor Gray -NoNewline }
        $hasDesc = -not [string]::IsNullOrWhiteSpace($p.description)
        if ($hasDesc) {
            Write-Host ""
            Write-Host ("                  {0}" -f $p.description) -ForegroundColor DarkGray
        } else {
            Write-Host ""
        }
    }
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor Yellow
    Write-Host "    .\run.ps1 profile list"               -ForegroundColor Gray
    Write-Host "    .\run.ps1 profile minimal"            -ForegroundColor Gray
    Write-Host "    .\run.ps1 profile advance --dry-run"  -ForegroundColor Gray
    Write-Host "    .\run.ps1 install profile-minimal"    -ForegroundColor Gray
    Write-Host ""
}

function Show-ProfileList {
    param([PSObject]$Config)
    Write-Host ""
    Write-Host "  Available Profiles" -ForegroundColor Cyan
    Write-Host "  ==================" -ForegroundColor DarkGray
    foreach ($prop in $Config.profiles.PSObject.Properties) {
        $name  = $prop.Name
        $p     = $prop.Value
        $count = ($p.steps | Measure-Object).Count
        Write-Host ("    {0,-14}  steps: {1,2}  -- {2}" -f $name, $count, $p.label) -ForegroundColor White
    }
    Write-Host ""
}

# Parse Rest args -- look for --dry-run / -Yes
$isDryRun  = $false
$isAutoYes = $false
$residual  = @()
if ($Rest) {
    foreach ($a in $Rest) {
        $low = "$a".Trim().ToLower()
        if ($low -in @("--dry-run", "-dryrun", "-dry-run", "/dryrun")) { $isDryRun  = $true; continue }
        if ($low -in @("-y", "--yes", "-yes"))                         { $isAutoYes = $true; continue }
        $residual += $a
    }
}

$normalizedAction = ""
$hasAction = -not [string]::IsNullOrWhiteSpace($Action)
if ($hasAction) { $normalizedAction = $Action.Trim().ToLower() }

if ($normalizedAction -in @("", "help", "--help", "-h")) {
    Show-ProfileHelp -Config $config
    exit 0
}
if ($normalizedAction -eq "list") {
    Show-ProfileList -Config $config
    exit 0
}

# Resolve profile by name (allow alias 'git' -> 'git-compact')
$profileAliases = @{
    "git"        = "git-compact"
    "gitcompact" = "git-compact"
    "cppdx"      = "cpp-dx"
    "smalldev"   = "small-dev"
}
$resolvedName = $normalizedAction
if ($profileAliases.ContainsKey($resolvedName)) { $resolvedName = $profileAliases[$resolvedName] }

$hasProfile = $null -ne $config.profiles.$resolvedName
if (-not $hasProfile) {
    $msg = $logMessages.messages.profileNotFound -replace '\{name\}', $Action
    Write-Host ""
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host $msg
    Show-ProfileList -Config $config
    exit 2
}

# Initialize logging
Initialize-Logging -ScriptName "Profile: $resolvedName"

# Expand recursively (cycle-safe)
$expanded = Expand-Profile -Config $config -Name $resolvedName -LogMessages $logMessages
$isExpandFailed = $null -eq $expanded
if ($isExpandFailed) {
    Save-LogFile -Status "fail"
    exit 1
}

$totalSteps = $expanded.Count
Write-Host ""
Write-Host "  Profile: $resolvedName" -ForegroundColor Cyan
Write-Host "  Steps  : $totalSteps" -ForegroundColor DarkGray
$prof = $config.profiles.$resolvedName
if ($prof.label)       { Write-Host "  Label  : $($prof.label)" -ForegroundColor DarkGray }
if ($prof.description) { Write-Host "  Desc   : $($prof.description)" -ForegroundColor DarkGray }
Write-Host ""

# Print step preview
for ($i = 0; $i -lt $totalSteps; $i++) {
    $s = $expanded[$i]
    $n = $i + 1
    $label = if ($s.label) { $s.label } else { "(no label)" }
    Write-Host ("    {0,3}. [{1,-10}] {2}" -f $n, $s.kind, $label) -ForegroundColor Gray
}
Write-Host ""

if ($isDryRun) {
    Write-Host "  [DRYRUN] No steps will be executed." -ForegroundColor Magenta
    Save-LogFile -Status "ok"
    exit 0
}

# Execute
$results = Invoke-ProfileSteps `
    -Steps        $expanded `
    -Config       $config `
    -LogMessages  $logMessages `
    -RootDir      (Split-Path -Parent (Split-Path -Parent $scriptDir)) `
    -AutoYes      $isAutoYes

# Final summary
Write-Host ""
Write-Host ("  Profile '{0}' Summary" -f $resolvedName) -ForegroundColor Cyan
Write-Host ("  " + ("=" * (20 + $resolvedName.Length))) -ForegroundColor DarkGray

$totalElapsed = 0.0
$failedCount  = 0
for ($i = 0; $i -lt $results.Count; $i++) {
    $r = $results[$i]
    $statusColor = switch ($r.Status) {
        "ok"   { "Green" }
        "fail" { "Red" }
        "skip" { "DarkGray" }
        "warn" { "Yellow" }
        default { "Gray" }
    }
    Write-Host ("    {0,3}. [{1,-10}] {2,-40} {3,-6} {4,6}s" -f ($i + 1), $r.Kind, $r.Label, $r.Status.ToUpper(), [Math]::Round($r.Elapsed, 1)) -ForegroundColor $statusColor
    $totalElapsed += $r.Elapsed
    if ($r.Status -eq "fail") { $failedCount++ }
}

Write-Host ""
$totalElapsedRounded = [Math]::Round($totalElapsed, 1)
if ($failedCount -eq 0) {
    Write-Host "  [  OK  ] " -ForegroundColor Green -NoNewline
    Write-Host ("All {0} step(s) succeeded in {1}s." -f $totalSteps, $totalElapsedRounded)
    Save-LogFile -Status "ok"
    exit 0
} else {
    Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
    Write-Host ("{0} of {1} step(s) failed (total {2}s)." -f $failedCount, $totalSteps, $totalElapsedRounded)
    Save-LogFile -Status "partial"
    exit 1
}
