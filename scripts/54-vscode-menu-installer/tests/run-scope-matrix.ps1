# --------------------------------------------------------------------------
#  Script 54 -- tests/run-scope-matrix.ps1
#
#  MUTATING test matrix for the per-user vs per-machine scope plumbing.
#  Walks the full install -> verify -> uninstall -> verify cycle once for
#  -Scope CurrentUser and once for -Scope AllUsers, and asserts that the
#  registry ends up exactly where each scope is supposed to write.
#
#  This is intentionally SEPARATE from tests\run-tests.ps1, which is a
#  read-only state-validation harness. This file performs real registry
#  writes -- it is meant to be run interactively or in a sandboxed
#  Windows VM, not on a production box.
#
#  Per-scope expectations:
#
#    -Scope CurrentUser
#      * install   -> every registryPaths.<target> rewritten to
#                     Registry::HKEY_CURRENT_USER\Software\Classes\... must EXIST
#      * the original Registry::HKEY_CLASSES_ROOT\... key must NOT have been
#                     created in HKLM by us (we snapshot the HKLM path before
#                     the run; if it did not exist before, it must still not
#                     exist after install, AND must still not exist after
#                     uninstall)
#      * uninstall -> all CurrentUser paths must be GONE
#
#    -Scope AllUsers     (skipped cleanly when the harness is not elevated)
#      * install   -> every original Registry::HKEY_CLASSES_ROOT\... path
#                     must EXIST (physically lives in HKLM\Software\Classes)
#      * the per-user paths under HKCU\Software\Classes must NOT have been
#                     created (snapshot + post-install equivalence check)
#      * uninstall -> all AllUsers paths must be GONE
#
#  Usage:
#    .\run-scope-matrix.ps1                           # both scopes; AllUsers skipped if not admin
#    .\run-scope-matrix.ps1 -OnlyScope CurrentUser    # one scope
#    .\run-scope-matrix.ps1 -Edition stable           # one edition
#    .\run-scope-matrix.ps1 -KeepGoing                # don't bail on first install failure
#    .\run-scope-matrix.ps1 -NoColor                  # CI / log-friendly
#    .\run-scope-matrix.ps1 -WhatIf                   # dry-run: print plan, change nothing
#
#  Exit codes (granular -- callers can act on the specific failure mode):
#    0  -- all scopes green
#    2  -- pre-flight failed (config missing, no enabled editions, install.ps1 not found, ...)
#    3  -- AllUsers requested but harness not elevated and -OnlyScope AllUsers (hard fail)
#    10 -- CurrentUser scope: post-install verification failed
#    11 -- CurrentUser scope: post-uninstall verification failed (residue)
#    12 -- CurrentUser scope: cross-hive bleed (HKLM key created when it shouldn't be)
#    20 -- AllUsers scope:    post-install verification failed
#    21 -- AllUsers scope:    post-uninstall verification failed (residue)
#    22 -- AllUsers scope:    cross-hive bleed (HKCU key created when it shouldn't be)
#    30 -- both scopes had failures
# --------------------------------------------------------------------------
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]                                $Edition       = "",
    [ValidateSet('Both','CurrentUser','AllUsers')]
    [string]                                $OnlyScope     = 'Both',
    [switch]                                $KeepGoing,
    [switch]                                $NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Locate sibling scripts -------------------------------------------------
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$installerDir = Split-Path -Parent $scriptDir
$configPath   = Join-Path $installerDir "config.json"
$installPs1   = Join-Path $installerDir "install.ps1"
$uninstallPs1 = Join-Path $installerDir "uninstall.ps1"
$installHelp  = Join-Path $installerDir "helpers\vscode-install.ps1"

# Pre-flight: make every dependency missing failure log the EXACT path
# so the operator does not have to guess.
function Test-RequiredFile {
    param([string]$Path, [string]$Role)
    if (Test-Path -LiteralPath $Path) { return $true }
    Write-Host "FATAL: required $Role not found at: $Path  (failure: cannot continue)" -ForegroundColor Red
    return $false
}

$preflightOk = $true
foreach ($pair in @(
    @{ p = $configPath;   r = 'config.json'                 },
    @{ p = $installPs1;   r = 'install.ps1'                 },
    @{ p = $uninstallPs1; r = 'uninstall.ps1'               },
    @{ p = $installHelp;  r = 'helpers\vscode-install.ps1'  }
)) {
    if (-not (Test-RequiredFile $pair.p $pair.r)) { $preflightOk = $false }
}
if (-not $preflightOk) { exit 2 }

# Source Convert-EditionPathsForScope so the harness rewrites paths the
# same way the production code does -- a divergent re-implementation here
# would silently mask real scope-routing bugs.
. $installHelp

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

