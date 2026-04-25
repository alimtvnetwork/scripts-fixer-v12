# --------------------------------------------------------------------------
#  Script 10 -- tests/smoke-install-check.ps1
#
#  Smoke test: runs `install` then `check` back-to-back and asserts the
#  registry ends up in the expected state for BOTH folder + file context
#  menu cases.
#
#  What it covers (per enabled edition in config.json):
#
#    1. install verb exits 0.
#    2. check  verb exits 0 (green): folder+background entries present with
#       correct (Default) label, Icon, and \command; file-target ABSENT;
#       no suppression values; no legacy duplicates.
#    3. -ExitCodeMap returns 0 (i.e. no specific failure bucket).
#
#  Optional negative case (-IncludeFileTargetNegativeCase):
#    4. Manually re-create HKCR\*\shell\<Name> (the file-target key),
#       then run check -ExitCodeMap and assert exit code 20 (file-target
#       still present).
#    5. Run repair -Edition <name>, then check again and assert exit 0.
#
#  Usage:
#    .\smoke-install-check.ps1                           # all enabled editions, no negative case
#    .\smoke-install-check.ps1 -Edition stable           # one edition
#    .\smoke-install-check.ps1 -IncludeFileTargetNegativeCase
#    .\smoke-install-check.ps1 -SkipInstall              # assume install already ran
#    .\smoke-install-check.ps1 -DryRun                   # print plan only, no registry writes
#    .\smoke-install-check.ps1 -NoColor                  # CI-friendly output
#
#  Exit codes:
#    0 -- all assertions passed
#    1 -- at least one assertion failed
#    2 -- pre-flight failed (config missing, not admin, etc.)
#
#  Requires Administrator (install + repair write to HKCR). The check verb
#  itself is read-only, but the smoke wrapper is a write test by design.
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string] $Edition = "",
    [switch] $IncludeFileTargetNegativeCase,
    [switch] $SkipInstall,
    [switch] $DryRun,
    [switch] $NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$installerDir = Split-Path -Parent $scriptDir
$runScript    = Join-Path $installerDir "run.ps1"
$configPath   = Join-Path $installerDir "config.json"

# ---- Output helpers --------------------------------------------------------
function Write-C {
    param([string]$Text, [string]$Color = "White")
    if ($NoColor) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}

$script:passN   = 0
$script:failN   = 0
$script:results = @()

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:passN++
        $script:results += [pscustomobject]@{ Name=$Name; Status='PASS'; Detail=$Detail }
        Write-C "    [PASS] $Name" "Green"
    } else {
        $script:failN++
        $script:results += [pscustomobject]@{ Name=$Name; Status='FAIL'; Detail=$Detail }
        Write-C "    [FAIL] $Name" "Red"
        if ($Detail) { Write-C "           $Detail" "DarkGray" }
    }
}

