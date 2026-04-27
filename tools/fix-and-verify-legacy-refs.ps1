# --------------------------------------------------------------------------
#  fix-and-verify-legacy-refs.ps1
#  One-command pipeline:
#    1. Dry-run the fixer to PREVIEW what would change
#    2. APPLY the rewrite (scripts-fixer-v8/v9/v10 -> v11)
#    3. Run the scanner; FAIL the whole command unless it reports PASS
#
#  Usage:
#    .\tools\fix-and-verify-legacy-refs.ps1
#    .\tools\fix-and-verify-legacy-refs.ps1 -SkipApply       # preview + scan only
#    .\tools\fix-and-verify-legacy-refs.ps1 -ReportFile r.json
#
#  Exit codes:
#    0 = dry-run + apply succeeded AND scanner reports PASS
#    1 = post-apply scanner reports FAIL (legacy refs still present)
#    2 = error in dry-run or apply step (exact file/path + reason logged)
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch] $SkipApply,
    [string] $ReportFile = 'legacy-fix-report.json'
)

$ErrorActionPreference = 'Stop'

function Write-Step ($t) { Write-Host "`n== $t ==" -ForegroundColor Magenta }
function Write-Info ($m) { Write-Host "[info ] $m" -ForegroundColor Cyan }
function Write-OkMsg($m) { Write-Host "[ ok  ] $m" -ForegroundColor Green }
function Write-Warn1($m) { Write-Host "[warn ] $m" -ForegroundColor Yellow }
function Write-Fail1($m) { Write-Host "[fail ] $m" -ForegroundColor Red }
function Write-FileError($p, $r) { Write-Host "[fail ] file=$p reason=$r" -ForegroundColor Red }

$scriptDir = $PSScriptRoot
$fixer   = Join-Path $scriptDir 'fix-legacy-fixer-refs.ps1'
$scanner = Join-Path $scriptDir 'scan-legacy-fixer-refs.ps1'

foreach ($p in @($fixer, $scanner)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-FileError $p 'required script missing'
        exit 2
    }
}

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

# --- Step 2: apply (skippable) --------------------------------------------
if ($SkipApply) {
    Write-Step 'Step 2/3  apply  (SKIPPED via -SkipApply)'
    Write-Warn1 'skipping apply step -- repo will not be modified'
} else {
    Write-Step 'Step 2/3  apply rewrite'
    Write-Info "running: $fixer -ReportFile $ReportFile"
    & $fixer -ReportFile $ReportFile
    $applyExit = $LASTEXITCODE
    if ($applyExit -ne 0) {
        Write-Fail1 "apply step failed (exit $applyExit) -- see logs above for exact file + reason"
        exit 2
    }
    Write-OkMsg 'apply step completed'
}

# --- Step 3: scanner verdict (gates exit code) ----------------------------
Write-Step 'Step 3/3  post-apply scanner (PASS required)'
Write-Info "running: $scanner"
& $scanner
$scanExit = $LASTEXITCODE
if ($scanExit -eq 0) {
    Write-OkMsg 'scanner reports PASS -- repo is clean'
    exit 0
} elseif ($scanExit -eq 1) {
    Write-Fail1 'scanner reports FAIL -- legacy scripts-fixer-v8/v9/v10 references still present'
    exit 1
} else {
    Write-Fail1 "scanner errored (exit $scanExit)"
    exit 2
}
