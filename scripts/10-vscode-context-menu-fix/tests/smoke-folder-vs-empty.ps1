# --------------------------------------------------------------------------
#  Script 10 -- tests/smoke-folder-vs-empty.ps1
#
#  Focused Windows smoke test for the FOLDER vs EMPTY-FOLDER context menu.
#
#  Background:
#    Two distinct shell verbs power "Open with Code" for directories:
#
#      * FOLDER  (right-click ON a folder in Explorer)
#          HKCR\Directory\shell\<Name>
#          %V resolves to the CLICKED folder's path
#
#      * EMPTY  (right-click in the EMPTY area of an open folder window)
#          HKCR\Directory\Background\shell\<Name>
#          %V resolves to the CURRENT folder shown in Explorer
#
#    Both must exist, both must point at the right exe with the right
#    quoted argument, both must show the configured label, and both must
#    have an Icon. If only one is wired the menu silently misbehaves --
#    folders work but empty-folder right-click does nothing (or vice
#    versa). This smoke test installs (or repairs) the menu, then checks
#    each invariant for BOTH targets per enabled edition.
#
#  What it does:
#    1. Drives `run.ps1 install` (or `repair` if -RepairOnly) once.
#    2. For every enabled edition, reads the two registry keys directly
#       (Directory\shell\<Name>  +  Directory\Background\shell\<Name>)
#       and asserts:
#         a. key exists
#         b. (Default) value == contextMenuLabel from config.json
#         c. Icon value points to an .exe that exists on disk
#         d. \command (Default) is "<exe>" "%V"   (matches the configured exe)
#         e. file-target HKCR\*\shell\<Name> is ABSENT (we don't want
#            "Open with Code" appearing on every file).
#    3. Prints a per-edition PASS/FAIL block and exits 0 only if every
#       cell passes.
#
#  Usage:
#    .\smoke-folder-vs-empty.ps1                    # all enabled editions
#    .\smoke-folder-vs-empty.ps1 -Edition stable
#    .\smoke-folder-vs-empty.ps1 -RepairOnly        # call `repair`, not `install`
#    .\smoke-folder-vs-empty.ps1 -SkipMutate        # assume registry already wired
#    .\smoke-folder-vs-empty.ps1 -DryRun            # print plan only
#    .\smoke-folder-vs-empty.ps1 -NoColor           # CI-friendly output
#
#  Exit codes:
#    0 -- every assertion passed for every edition
#    1 -- at least one folder/empty assertion failed
#    2 -- pre-flight failed (config missing, not admin, etc.)
#
#  Requires Administrator (install + repair write to HKCR). Read-only
#  assertions don't, but the wrapper drives the writes by default.
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string] $Edition    = "",
    [switch] $RepairOnly,
    [switch] $SkipMutate,
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
if (-not (Test-Path -LiteralPath $runScript)) {
    Write-Host "FATAL: run.ps1 not found at: $runScript (failure: cannot drive smoke test without entry point)" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "FATAL: config.json not found at: $configPath (failure: cannot read enabledEditions or registryPaths)" -ForegroundColor Red
    exit 2
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ((-not $isAdmin) -and (-not $DryRun) -and (-not $SkipMutate)) {
    Write-Host "FATAL: smoke test must run as Administrator (install/repair write to HKEY_CLASSES_ROOT). Re-launch PowerShell with 'Run as administrator', or pass -DryRun to preview, or -SkipMutate to assert read-only." -ForegroundColor Red
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
Write-C " Script 10 -- smoke: FOLDER vs EMPTY-FOLDER context menu"         "DarkCyan"
Write-C "================================================================" "DarkCyan"
Write-C ("  editions    : " + ($editions -join ', ')) "Gray"
Write-C ("  RepairOnly  : " + [bool]$RepairOnly)      "Gray"
Write-C ("  SkipMutate  : " + [bool]$SkipMutate)      "Gray"
Write-C ("  DryRun      : " + [bool]$DryRun)          "Gray"
Write-C ""

if ($DryRun) {
    Write-C "DryRun mode -- planned sequence:" "Yellow"
    if (-not $SkipMutate) {
        $verb = if ($RepairOnly) { 'repair' } else { 'install' }
        Write-C "  1. & '$runScript' $verb" "DarkGray"
    }
    foreach ($e in $editions) {
        $dirPath = $config.editions.$e.registryPaths.directory
        $bgPath  = $config.editions.$e.registryPaths.background
        $filPath = $config.editions.$e.registryPaths.file
        Write-C "  2. assert FOLDER  key present:        $dirPath"          "DarkGray"
        Write-C "  3. assert EMPTY   key present:        $bgPath"           "DarkGray"
        Write-C "  4. assert FILE-target key ABSENT:     $filPath"          "DarkGray"
        Write-C "  5. assert (Default)/Icon/\command match config for both" "DarkGray"
    }
    Write-C ""
    Write-C "DryRun complete. No registry writes or reads performed." "Yellow"
    exit 0
}

# ---- Helper: invoke run.ps1 and capture exit code --------------------------
function Invoke-Run {
    param([Parameter(Mandatory)] [string[]] $Arguments, [string]$Label = "")
    if ($Label) { Write-C ("  > " + $Label) "DarkGray" }
    & $runScript @Arguments
    return $LASTEXITCODE
}

# ---- Helper: resolve the configured exe path for an edition ----------------
# Mirrors what registry.ps1 picks at install time so the assertions compare
# apples to apples. installationType in config drives which slot we use.
function Resolve-EditionExe {
    param([Parameter(Mandatory)] $EditionConfig, [string]$InstallType = 'user')
    $slot = if ($InstallType -ieq 'system') { 'system' } else { 'user' }
    $raw  = $EditionConfig.vscodePath.$slot
    if (-not $raw) { return $null }
    return [Environment]::ExpandEnvironmentVariables($raw)
}

# ---- Helper: read a registry (Default) value safely ------------------------
function Get-RegDefault {
    param([Parameter(Mandatory)] [string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains '(default)') { return $item.'(default)' }
        # Some PowerShell versions surface the default value as the key's "(Default)" PSChildName
        $raw = (Get-Item -LiteralPath $Path).GetValue($null)
        return $raw
    } catch { return $null }
}

function Get-RegValue {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        return (Get-Item -LiteralPath $Path).GetValue($Name)
    } catch { return $null }
}

# ---- Step 1: install or repair --------------------------------------------
if (-not $SkipMutate) {
    $verb = if ($RepairOnly) { 'repair' } else { 'install' }
    Write-C ""
    Write-C "Step 1 : $verb" "Cyan"
    $verbArgs = @($verb)
    if ($hasFilter) { $verbArgs += @('-Edition', $Edition) }
    $rc = Invoke-Run -Arguments $verbArgs -Label ("run.ps1 " + ($verbArgs -join ' '))
    Assert-True "$verb verb exits 0" ($rc -eq 0) `
        ("$verb exited $rc (failure: see logs/10-vscode-context-menu-fix/<latest>.log; cannot proceed to folder/empty assertions if $verb itself failed)")
    if ($rc -ne 0) {
        Write-C ""
        Write-C "Skipping registry assertions because $verb failed." "Red"
        exit 1
    }
} else {
    Write-C ""
    Write-C "Step 1 : install/repair -- SKIPPED (-SkipMutate)" "Yellow"
}

# ---- Step 2: per-edition folder vs empty assertions -----------------------
$installType = if ($config.PSObject.Properties.Name -contains 'installationType') { [string]$config.installationType } else { 'user' }

foreach ($edName in $editions) {
    Write-C ""
    Write-C ("Edition: $edName") "Cyan"

    $hasEd = $config.editions.PSObject.Properties.Name -contains $edName
    if (-not $hasEd) {
        Assert-True "edition '$edName' present in config.editions" $false `
            "config.json has no editions.$edName block (failure: cannot read registry paths)"
        continue
    }
    $edCfg     = $config.editions.$edName
    $expLabel  = [string]$edCfg.contextMenuLabel
    $expExe    = Resolve-EditionExe -EditionConfig $edCfg -InstallType $installType
    $expCmdArg = "`"$expExe`" `"%V`""

    $dirPath = $edCfg.registryPaths.directory     # FOLDER (right-click on a folder)
    $bgPath  = $edCfg.registryPaths.background    # EMPTY  (right-click empty area inside a folder)
    $filPath = $edCfg.registryPaths.file          # FILE   (must remain ABSENT)

    foreach ($pair in @(
        @{ Label = 'FOLDER (right-click on folder)';        Path = $dirPath; Hive = 'Directory\shell' },
        @{ Label = 'EMPTY  (right-click empty folder bg)';  Path = $bgPath;  Hive = 'Directory\Background\shell' }
    )) {
        $tLabel = $pair.Label
        $tPath  = $pair.Path

        Write-C ("  Target: $tLabel  -> $tPath") "DarkGray"

        $isPresent = Test-Path -LiteralPath $tPath
        Assert-True "$edName / $tLabel : key exists" $isPresent `
            "missing registry key: $tPath (failure: $tLabel context menu will not appear in Explorer until this key is recreated; run: $runScript repair -Edition $edName)"
        if (-not $isPresent) { continue }

        $gotLabel = Get-RegDefault -Path $tPath
        $isLabelOk = ([string]$gotLabel -eq $expLabel)
        Assert-True "$edName / $tLabel : (Default) label == '$expLabel'" $isLabelOk `
            ("(Default) at " + $tPath + " is '" + [string]$gotLabel + "', expected '" + $expLabel + "' (failure: menu entry will show the wrong text)")

        $gotIcon = Get-RegValue -Path $tPath -Name 'Icon'
        $isIconPresent = -not [string]::IsNullOrWhiteSpace([string]$gotIcon)
        Assert-True "$edName / $tLabel : Icon value is set" $isIconPresent `
            ("Icon missing at " + $tPath + " (failure: menu entry will render without the VS Code glyph; expected an .exe path)")
        if ($isIconPresent) {
            $iconExe = ([string]$gotIcon -replace '^"', '' -replace '"$', '')
            $iconExe = [Environment]::ExpandEnvironmentVariables($iconExe)
            $isIconOnDisk = Test-Path -LiteralPath $iconExe
            Assert-True "$edName / $tLabel : Icon target exists on disk" $isIconOnDisk `
                ("Icon at " + $tPath + " points to '" + $iconExe + "' which does not exist (failure: VS Code probably uninstalled or moved; re-run install)")
        }

        $cmdPath = Join-Path $tPath 'command'
        $isCmdKey = Test-Path -LiteralPath $cmdPath
        Assert-True "$edName / $tLabel : \command subkey exists" $isCmdKey `
            ("missing subkey: $cmdPath (failure: clicking the menu entry will do nothing -- no command bound)")
        if ($isCmdKey) {
            $gotCmd = Get-RegDefault -Path $cmdPath
            $isCmdOk = ([string]$gotCmd -eq $expCmdArg)
            Assert-True "$edName / $tLabel : \command (Default) == '$expCmdArg'" $isCmdOk `
                ("(Default) at " + $cmdPath + " is '" + [string]$gotCmd + "', expected '" + $expCmdArg + "' (failure: %V token must resolve to the clicked/current folder; mismatch means the menu opens the wrong path or fails silently)")
        }
    }

    # File-target invariant: must NOT exist (otherwise "Open with Code" appears on every file).
    Write-C ("  Invariant: FILE-target must be ABSENT  -> $filPath") "DarkGray"
    $isFilePresent = Test-Path -LiteralPath $filPath
    Assert-True "$edName / FILE-target absent (no per-file menu entry)" (-not $isFilePresent) `
        ("file-target key STILL EXISTS at " + $filPath + " (failure: 'Open with Code' will appear on every file in Explorer; run: $runScript repair -Edition $edName)")
}

# ---- Summary --------------------------------------------------------------
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " Smoke summary -- folder vs empty-folder"                          "DarkCyan"
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

Write-C "All folder vs empty-folder assertions passed." "Green"
exit 0