$editionsToTest = if ([string]::IsNullOrWhiteSpace($Edition)) {
    @($config.enabledEditions)
} else { @($Edition) }

if ($editionsToTest.Count -eq 0) {
    Write-Host "FATAL: no editions to test (config.enabledEditions is empty and -Edition not supplied)" -ForegroundColor Red
    exit 2
}

# ---- Output helpers ---------------------------------------------------------
function Write-C {
    param([string]$Text, [string]$Color = "White")
    if ($NoColor) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}

# Per-scope tally so the granular exit-code map can pick the right code.
$script:scopeStatus = @{
    CurrentUser = [ordered]@{ ran=$false; installFail=$false; uninstallFail=$false; bleedFail=$false; reasons=@() }
    AllUsers    = [ordered]@{ ran=$false; installFail=$false; uninstallFail=$false; bleedFail=$false; reasons=@() }
}

function Add-ScopeFail {
    param(
        [Parameter(Mandatory)] [ValidateSet('CurrentUser','AllUsers')] [string] $Scope,
        [Parameter(Mandatory)] [ValidateSet('install','uninstall','bleed')]     [string] $Phase,
        [Parameter(Mandatory)] [string] $Reason
    )
    switch ($Phase) {
        'install'   { $script:scopeStatus[$Scope].installFail   = $true }
        'uninstall' { $script:scopeStatus[$Scope].uninstallFail = $true }
        'bleed'     { $script:scopeStatus[$Scope].bleedFail     = $true }
    }
    $script:scopeStatus[$Scope].reasons += "[$Phase] $Reason"
}

# ---- Admin check (mirrors production code) ----------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---- Decide which scopes will actually run ---------------------------------
$scopesPlanned = switch ($OnlyScope) {
    'CurrentUser' { @('CurrentUser') }
    'AllUsers'    { @('AllUsers') }
    'Both'        { @('CurrentUser','AllUsers') }
}

# Hard-fail if the operator explicitly asked for AllUsers but isn't elevated.
if ($OnlyScope -eq 'AllUsers' -and -not $isAdmin) {
    Write-C "FATAL: -OnlyScope AllUsers requires admin elevation. Re-run from an elevated PowerShell." "Red"
    exit 3
}

# ---- Banner -----------------------------------------------------------------
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " VS Code Menu Installer (54) -- scope matrix (mutating!)"          "DarkCyan"
Write-C "================================================================" "DarkCyan"
Write-C "  Editions    : $($editionsToTest -join ', ')"
Write-C "  Scopes      : $($scopesPlanned -join ', ')"
Write-C "  Admin       : $isAdmin"
if ($WhatIfPreference) { Write-C "  Mode        : DRY-RUN (-WhatIf) -- no real registry writes" "Yellow" }
Write-C ""

# ---- Helpers: path enumeration per scope ------------------------------------
# Returns the list of fully-qualified PsPaths the install/uninstall would
# touch for one edition under one scope. Uses Convert-EditionPathsForScope
# so this matches production rewriting bit-for-bit.
function Get-ExpectedPathsForScope {
    param(
        [Parameter(Mandatory)] $EditionConfig,
        [Parameter(Mandatory)] [ValidateSet('CurrentUser','AllUsers')] [string] $Scope
    )
    $rewritten = Convert-EditionPathsForScope -EditionConfig $EditionConfig -Scope $Scope
    $out = @()
    foreach ($t in @('file','directory','background')) {
        $hasT = $rewritten.registryPaths.PSObject.Properties.Name -contains $t
        if (-not $hasT) { continue }
        $p = $rewritten.registryPaths.$t
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $out += [pscustomobject]@{ Target = $t; PsPath = $p }
    }
    return ,$out
}

# Snapshots presence of a list of PsPaths into a hashtable PsPath -> bool.
# Used so we can prove that the OPPOSITE hive was not touched by an op.
function Get-PresenceSnapshot {
    param([Parameter(Mandatory)] [object[]] $Paths)
    $snap = @{}
    foreach ($row in $Paths) {
        $snap[$row.PsPath] = [bool](Test-Path -LiteralPath $row.PsPath)
    }
    return $snap
}

# Compares a fresh snapshot against a baseline. Returns the list of paths
# that newly came into existence (i.e. our run created something in a hive
# we did not target). Strict allow-list: we never enumerate -- only re-probe
# the exact paths in $Baseline.
function Get-NewlyCreatedPaths {
    param(
        [Parameter(Mandatory)] [hashtable] $Baseline,
        [Parameter(Mandatory)] [hashtable] $After
    )
    $out = @()
    foreach ($k in $Baseline.Keys) {
        $wasThere   = [bool]$Baseline[$k]
        $isThereNow = [bool]$After[$k]
        if ((-not $wasThere) -and $isThereNow) { $out += $k }
    }
    return ,$out
}

