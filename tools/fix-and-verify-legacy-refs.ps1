# --------------------------------------------------------------------------
#  fix-and-verify-legacy-refs.ps1
#  One-command pipeline:
#    1. Dry-run the fixer to PREVIEW what would change
#    2. APPLY the rewrite (scripts-fixer-v12/v9/v10 -> v11) with timestamped
#       backups under .legacy-fix-backups\<UTC-timestamp>\
#    3. Run the scanner; if it FAILS, AUTO-ROLLBACK from the backup so the
#       repo is restored to its pre-apply state.
#
#  Usage:
#    .\tools\fix-and-verify-legacy-refs.ps1
#    .\tools\fix-and-verify-legacy-refs.ps1 -SkipApply        # preview + scan only
#    .\tools\fix-and-verify-legacy-refs.ps1 -NoBackup         # disable backups
#    .\tools\fix-and-verify-legacy-refs.ps1 -NoRollback       # keep changes on FAIL
#    .\tools\fix-and-verify-legacy-refs.ps1 -ReportFile r.json
#
#  Exit codes:
#    0 = dry-run + apply succeeded AND scanner reports PASS
#    1 = post-apply scanner reports FAIL (auto-rollback was attempted unless
#        -NoRollback / -NoBackup; rollback success/failure is logged either way)
#    2 = error in dry-run, apply, or rollback step
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch] $SkipApply,
    [switch] $NoBackup,
    [switch] $NoRollback,
    [string] $ReportFile  = 'legacy-fix-report.json',
    [string] $BackupRoot  = '.legacy-fix-backups'
)

$ErrorActionPreference = 'Stop'

function Write-Step ($t) { Write-Host "`n== $t ==" -ForegroundColor Magenta }
function Write-Info ($m) { Write-Host "[info ] $m" -ForegroundColor Cyan }
function Write-OkMsg($m) { Write-Host "[ ok  ] $m" -ForegroundColor Green }
function Write-Warn1($m) { Write-Host "[warn ] $m" -ForegroundColor Yellow }
function Write-Fail1($m) { Write-Host "[fail ] $m" -ForegroundColor Red }
function Write-FileError($p, $r) { Write-Host "[fail ] file=$p reason=$r" -ForegroundColor Red }

$scriptDir = $PSScriptRoot
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..')).Path
$fixer     = Join-Path $scriptDir 'fix-legacy-fixer-refs.ps1'
$scanner   = Join-Path $scriptDir 'scan-legacy-fixer-refs.ps1'

foreach ($p in @($fixer, $scanner)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-FileError $p 'required script missing'
        exit 2
    }
}

# Stable backup stamp shared across this whole pipeline run.
$backupStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$backupBase  = if ([System.IO.Path]::IsPathRooted($BackupRoot)) { $BackupRoot } else { Join-Path $repoRoot $BackupRoot }
$backupDir   = Join-Path $backupBase $backupStamp

# --- Step 1: dry-run preview ----------------------------------------------
Write-Step 'Step 1/3  dry-run preview'
Write-Info "running: $fixer -DryRun -ReportFile $ReportFile"
& $fixer -DryRun -ReportFile $ReportFile
$dryExit = $LASTEXITCODE
if ($dryExit -ne 0) {
    Write-Fail1 "dry-run preview failed (exit $dryExit) -- aborting before any writes"
    exit 2
}
Write-OkMsg 'dry-run preview completed cleanly'

# --- Step 2: apply (skippable, with backups by default) -------------------
$applyRan = $false
if ($SkipApply) {
    Write-Step 'Step 2/3  apply  (SKIPPED via -SkipApply)'
    Write-Warn1 'skipping apply step -- repo will not be modified'
} else {
    if ($NoBackup) {
        Write-Step 'Step 2/3  apply rewrite  (NO BACKUP -- rollback disabled)'
        Write-Warn1 '-NoBackup -- post-apply rollback will NOT be possible'
        & $fixer -ReportFile $ReportFile
    } else {
        Write-Step "Step 2/3  apply rewrite  (with backups -> $backupDir)"
        Write-Info "running: $fixer -Backup -BackupRoot $BackupRoot -BackupStamp $backupStamp -ReportFile $ReportFile"
        & $fixer -Backup -BackupRoot $BackupRoot -BackupStamp $backupStamp -ReportFile $ReportFile
    }
    $applyExit = $LASTEXITCODE
    if ($applyExit -ne 0) {
        Write-Fail1 "apply step failed (exit $applyExit) -- see logs above for exact file + reason"
        exit 2
    }
    $applyRan = $true
    Write-OkMsg 'apply step completed'
}

# --- Step 3: scanner verdict (gates exit code, triggers rollback) ---------
Write-Step 'Step 3/3  post-apply scanner (PASS required)'
Write-Info "running: $scanner"
& $scanner
$scanExit = $LASTEXITCODE
if ($scanExit -eq 0) {
    Write-OkMsg 'scanner reports PASS -- repo is clean'
    # Remove the backup directory if it ended up empty (no files rewritten).
    if ((Test-Path -LiteralPath $backupDir) -and -not (Get-ChildItem -LiteralPath $backupDir -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -LiteralPath $backupDir -Force -ErrorAction Stop
            $parent = Split-Path -Parent $backupDir
            if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    exit 0
}
if ($scanExit -ne 1) {
    Write-Fail1 "scanner errored (exit $scanExit)"
    exit 2
}

Write-Fail1 'scanner reports FAIL -- legacy scripts-fixer-v12/v9/v10 references still present'

# Decide whether to roll back.
$canRollback = $true
if (-not $applyRan)               { $canRollback = $false }
if ($NoBackup)                    { $canRollback = $false }
if ($NoRollback)                  { $canRollback = $false }
if (-not (Test-Path -LiteralPath $backupDir)) { $canRollback = $false }

if (-not $canRollback) {
    if ($NoRollback)     { Write-Warn1 '-NoRollback -- leaving rewritten files in place' }
    elseif ($NoBackup)   { Write-Warn1 'no backup was taken (-NoBackup) -- cannot auto-rollback' }
    elseif (-not $applyRan) { Write-Warn1 'apply step was skipped -- nothing to roll back' }
    else { Write-FileError $backupDir 'backup directory not found -- cannot auto-rollback' }
    exit 1
}

# --- Auto-rollback: copy every backed-up file back over its original ------
Write-Step "Auto-rollback from $backupDir"
$restoreCount  = 0
$restoreErrors = 0
$backupFiles = Get-ChildItem -LiteralPath $backupDir -Recurse -File -Force -ErrorAction SilentlyContinue
foreach ($bf in $backupFiles) {
    $rel  = $bf.FullName.Substring($backupDir.Length).TrimStart('\','/')
    $dest = Join-Path $repoRoot $rel
    $ddir = Split-Path -Parent $dest
    try {
        if ($ddir -and -not (Test-Path -LiteralPath $ddir)) {
            New-Item -ItemType Directory -Path $ddir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $bf.FullName -Destination $dest -Force -ErrorAction Stop
        $restoreCount++
    } catch {
        Write-FileError $dest "restore copy failed (backup: $($bf.FullName)): $($_.Exception.Message)"
        $restoreErrors++
    }
}

if ($restoreErrors -gt 0) {
    Write-Fail1 "rollback completed with $restoreErrors error(s); $restoreCount file(s) restored"
    Write-Fail1 "backup retained at: $backupDir"
    exit 2
}

Write-OkMsg "rollback restored $restoreCount file(s) from $backupDir"
Write-Warn1 'scanner FAILed -- repo is back to its pre-apply state. Investigate before retrying.'
exit 1