# ---- Pre-flight ------------------------------------------------------------
$isRunMissing = -not (Test-Path -LiteralPath $runScript)
if ($isRunMissing) {
    Write-Host "FATAL: run.ps1 not found at: $runScript (failure: cannot drive smoke test without entry point)" -ForegroundColor Red
    exit 2
}
$isConfigMissing = -not (Test-Path -LiteralPath $configPath)
if ($isConfigMissing) {
    Write-Host "FATAL: config.json not found at: $configPath (failure: cannot read enabledEditions)" -ForegroundColor Red
    exit 2
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ((-not $isAdmin) -and (-not $DryRun)) {
    Write-Host "FATAL: smoke test must run as Administrator (install + repair write to HKEY_CLASSES_ROOT). Re-launch PowerShell with 'Run as administrator' or pass -DryRun to preview the plan." -ForegroundColor Red
    exit 2
}

$editions = @($config.enabledEditions)
$hasFilter = -not [string]::IsNullOrWhiteSpace($Edition)
if ($hasFilter) { $editions = $editions | Where-Object { $_ -ieq $Edition } }
if ($editions.Count -eq 0) {
    Write-Host "FATAL: no editions to test (Edition filter '$Edition' matched nothing in enabledEditions = $($config.enabledEditions -join ', '))" -ForegroundColor Red
    exit 2
}

# ---- Banner ----------------------------------------------------------------
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " Script 10 -- smoke test: install -> check"                       "DarkCyan"
Write-C "================================================================" "DarkCyan"
Write-C ("  editions             : " + ($editions -join ', '))             "Gray"
Write-C ("  IncludeNegativeCase  : " + [bool]$IncludeFileTargetNegativeCase) "Gray"
Write-C ("  SkipInstall          : " + [bool]$SkipInstall)                 "Gray"
Write-C ("  DryRun               : " + [bool]$DryRun)                      "Gray"
Write-C ""

if ($DryRun) {
    Write-C "DryRun mode -- would execute the following sequence:" "Yellow"
    if (-not $SkipInstall) { Write-C "  1. & '$runScript' install" "DarkGray" }
    Write-C "  2. & '$runScript' check -ExitCodeMap   (expect exit 0)"     "DarkGray"
    if ($IncludeFileTargetNegativeCase) {
        foreach ($e in $editions) {
            $fileReg = $config.editions.$e.registryPaths.file
            $fileExe = ($fileReg -replace '^Registry::', '')
            Write-C "  3. reg.exe add '$fileExe' /f                       (synthesize file-target for $e)"  "DarkGray"
            Write-C "  4. & '$runScript' check -ExitCodeMap -Edition $e   (expect exit 20)"                  "DarkGray"
            Write-C "  5. & '$runScript' repair -Edition $e               (cleanup)"                          "DarkGray"
            Write-C "  6. & '$runScript' check -ExitCodeMap -Edition $e   (expect exit 0)"                   "DarkGray"
        }
    }
    Write-C ""
    Write-C "DryRun complete. No registry writes performed." "Yellow"
    exit 0
}

# ---- Helper: invoke run.ps1 and capture exit code --------------------------
function Invoke-Run {
    param([Parameter(Mandatory)] [string[]] $Arguments, [string]$Label = "")
    if ($Label) { Write-C ("  > " + $Label) "DarkGray" }
    & $runScript @Arguments
    return $LASTEXITCODE
}

# ---- Step 1: install -------------------------------------------------------
if (-not $SkipInstall) {
    Write-C ""
    Write-C "Step 1 : install" "Cyan"
    $installArgs = @('install')
    if ($hasFilter) { $installArgs += @('-Edition', $Edition) }
    $installCode = Invoke-Run -Arguments $installArgs -Label ("run.ps1 " + ($installArgs -join ' '))
    Assert-True "install verb exits 0" ($installCode -eq 0) `
        "install exited $installCode (failure: see logs/10-vscode-context-menu-fix/<latest>.log for the failing edition/target and reg path)"
} else {
    Write-C ""
    Write-C "Step 1 : install -- SKIPPED (-SkipInstall)" "Yellow"
}

# ---- Step 2: check (expect exit 0 after a clean install) -------------------
Write-C ""
Write-C "Step 2 : check (expect exit 0 -- folder/background present, file-target absent, no suppression, no legacy)" "Cyan"
$checkArgs = @('check', '-ExitCodeMap')
if ($hasFilter) { $checkArgs += @('-Edition', $Edition) }
$checkCode = Invoke-Run -Arguments $checkArgs -Label ("run.ps1 " + ($checkArgs -join ' '))

Assert-True "check verb exits 0 after install (all invariants green)" ($checkCode -eq 0) `
    ("check exited $checkCode (failure: bucket legend -- 10=install-state, 20=file-target, 21=suppression, 22=legacy, 30=multi-invariant, 40=mixed; re-run check without -ExitCodeMap to see the per-MISS Path/Items/Why/Fix block)")

# ---- Step 3: optional negative case ---------------------------------------
if ($IncludeFileTargetNegativeCase) {
    Write-C ""
    Write-C "Step 3 : negative case -- synthesize HKCR\*\shell\<Name>, expect check exit 20" "Cyan"

    foreach ($edName in $editions) {
        $hasEd = $config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) {
            Write-C "  [skip] edition '$edName' not in config.editions" "Yellow"
            continue
        }
        $edCfg = $config.editions.$edName
        $hasFile = $edCfg.registryPaths.PSObject.Properties.Name -contains 'file'
        if (-not $hasFile) {
            Write-C "  [skip] edition '$edName' has no registryPaths.file entry" "Yellow"
            continue
        }
        $fileReg = $edCfg.registryPaths.file
        $fileExe = ($fileReg -replace '^Registry::', '')

        Write-C ("  Synthesizing file-target: " + $fileExe) "DarkGray"
        $null = reg.exe add $fileExe /f 2>&1
        $isAddOk = ($LASTEXITCODE -eq 0)
        Assert-True ("synthesize file-target for '$edName' succeeds (reg.exe add)") $isAddOk `
            ("reg.exe add exited $LASTEXITCODE for path: $fileExe (failure: cannot run negative case without writing the key)")
        if (-not $isAddOk) { continue }

        $negArgs = @('check', '-ExitCodeMap', '-Edition', $edName)
        $negCode = Invoke-Run -Arguments $negArgs -Label ("run.ps1 " + ($negArgs -join ' '))
        Assert-True ("check exits 20 (file-target present) for '$edName'") ($negCode -eq 20) `
            ("check exited $negCode for edition '$edName' (expected 20 = file-target STILL PRESENT). Path that should have triggered the miss: $fileExe")

        Write-C ("  Cleanup: repair -Edition " + $edName) "DarkGray"
        $repairCode = Invoke-Run -Arguments @('repair','-Edition',$edName) -Label ("run.ps1 repair -Edition " + $edName)
        Assert-True ("repair -Edition $edName exits 0") ($repairCode -eq 0) `
            ("repair exited $repairCode (failure: see logs/10-vscode-context-menu-fix/<latest>.log; manually inspect $fileExe with reg.exe query)")

        $finalCode = Invoke-Run -Arguments @('check','-ExitCodeMap','-Edition',$edName) -Label ("run.ps1 check -ExitCodeMap -Edition " + $edName)
        Assert-True ("check exits 0 after repair for '$edName'") ($finalCode -eq 0) `
            ("check exited $finalCode after repair (expected 0). The file-target at $fileExe should now be absent -- verify with: reg.exe query `"$fileExe`"")
    }
}

# ---- Summary --------------------------------------------------------------
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " Smoke summary"                                                    "DarkCyan"
Write-C "================================================================" "DarkCyan"
Write-C ("  PASS : " + $script:passN) "Green"
Write-C ("  FAIL : " + $script:failN) $(if ($script:failN -gt 0) { "Red" } else { "DarkGray" })
Write-C ""

if ($script:failN -gt 0) {
    Write-C "Failures:" "Red"
    $script:results | Where-Object Status -eq "FAIL" | ForEach-Object {
        Write-C ("  - " + $_.Name) "Red"
        if ($_.Detail) { Write-C ("      " + $_.Detail) "DarkGray" }
    }
    exit 1
}

Write-C "All smoke assertions passed." "Green"
exit 0