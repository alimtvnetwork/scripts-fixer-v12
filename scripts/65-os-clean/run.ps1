<#
.SYNOPSIS
    65 os-clean -- Windows side of cross-OS cleanup.

.DESCRIPTION
    Thin dispatcher that wraps `scripts/os/run.ps1 clean` with the same
    plan -> confirm -> apply -> verify lifecycle the Linux/macOS side
    (scripts-linux/65-os-clean/run.sh) ships.

    Lifecycle:
      1. PLAN     -- invoke `os clean --dry-run` (with any --only/--skip/
                     --bucket flags the operator passed) and capture every
                     category that reports rows.
      2. CONFIRM  -- render the plan as a grouped table and prompt the
                     operator to type 'yes' to proceed. -Yes / --yes
                     auto-confirms (CI). Empty plan exits 0 silently.
      3. APPLY    -- invoke `os clean` for real. Exit code propagates.
      4. VERIFY   -- re-invoke `os clean --dry-run` and compare. Any
                     category that still reports rows is FAIL(n);
                     categories that drop to 0 are PASS.
      5. SUMMARY  -- per-category table mirroring the Linux 65 layout
                     (STATUS / CATEGORY / LABEL / ITEMS / VERIFIED) plus
                     a manifest.json under .logs/65/<TS>/.

    Pass --dry-run to do step 1 only (preview), with no prompt and no
    apply, and no verify. The Linux side behaves identically.

    CODE RED: every file/path failure is logged with exact path + reason.

.NOTES
    Pairs with: scripts-linux/65-os-clean/run.sh
    Delegates  to: scripts/os/run.ps1 clean (shipped since v0.48.0, 59 cats)
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Argv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ScriptsRoot = Split-Path -Parent $ScriptDir
$ProjectRoot = Split-Path -Parent $ScriptsRoot
$OsRunner    = Join-Path $ScriptsRoot "os\run.ps1"
$SharedDir   = Join-Path $ScriptsRoot "shared"

# ---- Sanity: the worker must exist (CODE-RED file error if missing). -----
if (-not (Test-Path -LiteralPath $OsRunner)) {
    Write-Host ("[FILE-ERROR] path={0} reason=delegate (scripts/os/run.ps1) not found; cannot dispatch" -f $OsRunner) -ForegroundColor Red
    exit 2
}

# Lightweight logger fallback (avoids hard dep on shared/logging.ps1 so a
# fresh checkout still runs). When shared logging is available we use it.
$loggingPath = Join-Path $SharedDir "logging.ps1"
if (Test-Path -LiteralPath $loggingPath) {
    . $loggingPath
    Initialize-Logging -ScriptName "65-os-clean" 2>$null | Out-Null
}

function Write-Stage {
    param([string]$Tag, [string]$Msg, [ConsoleColor]$Color = 'Cyan')
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host ("{0} [{1}] {2}" -f $ts, $Tag, $Msg) -ForegroundColor $Color
}
function Write-Ok    { Write-Stage 'OK   ' $args[0] 'Green' }
function Write-Info  { Write-Stage 'INFO ' $args[0] 'Cyan' }
function Write-Warn2 { Write-Stage 'WARN ' $args[0] 'Yellow' }
function Write-Err2  { Write-Stage 'ERROR' $args[0] 'Red' }
function Write-Step  { Write-Stage 'STEP ' $args[0] 'Magenta' }
function Write-FileErr {
    param([string]$Path, [string]$Reason)
    Write-Host ("[FILE-ERROR] path={0} reason={1}" -f $Path, $Reason) -ForegroundColor Red
}

# ---- Argv parsing (ours) ------------------------------------------------
$DryRun     = $false
$AssumeYes  = $false
$JsonOut    = $false
$ShowHelp   = $false
$Forwarded  = @()

foreach ($a in $Argv) {
    switch -Regex ("$a") {
        '^(--dry-run|-n|-DryRun)$'  { $DryRun     = $true; continue }
        '^(--yes|-y|-Yes)$'         { $AssumeYes  = $true; continue }
        '^(--json|-Json)$'          { $JsonOut    = $true; continue }
        '^(--help|-h|-Help|/\?)$'   { $ShowHelp   = $true; continue }
        default                     { $Forwarded += "$a" }
    }
}

