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

# ── Profile alias resolution ────────────────────────────────────────
# Two kinds of aliases (see scripts/profile/profile-aliases.json):
#   exact    -> hard rename, silent (e.g. 'git' -> 'git-compact')
#   fallback -> closest-match for a profile not present locally;
#               emits a [ WARN ] before running (e.g. 'dev' -> 'base')
#
# Built-in defaults are merged with the JSON file so the dispatcher still
# works even if the alias file is deleted.
$builtinAliases = @{
    "git"         = @{ kind = "exact";    target = "git-compact" }
    "gitcompact"  = @{ kind = "exact";    target = "git-compact" }
    "cppdx"       = @{ kind = "exact";    target = "cpp-dx" }
    "smalldev"    = @{ kind = "exact";    target = "small-dev" }
    "dev"         = @{ kind = "fallback"; target = "base";    reason = "'dev' profile not present locally; closest match is 'base'." }
    "dev-advance" = @{ kind = "fallback"; target = "advance"; reason = "'dev-advance' profile not present locally; closest match is 'advance'." }
}

$aliasMap   = @{}
foreach ($k in $builtinAliases.Keys) { $aliasMap[$k.ToLower()] = $builtinAliases[$k] }

$aliasPath = Join-Path $scriptDir "profile-aliases.json"
if (Test-Path -LiteralPath $aliasPath) {
    try {
        $aliasObj = Get-Content -LiteralPath $aliasPath -Raw | ConvertFrom-Json
        if ($aliasObj -and $aliasObj.aliases) {
            foreach ($prop in $aliasObj.aliases.PSObject.Properties) {
                $entry = @{
                    kind   = "$($prop.Value.kind)".ToLower()
                    target = "$($prop.Value.target)"
                }
                if ($prop.Value.PSObject.Properties.Name -contains 'reason') {
                    $entry.reason = "$($prop.Value.reason)"
                }
                $aliasMap[$prop.Name.ToLower()] = $entry
            }
        }
    } catch {
        $msg = $logMessages.messages.aliasFileParseFailed `
            -replace '\{path\}', $aliasPath `
            -replace '\{error\}', $_.Exception.Message
        Write-Host ""
        Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
        Write-Host $msg -ForegroundColor Yellow
    }
} else {
    $msg = $logMessages.messages.aliasFileMissing -replace '\{path\}', $aliasPath
    Write-Host "  [ INFO ] " -ForegroundColor DarkGray -NoNewline
    Write-Host $msg -ForegroundColor DarkGray
}

$resolvedName     = $normalizedAction
$aliasFallbackHit = $null  # populated when a fallback alias is used

if ($aliasMap.ContainsKey($resolvedName)) {
    $entry  = $aliasMap[$resolvedName]
    $target = $entry.target
    if ($entry.kind -eq "fallback") {
        # Only fall back if the requested name itself is NOT already a real profile,
        # AND the target IS a real profile. Otherwise let the normal not-found path handle it.
        $isRequestedReal = $null -ne $config.profiles.$resolvedName
        $isTargetReal    = $null -ne $config.profiles.$target
        if (-not $isRequestedReal -and $isTargetReal) {
            $aliasFallbackHit = @{ requested = $resolvedName; target = $target; reason = $entry.reason }
            $resolvedName = $target
        }
    } else {
        # exact: silent rename (still print a small INFO line for transparency)
        $resolvedName = $target
        $line = $logMessages.messages.aliasExact `
            -replace '\{requested\}', $normalizedAction `
            -replace '\{target\}',    $target
        Write-Host "  [ INFO ] " -ForegroundColor DarkGray -NoNewline
        Write-Host $line -ForegroundColor DarkGray
    }
}

# Emit the warning for fallback aliases AFTER resolution so it's visually grouped
# with the upcoming "Profile: <name>" header.
if ($aliasFallbackHit) {
    $warn = $logMessages.messages.aliasFallback `
        -replace '\{requested\}', $aliasFallbackHit.requested `
        -replace '\{target\}',    $aliasFallbackHit.target
    Write-Host ""
    Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
    Write-Host $warn -ForegroundColor Yellow
    if ($aliasFallbackHit.reason) {
        $reasonLine = $logMessages.messages.aliasFallbackReason -replace '\{reason\}', $aliasFallbackHit.reason
        Write-Host ("          " + $reasonLine) -ForegroundColor DarkGray
    }
    Write-Host ("          " + $logMessages.messages.aliasFallbackHint) -ForegroundColor DarkGray
}