# Pretty-print a list of PsPaths.
function Write-PathList {
    param([Parameter(Mandatory)] [object[]] $Paths, [string]$Indent = "      ")
    foreach ($p in $Paths) {
        if ($p -is [string]) { Write-C "$Indent$p" "DarkGray" }
        else                 { Write-C "$Indent[$($p.Target)] $($p.PsPath)" "DarkGray" }
    }
}

# ---- The actual scope test --------------------------------------------------
function Invoke-ScopeCase {
    param(
        [Parameter(Mandatory)] [ValidateSet('CurrentUser','AllUsers')] [string] $Scope,
        [Parameter(Mandatory)] [string] $EditionName
    )

    Write-C ""
    Write-C "----------------------------------------------------------------" "DarkGray"
    Write-C " Scope: $Scope    Edition: $EditionName"                           "White"
    Write-C "----------------------------------------------------------------" "DarkGray"

    $script:scopeStatus[$Scope].ran = $true

    $editionCfg = $config.editions.$EditionName
    if ($null -eq $editionCfg) {
        Add-ScopeFail -Scope $Scope -Phase install -Reason "edition '$EditionName' not present in config.editions"
        Write-C "  [FAIL] edition '$EditionName' not in config.editions" "Red"
        return
    }

    # Paths the OPPOSITE scope would have used. We need a baseline snapshot
    # so we can prove the install did not bleed into the wrong hive.
    $oppositeScope = if ($Scope -eq 'CurrentUser') { 'AllUsers' } else { 'CurrentUser' }
    $expected      = Get-ExpectedPathsForScope -EditionConfig $editionCfg -Scope $Scope
    $oppositePaths = Get-ExpectedPathsForScope -EditionConfig $editionCfg -Scope $oppositeScope

    Write-C "  Expected paths (this scope):" "DarkCyan"
    Write-PathList $expected
    Write-C "  Cross-hive watch list (must NOT be created here):" "DarkCyan"
    Write-PathList $oppositePaths

    # ---- Snapshot ----------------------------------------------------------
    $oppositeBaseline = Get-PresenceSnapshot -Paths $oppositePaths

    # ---- INSTALL -----------------------------------------------------------
    Write-C ""
    Write-C "  >> install -Scope $Scope -Edition $EditionName" "Cyan"
    if ($PSCmdlet.ShouldProcess("install.ps1 -Scope $Scope -Edition $EditionName", "run installer")) {
        try {
            & $installPs1 -Edition $EditionName -Scope $Scope | Out-Host
            $installRc = $LASTEXITCODE
        } catch {
            $installRc = 1
            Write-C "  [FAIL] install threw: $($_.Exception.Message) (failure: install.ps1 raised exception)" "Red"
        }
        if ($installRc -ne 0 -and $null -ne $installRc) {
            Add-ScopeFail -Scope $Scope -Phase install -Reason "install.ps1 exit code $installRc"
            Write-C "  [FAIL] install.ps1 exited with code $installRc" "Red"
            if (-not $KeepGoing) { return }
        }
    }

    # ---- VERIFY: target paths must exist -----------------------------------
    $missingAfterInstall = @()
    foreach ($row in $expected) {
        $isPresent = Test-Path -LiteralPath $row.PsPath
        if ($isPresent) {
            Write-C "    [PASS] present: $($row.PsPath)" "Green"
        } else {
            Write-C "    [FAIL] MISSING: $($row.PsPath) (failure: install did not create the expected key)" "Red"
            $missingAfterInstall += $row.PsPath
        }
    }
    if ($missingAfterInstall.Count -gt 0) {
        Add-ScopeFail -Scope $Scope -Phase install -Reason ("missing after install: " + ($missingAfterInstall -join '; '))
    }

    # ---- VERIFY: opposite hive must NOT have new keys ----------------------
    $oppositeAfterInstall = Get-PresenceSnapshot -Paths $oppositePaths
    $bleedAfterInstall    = Get-NewlyCreatedPaths -Baseline $oppositeBaseline -After $oppositeAfterInstall
    if ($bleedAfterInstall.Count -eq 0) {
        Write-C "    [PASS] no cross-hive bleed after install ($oppositeScope hive untouched)" "Green"
    } else {
        foreach ($p in $bleedAfterInstall) {
            Write-C "    [FAIL] BLEED: install created '$p' in $oppositeScope hive (failure: scope routing leak)" "Red"
        }
        Add-ScopeFail -Scope $Scope -Phase bleed -Reason ("install created keys in $oppositeScope hive: " + ($bleedAfterInstall -join '; '))
    }

    # ---- UNINSTALL ---------------------------------------------------------
    Write-C ""
    Write-C "  >> uninstall -Scope $Scope -Edition $EditionName" "Cyan"
    if ($PSCmdlet.ShouldProcess("uninstall.ps1 -Scope $Scope -Edition $EditionName", "run uninstaller")) {
        try {
            & $uninstallPs1 -Edition $EditionName -Scope $Scope | Out-Host
            $uninstallRc = $LASTEXITCODE
        } catch {
            $uninstallRc = 1
            Write-C "  [FAIL] uninstall threw: $($_.Exception.Message) (failure: uninstall.ps1 raised exception)" "Red"
        }
        if ($uninstallRc -ne 0 -and $null -ne $uninstallRc) {
            Add-ScopeFail -Scope $Scope -Phase uninstall -Reason "uninstall.ps1 exit code $uninstallRc"
            Write-C "  [FAIL] uninstall.ps1 exited with code $uninstallRc" "Red"
        }
    }

    # ---- VERIFY: target paths must be GONE ---------------------------------
    $stillThere = @()
    foreach ($row in $expected) {
        $isPresent = Test-Path -LiteralPath $row.PsPath
        if (-not $isPresent) {
            Write-C "    [PASS] removed: $($row.PsPath)" "Green"
        } else {
            Write-C "    [FAIL] RESIDUE: $($row.PsPath) (failure: uninstall left the key behind)" "Red"
            $stillThere += $row.PsPath
        }
    }
    if ($stillThere.Count -gt 0) {
        Add-ScopeFail -Scope $Scope -Phase uninstall -Reason ("residue after uninstall: " + ($stillThere -join '; '))
    }

    # ---- VERIFY: opposite hive STILL untouched (no late bleed) -------------
    $oppositeAfterUninstall = Get-PresenceSnapshot -Paths $oppositePaths
    $bleedAfterUninstall    = Get-NewlyCreatedPaths -Baseline $oppositeBaseline -After $oppositeAfterUninstall
    if ($bleedAfterUninstall.Count -eq 0) {
        Write-C "    [PASS] no cross-hive bleed after uninstall ($oppositeScope hive untouched)" "Green"
    } else {
        foreach ($p in $bleedAfterUninstall) {
            Write-C "    [FAIL] BLEED (post-uninstall): '$p' was created in $oppositeScope hive (failure: scope routing leak)" "Red"
        }
        Add-ScopeFail -Scope $Scope -Phase bleed -Reason ("post-uninstall keys in $oppositeScope hive: " + ($bleedAfterUninstall -join '; '))
    }
}