if ($ShowHelp) {
    $msgs = $null
    $msgPath = Join-Path $ScriptDir "log-messages.json"
    if (Test-Path -LiteralPath $msgPath) {
        $msgs = Get-Content -LiteralPath $msgPath -Raw | ConvertFrom-Json
    } else {
        Write-FileErr $msgPath "log-messages.json missing"
    }
    Write-Host ""
    Write-Host "  65 os-clean -- Windows side" -ForegroundColor Cyan
    Write-Host "  ===========================" -ForegroundColor DarkGray
    if ($msgs -and $msgs.synopsis) { Write-Host ("  {0}" -f $msgs.synopsis) }
    Write-Host ""
    Write-Host "  Lifecycle:  plan -> confirm -> apply -> verify" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Flags:" -ForegroundColor Yellow
    Write-Host "    --dry-run, -n     Preview only (no apply, no prompt, no verify)."
    Write-Host "    --yes, -y         Auto-confirm; skip the plan prompt."
    Write-Host "    --json            Print a machine-readable summary instead of table."
    Write-Host "    --help, -h        Show this help."
    Write-Host ""
    Write-Host "  Forwarded to `os clean` (full list: .\run.ps1 os clean --help):" -ForegroundColor Yellow
    Write-Host "    --bucket A|B|C|D|E|F|G    Run only one bucket."
    Write-Host "    --only <a,b,c>            Run only listed categories."
    Write-Host "    --skip <a,b,c>            Skip listed categories."
    Write-Host "    --days <N>                Override age threshold for media subcommands."
    Write-Host ""
    if ($msgs -and $msgs.usage) {
        Write-Host "  Examples:" -ForegroundColor Yellow
        foreach ($u in $msgs.usage) { Write-Host ("    {0}" -f $u) -ForegroundColor Gray }
    }
    Write-Host ""
    exit 0
}

# ---- Per-run log dir -----------------------------------------------------
$Ts      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$LogsRoot = if ($env:LOGS_OVERRIDE) { $env:LOGS_OVERRIDE } else { Join-Path $ProjectRoot ".logs\65" }
$RunDir  = Join-Path $LogsRoot $Ts
try {
    [void](New-Item -ItemType Directory -Path $RunDir -Force -ErrorAction Stop)
} catch {
    Write-FileErr $RunDir ("New-Item failed: " + $_.Exception.Message)
    exit 2
}
$PlanPath    = Join-Path $RunDir "plan.txt"
$ApplyPath   = Join-Path $RunDir "apply.txt"
$VerifyPath  = Join-Path $RunDir "verify.txt"
$ManifestPath= Join-Path $RunDir "manifest.json"
$CommandPath = Join-Path $RunDir "command.txt"
try {
    ($Argv -join ' ') | Set-Content -LiteralPath $CommandPath -Encoding UTF8
} catch {
    Write-FileErr $CommandPath ("write failed: " + $_.Exception.Message)
}