$hasProfile = $null -ne $config.profiles.$resolvedName
if (-not $hasProfile) {
    # ---- Build a richer "profile not found" block ------------------------
    # Includes: local script version, did-you-mean suggestions (from local
    # profiles + alias keys), and -- when the requested name is known to
    # exist in a newer release -- a copy-paste 'git pull' / re-install hint.
    $rootDir   = Split-Path -Parent (Split-Path -Parent $scriptDir)
    $verFile   = Join-Path (Join-Path $rootDir "scripts") "version.json"
    $localVer  = "unknown"
    if (Test-Path -LiteralPath $verFile) {
        try {
            $vobj = Get-Content -LiteralPath $verFile -Raw | ConvertFrom-Json
            if ($vobj -and $vobj.PSObject.Properties.Name -contains 'version') { $localVer = "$($vobj.version)" }
        } catch { } # version is best-effort; never fail the error path itself
    }

    # Did-you-mean: case-insensitive match by substring + simple Levenshtein
    $allLocalNames = @()
    foreach ($prop in $config.profiles.PSObject.Properties) { $allLocalNames += $prop.Name }
    foreach ($k in $aliasMap.Keys) { $allLocalNames += $k }
    $allLocalNames = @($allLocalNames | Sort-Object -Unique)

    function _Get-Levenshtein {
        param([string]$a, [string]$b)
        $la = $a.Length; $lb = $b.Length
        if ($la -eq 0) { return $lb }
        if ($lb -eq 0) { return $la }
        $d = New-Object 'int[,]' ($la + 1), ($lb + 1)
        for ($i = 0; $i -le $la; $i++) { $d[$i, 0] = $i }
        for ($j = 0; $j -le $lb; $j++) { $d[0, $j] = $j }
        for ($i = 1; $i -le $la; $i++) {
            for ($j = 1; $j -le $lb; $j++) {
                $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
                $del = $d[($i - 1), $j] + 1
                $ins = $d[$i, ($j - 1)] + 1
                $sub = $d[($i - 1), ($j - 1)] + $cost
                $d[$i, $j] = [Math]::Min([Math]::Min($del, $ins), $sub)
            }
        }
        return $d[$la, $lb]
    }

    $needle = $resolvedName.ToLower()
    $scored = @()
    foreach ($cand in $allLocalNames) {
        $lc = $cand.ToLower()
        $dist = _Get-Levenshtein $needle $lc
        $isContains = ($lc.Contains($needle) -or $needle.Contains($lc))
        # Boost contains matches by treating them as distance 1 if shorter
        $score = if ($isContains) { [Math]::Min($dist, 2) } else { $dist }
        $scored += [pscustomobject]@{ Name = $cand; Score = $score }
    }
    $maxDist = [Math]::Max(2, [int]([Math]::Ceiling($needle.Length / 2)))
    $suggestions = @($scored | Where-Object { $_.Score -le $maxDist } | Sort-Object Score, Name | Select-Object -First 3 | ForEach-Object { $_.Name })

    # Known-newer registry lookup (data-driven, off-disk so it's easy to extend)
    $knownPath = Join-Path $scriptDir "known-newer-profiles.json"
    $knownInfo = $null
    if (Test-Path -LiteralPath $knownPath) {
        try {
            $kobj = Get-Content -LiteralPath $knownPath -Raw | ConvertFrom-Json
            $hasEntry = $kobj -and $kobj.profiles -and ($kobj.profiles.PSObject.Properties.Name -contains $resolvedName)
            if ($hasEntry) { $knownInfo = $kobj.profiles.$resolvedName }
        } catch { }
    }

    # ---- Render ----------------------------------------------------------
    $msg = $logMessages.messages.profileNotFound -replace '\{name\}', $Action
    Write-Host ""
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host $msg

    $verLine = $logMessages.messages.profileNotFoundLocalVersion `
        -replace '\{version\}', $localVer `
        -replace '\{configPath\}', $configPath
    Write-Host ("  " + $verLine) -ForegroundColor DarkGray

    if ($suggestions.Count -gt 0) {
        $sugLine = $logMessages.messages.profileNotFoundDidYouMean `
            -replace '\{suggestions\}', ($suggestions -join ', ')
        Write-Host ""
        Write-Host ("  " + $sugLine) -ForegroundColor Yellow
    }

    if ($knownInfo) {
        $addedIn = if ($knownInfo.PSObject.Properties.Name -contains 'addedIn') { "v$($knownInfo.addedIn)" } else { "a newer release" }
        $newerLine = $logMessages.messages.profileNotFoundKnownNewer `
            -replace '\{name\}', $resolvedName `
            -replace '\{addedIn\}', $addedIn
        Write-Host ""
        Write-Host ("  " + $newerLine) -ForegroundColor Magenta
        if ($knownInfo.PSObject.Properties.Name -contains 'summary' -and $knownInfo.summary) {
            Write-Host ("    summary: " + $knownInfo.summary) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host ("  " + $logMessages.messages.profileNotFoundUpdateHint) -ForegroundColor Yellow
        $gitHint = $logMessages.messages.profileNotFoundGitHint -replace '\{root\}', $rootDir
        Write-Host ("  " + $gitHint) -ForegroundColor White
        Write-Host ("  " + $logMessages.messages.profileNotFoundReinstallHint) -ForegroundColor White
    }

    Show-ProfileList -Config $config
    exit 2
}

# Initialize logging
Initialize-Logging -ScriptName "Profile: $resolvedName"

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Profile dispatcher: $resolvedName" `
    -Action "Dispatch" `
    -Source "$scriptDir\config.json (profile catalog)" `
    -Temp   ($env:TEMP + "\scripts-fixer\profile") `
    -Target "varies per profile (forwards to scripts/01..65)"

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