# ---- Drive the matrix -------------------------------------------------------
foreach ($scope in $scopesPlanned) {
    if ($scope -eq 'AllUsers' -and -not $isAdmin) {
        Write-C ""
        Write-C "[SKIP] -Scope AllUsers requires admin elevation -- skipping (re-run elevated to cover it)." "Yellow"
        continue
    }
    foreach ($ed in $editionsToTest) {
        Invoke-ScopeCase -Scope $scope -EditionName $ed
    }
}

# ---- Summary + granular exit code ------------------------------------------
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " Scope-matrix summary"                                              "DarkCyan"
Write-C "================================================================" "DarkCyan"

$cuStat = $script:scopeStatus.CurrentUser
$auStat = $script:scopeStatus.AllUsers

function Write-ScopeSummary {
    param([string]$Name, $Stat)
    if (-not $Stat.ran) {
        Write-C ("  {0,-12} : {1}" -f $Name, "(skipped)") "Yellow"
        return
    }
    $hasFail = $Stat.installFail -or $Stat.uninstallFail -or $Stat.bleedFail
    if (-not $hasFail) {
        Write-C ("  {0,-12} : PASS" -f $Name) "Green"
    } else {
        Write-C ("  {0,-12} : FAIL" -f $Name) "Red"
        foreach ($r in $Stat.reasons) { Write-C "                 - $r" "DarkGray" }
    }
}

Write-ScopeSummary "CurrentUser" $cuStat
Write-ScopeSummary "AllUsers"    $auStat

# Pick the granular exit code per the contract in the file header.
$cuFailed = $cuStat.ran -and ($cuStat.installFail -or $cuStat.uninstallFail -or $cuStat.bleedFail)
$auFailed = $auStat.ran -and ($auStat.installFail -or $auStat.uninstallFail -or $auStat.bleedFail)

if ($cuFailed -and $auFailed) { exit 30 }

if ($cuFailed) {
    if ($cuStat.bleedFail)             { exit 12 }
    elseif ($cuStat.installFail)       { exit 10 }
    else                               { exit 11 }   # uninstall residue
}
if ($auFailed) {
    if ($auStat.bleedFail)             { exit 22 }
    elseif ($auStat.installFail)       { exit 20 }
    else                               { exit 21 }
}

Write-C ""
Write-C "All scope cases passed." "Green"
exit 0