# ---- Helper: invoke the os runner and capture combined output -----------
function Invoke-OsClean {
    param([string[]]$ExtraArgs, [string]$OutFile)
    $allArgs = @('clean') + $Forwarded + $ExtraArgs
    Write-Info ("delegating: pwsh `"{0}`" {1}" -f $OsRunner, ($allArgs -join ' '))
    # Capture all streams into the log file. We deliberately do NOT Tee
    # back to the pipeline because Tee-Object/Write-Host both emit
    # HostInformation records that contaminate the function return value.
    # Operator visibility is preserved by streaming the captured file
    # contents to the host AFTER capture, then returning a scalar int.
    $rc = 0
    try {
        & $OsRunner @allArgs *>&1 > $OutFile
        $rc = $LASTEXITCODE
        if ($null -eq $rc) { $rc = 0 }
    } catch {
        Write-Err2 ("delegate threw: " + $_.Exception.Message)
        $rc = 30
        $_.Exception.Message | Add-Content -LiteralPath $OutFile
    }
    # Stream captured output to the host so the operator sees progress.
    if (Test-Path -LiteralPath $OutFile) {
        Get-Content -LiteralPath $OutFile | ForEach-Object { Write-Host "    $_" }
    }
    # Force scalar int return -- prevents pipeline contamination upstream.
    return [int]$rc
}

# ---- Parse a captured `os clean` output into per-category row counts -----
# The os runner emits a per-category line like
#   "[ DELETE ] chrome  (count=12 bytes=3,408,221)"
# under dry-run. We extract category + count via regex. Lines that don't
# match are ignored. Returns an [ordered] hashtable category -> count.
function Parse-OsCleanRows {
    param([string]$LogFile)
    $rows = [ordered]@{}
    if (-not (Test-Path -LiteralPath $LogFile)) {
        Write-FileErr $LogFile "parse: capture file missing (delegate produced no output)"
        return $rows
    }
    # Two patterns: dry-run "[ WOULD ]" and apply "[ DELETE ]". Both follow
    # the same shape: "<verb> <category-id>  (count=N ..."
    $patternA = '^\s*\[\s*(WOULD|DELETE|KEEP|SKIP|FAIL)\s*\]\s+(?<cat>[a-z0-9][a-z0-9-]*)\b.*\bcount\s*=\s*(?<n>\d[\d,]*)'
    foreach ($line in Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue) {
        if ($line -match $patternA) {
            $cat = $matches['cat']
            $n   = [int](($matches['n']) -replace ',', '')
            if ($n -gt 0) {
                if ($rows.Contains($cat)) { $rows[$cat] = [int]$rows[$cat] + $n }
                else { $rows[$cat] = $n }
            }
        }
    }
    return $rows
}

# ========================== STAGE 1: PLAN ================================
Write-Step "[STAGE 1/4] PLAN -- building dry-run plan"
$planRc = Invoke-OsClean -ExtraArgs @('--dry-run') -OutFile $PlanPath
$planRows = Parse-OsCleanRows -LogFile $PlanPath
$planTotalCats  = $planRows.Keys.Count
$planTotalItems = ($planRows.Values | Measure-Object -Sum).Sum
if ($null -eq $planTotalItems) { $planTotalItems = 0 }

if ($planTotalCats -eq 0) {
    Write-Ok ("Plan is empty -- nothing queued (delegate rc={0}). Exiting." -f $planRc)
    if ($DryRun) { Write-Info "(--dry-run requested; nothing to preview either)" }
    exit 0
}

# Render plan
Write-Host ""
Write-Host ("  ===== PLAN ({0} categor{1}, {2} item{3}) =====" -f `
    $planTotalCats, ($(if ($planTotalCats -eq 1) { 'y' } else { 'ies' })), `
    $planTotalItems, ($(if ($planTotalItems -eq 1) { '' } else { 's' }))) -ForegroundColor Cyan
Write-Host ("  {0,-32}  {1,8}" -f 'CATEGORY', 'ITEMS')
Write-Host ("  " + ('-' * 44))
foreach ($k in $planRows.Keys) {
    Write-Host ("  {0,-32}  {1,8}" -f $k, $planRows[$k])
}
Write-Host ("  " + ('-' * 44))
Write-Host ("  TOTAL: {0} item(s) across {1} categor(ies)" -f $planTotalItems, $planTotalCats) -ForegroundColor Yellow
Write-Host ""

# ---- Dry-run short-circuit ----------------------------------------------
if ($DryRun) {
    Write-Info "[DRY-RUN] Preview only. No prompt, no apply, no verify."
    # Write a minimal manifest so dashboards still find the run dir.
    $m = [ordered]@{
        scriptId   = '65'
        platform   = 'windows'
        timestamp  = $Ts
        mode       = 'dry-run'
        delegate   = 'scripts/os/run.ps1 clean'
        plan       = [ordered]@{
            categories  = $planTotalCats
            items       = $planTotalItems
            rows        = $planRows
        }
        verification = $null
    }
    try {
        ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
        Write-Ok ("Manifest written: {0}" -f $ManifestPath)
    } catch {
        Write-FileErr $ManifestPath ("manifest write failed: " + $_.Exception.Message)
    }
    exit 0
}

# ========================== STAGE 2: CONFIRM =============================
Write-Step "[STAGE 2/4] CONFIRM"
if ($AssumeYes) {
    Write-Ok "Confirmation skipped: -Yes / --yes supplied."
} else {
    if (-not [Environment]::UserInteractive) {
        Write-Warn2 "Non-interactive session and --yes was not supplied."
        Write-Warn2 "Aborting to avoid an unattended destructive run."
        Write-Warn2 "Re-run with --yes for CI, or --dry-run for preview only."
        exit 1
    }
    $reply = Read-Host ("  Type 'yes' to apply {0} item(s) across {1} categor(ies), anything else to abort" -f $planTotalItems, $planTotalCats)
    if ($reply -notmatch '^(?i:y|yes)$') {
        Write-Warn2 ("Aborted by operator (reply='{0}'). No changes made." -f $reply)
        exit 1
    }
    Write-Ok "Confirmed -- proceeding with apply."
}

# ========================== STAGE 3: APPLY ===============================
Write-Step "[STAGE 3/4] APPLY"
# We forward --yes to the delegate so its own destructive-consent gates
# (recycle, ms-search, etc.) don't re-prompt for the categories we already
# confirmed at our level.
$applyExtras = @()
if ($AssumeYes -or $true) { $applyExtras += '--yes' }
$applyRc = Invoke-OsClean -ExtraArgs $applyExtras -OutFile $ApplyPath
Write-Info ("Apply finished (rc={0})." -f $applyRc)

# ========================== STAGE 4: VERIFY ==============================
Write-Step "[STAGE 4/4] VERIFY -- re-running dry-run to detect residue"
$verifyRc   = Invoke-OsClean -ExtraArgs @('--dry-run') -OutFile $VerifyPath
$verifyRows = Parse-OsCleanRows -LogFile $VerifyPath

$verification = [ordered]@{}
$verifyPass = 0
$verifyFail = 0
foreach ($cat in $planRows.Keys) {
    $before = [int]$planRows[$cat]
    $after  = if ($verifyRows.Contains($cat)) { [int]$verifyRows[$cat] } else { 0 }
    if ($after -eq 0) {
        $verification[$cat] = [ordered]@{ status='PASS'; before=$before; after=0 }
        $verifyPass++
    } else {
        $verification[$cat] = [ordered]@{ status='FAIL'; before=$before; after=$after }
        $verifyFail++
    }
}

# ========================== SUMMARY ======================================
Write-Host ""
Write-Host ("  ===== summary (apply rc={0}) =====" -f $applyRc) -ForegroundColor Cyan
Write-Host ("  {0,-7}  {1,-30}  {2,8}  {3,8}  {4,-12}" -f 'STATUS','CATEGORY','BEFORE','AFTER','VERIFIED')
Write-Host ("  " + ('-' * 80))
foreach ($cat in $planRows.Keys) {
    $v = $verification[$cat]
    $vmark = if ($v.status -eq 'PASS') { 'PASS' } else { ("FAIL({0})" -f $v.after) }
    $statColor = if ($v.status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-7}  {1,-30}  {2,8}  {3,8}  {4,-12}" -f `
        $v.status, $cat, $v.before, $v.after, $vmark) -ForegroundColor $statColor
}
Write-Host ("  " + ('-' * 80))
Write-Host ("  TOTAL: PASS={0}  FAIL={1}  CATEGORIES={2}" -f $verifyPass, $verifyFail, $planRows.Keys.Count) -ForegroundColor Yellow
Write-Host ""

# Write manifest.
$manifest = [ordered]@{
    scriptId    = '65'
    platform    = 'windows'
    timestamp   = $Ts
    mode        = 'apply'
    delegate    = 'scripts/os/run.ps1 clean'
    plan        = [ordered]@{ categories = $planTotalCats; items = $planTotalItems; rows = $planRows }
    apply       = [ordered]@{ exitCode = $applyRc }
    verification= [ordered]@{
        method  = 'rerun-dry-after-apply'
        rows    = $verification
        totals  = [ordered]@{ pass = $verifyPass; fail = $verifyFail; categories = $planRows.Keys.Count }
    }
}
try {
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    Write-Ok ("Manifest written: {0}" -f $ManifestPath)
} catch {
    Write-FileErr $ManifestPath ("manifest write failed: " + $_.Exception.Message)
}

if ($JsonOut) {
    # Re-emit a machine-readable line at the very end so CI greps catch it.
    $jsonSummary = [ordered]@{
        scriptId   = '65'
        applyRc    = $applyRc
        verifyPass = $verifyPass
        verifyFail = $verifyFail
        manifest   = $ManifestPath
    } | ConvertTo-Json -Depth 4 -Compress
    Write-Host $jsonSummary
}

# Exit code: non-zero if apply failed OR verification reported residue.
if ($applyRc -ne 0) { exit $applyRc }
if ($verifyFail -gt 0) { exit 11 }   # mirrors Linux 65 'CurrentUser post-uninstall residue' style
exit 0
