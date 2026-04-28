<#
.SYNOPSIS
    Step-by-step verification that VS Code entries appear in the Windows
    right-click context menu after Script 10's `repair` (or default install)
    has run.

.DESCRIPTION
    Read-only. Does NOT touch the registry. For each enabled edition in
    config.json, runs a numbered sequence of `reg.exe query` commands that
    correspond 1:1 to the user-visible right-click scenarios:

      Step 1  Right-click ON a folder       (Directory\shell\<Name>)
      Step 2  Right-click in EMPTY space    (Directory\Background\shell\<Name>)
      Step 3  Folder \command default       (must be "<Code.exe>" "%V")
      Step 4  Background \command default   (must be "<Code.exe>" "%V")
      Step 5  Label  (Default value)        (must equal contextMenuLabel)
      Step 6  Icon points at a real Code.exe
      Step 7  File-target leaf is ABSENT    (HKCR\*\shell\<Name>)

    Each step prints:
      [PASS|FAIL] Step N -- <scenario>
        reg path : <full HKCR path>
        command  : <the exact reg.exe line we ran>
        result   : <what we found>
        fix      : <copy-paste command to repair if FAIL>

    Exit codes
      0  all steps passed for every enabled edition
      1  at least one step failed
      2  pre-flight failure (config missing, no editions, etc.)

.PARAMETER Edition
    Optional. Restrict verification to a single edition key (e.g. 'stable'
    or 'insiders'). Default: every entry in config.enabledEditions.

.PARAMETER ConfigPath
    Optional. Override path to config.json. Default: ..\config.json
    relative to this script.

.EXAMPLE
    .\verify-context-menu.ps1
    .\verify-context-menu.ps1 -Edition stable
#>
param(
    [string]$Edition,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $scriptRoot 'config.json'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host ("[PRE-FAIL] config.json not found at: " + $ConfigPath) -ForegroundColor Red
    Write-Host  "          fix: re-clone the repo or pass -ConfigPath <path>" -ForegroundColor Yellow
    exit 2
}

try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Host ("[PRE-FAIL] failed to parse config.json: " + $ConfigPath) -ForegroundColor Red
    Write-Host ("          reason: " + $_.Exception.Message) -ForegroundColor Yellow
    exit 2
}

$editionsToCheck = @()
if ($Edition) {
    $editionsToCheck = @($Edition)
} elseif ($config.PSObject.Properties.Name -contains 'enabledEditions') {
    $editionsToCheck = @($config.enabledEditions)
}
if ($editionsToCheck.Count -eq 0) {
    Write-Host "[PRE-FAIL] no editions to verify (config.enabledEditions is empty and -Edition not given)" -ForegroundColor Red
    Write-Host  "          fix: pass -Edition stable  OR  populate enabledEditions in config.json" -ForegroundColor Yellow
    exit 2
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Registry::HKEY_CLASSES_ROOT\... -> HKCR\... (reg.exe friendly)
function ConvertTo-RegExePath {
    param([string]$RegistryColonPath)
    return ($RegistryColonPath -replace '^Registry::HKEY_CLASSES_ROOT', 'HKCR' `
                               -replace '^Registry::HKEY_LOCAL_MACHINE', 'HKLM' `
                               -replace '^Registry::HKEY_CURRENT_USER',  'HKCU')
}

# Run `reg query "<key>" /ve` (or with /v <name>) and return:
#   @{ exists=<bool>; value=<string-or-empty>; raw=<full reg.exe output>; cmd=<the line we ran> }
function Invoke-RegQuery {
    param(
        [Parameter(Mandatory)] [string]$RegPath,
        [string]$ValueName = ''   # '' means default value (/ve)
    )
    $regExePath = ConvertTo-RegExePath -RegistryColonPath $RegPath
    $argList = @('query', $regExePath)
    if ($ValueName -eq '') { $argList += @('/ve') }
    else                   { $argList += @('/v', $ValueName) }
    $cmdLine = 'reg.exe ' + ($argList -join ' ')

    $raw = ''
    $exitCode = 1
    try {
        $raw = & reg.exe @argList 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } catch {
        $raw = "reg.exe not available on this host: " + $_.Exception.Message
        $exitCode = 1
    }
    $exists = ($exitCode -eq 0)

    $value = ''
    if ($exists) {
        # reg.exe prints lines like:    (Default)    REG_SZ    <value>
        # or                            <Name>       REG_SZ    <value>
        $needle = if ($ValueName -eq '') { '(Default)' } else { $ValueName }
        foreach ($line in ($raw -split "`r?`n")) {
            $trim = $line.Trim()
            if ($trim -like ($needle + '*REG_*')) {
                $parts = [regex]::Split($trim, '\s{2,}|\t+')
                if ($parts.Count -ge 3) {
                    $value = ($parts[2..($parts.Count - 1)] -join ' ').Trim()
                }
                break
            }
        }
    }

    return @{
        exists = $exists
        value  = $value
        raw    = $raw.TrimEnd()
        cmd    = $cmdLine
    }
}

$script:totalPass = 0
$script:totalFail = 0
$script:stepNumber = 0

function Write-StepResult {
    param(
        [Parameter(Mandatory)] [bool]   $IsPass,
        [Parameter(Mandatory)] [string] $Scenario,
        [Parameter(Mandatory)] [string] $RegPath,
        [Parameter(Mandatory)] [string] $Cmd,
        [Parameter(Mandatory)] [string] $ResultText,
        [Parameter(Mandatory)] [string] $FixHint
    )
    $script:stepNumber++
    if ($IsPass) {
        $script:totalPass++
        Write-Host ("[PASS] Step " + $script:stepNumber + " -- " + $Scenario) -ForegroundColor Green
    } else {
        $script:totalFail++
        Write-Host ("[FAIL] Step " + $script:stepNumber + " -- " + $Scenario) -ForegroundColor Red
    }
    Write-Host ("       reg path : " + (ConvertTo-RegExePath $RegPath)) -ForegroundColor DarkGray
    Write-Host ("       command  : " + $Cmd)                            -ForegroundColor DarkGray
    Write-Host ("       result   : " + $ResultText)                     -ForegroundColor DarkGray
    if (-not $IsPass) {
        Write-Host ("       fix      : " + $FixHint)                    -ForegroundColor Yellow
    }
}

function Resolve-CodeExePath {
    param([Parameter(Mandatory)] $EditionConfig, [string]$InstallType = 'user')
    $raw = $EditionConfig.vscodePath.$InstallType
    if (-not $raw) { return '' }
    return [Environment]::ExpandEnvironmentVariables($raw)
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Script 10 -- Step-by-step Context-Menu Verification"      -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  config       : " + $ConfigPath)
Write-Host ("  editions     : " + ($editionsToCheck -join ', '))
Write-Host ("  installType  : " + $config.installationType)
Write-Host ""

$installType = $config.installationType
if (-not $installType) { $installType = 'user' }

$repairHintBase = ".\run.ps1 repair"

foreach ($edName in $editionsToCheck) {
    $ed = $config.editions.$edName
    if (-not $ed) {
        Write-Host ("[SKIP] edition '" + $edName + "' is not defined in config.editions") -ForegroundColor Yellow
        continue
    }

    Write-Host ("---- Edition: " + $edName + " ----") -ForegroundColor Cyan
    $exePath = Resolve-CodeExePath -EditionConfig $ed -InstallType $installType
    $expectedLabel = $ed.contextMenuLabel
    $dirPath  = $ed.registryPaths.directory
    $bgPath   = $ed.registryPaths.background
    $filePath = $ed.registryPaths.file
    $repairHint = $repairHintBase + " -Edition " + $edName

    # ---- Step: directory key present (right-click ON a folder) ----
    $r = Invoke-RegQuery -RegPath $dirPath -ValueName ''
    Write-StepResult `
        -IsPass:$r.exists `
        -Scenario "Right-click ON a folder -> menu entry exists" `
        -RegPath  $dirPath `
        -Cmd      $r.cmd `
        -ResultText $(if ($r.exists) { "key found, label='" + $r.value + "'" } else { "key MISSING" }) `
        -FixHint  $repairHint

    # ---- Step: background key present (right-click in empty space) ----
    $r = Invoke-RegQuery -RegPath $bgPath -ValueName ''
    Write-StepResult `
        -IsPass:$r.exists `
        -Scenario "Right-click in EMPTY space inside a folder -> menu entry exists" `
        -RegPath  $bgPath `
        -Cmd      $r.cmd `
        -ResultText $(if ($r.exists) { "key found, label='" + $r.value + "'" } else { "key MISSING" }) `
        -FixHint  $repairHint

    # ---- Step: \command default for directory ----
    $dirCmdPath = $dirPath + '\command'
    $r = Invoke-RegQuery -RegPath $dirCmdPath -ValueName ''
    $expectedCmd = '"' + $exePath + '" "%V"'
    $isCmdOk = $r.exists -and ($r.value -eq $expectedCmd)
    Write-StepResult `
        -IsPass:$isCmdOk `
        -Scenario "Folder \command launches Code.exe with %V" `
        -RegPath  $dirCmdPath `
        -Cmd      $r.cmd `
        -ResultText ("got='" + $r.value + "'  expected='" + $expectedCmd + "'") `
        -FixHint  $repairHint

    # ---- Step: \command default for background ----
    $bgCmdPath = $bgPath + '\command'
    $r = Invoke-RegQuery -RegPath $bgCmdPath -ValueName ''
    $isBgCmdOk = $r.exists -and ($r.value -eq $expectedCmd)
    Write-StepResult `
        -IsPass:$isBgCmdOk `
        -Scenario "Background \command launches Code.exe with %V" `
        -RegPath  $bgCmdPath `
        -Cmd      $r.cmd `
        -ResultText ("got='" + $r.value + "'  expected='" + $expectedCmd + "'") `
        -FixHint  $repairHint

    # ---- Step: label matches contextMenuLabel on directory ----
    $r = Invoke-RegQuery -RegPath $dirPath -ValueName ''
    $isLabelOk = $r.exists -and ($r.value -eq $expectedLabel)
    Write-StepResult `
        -IsPass:$isLabelOk `
        -Scenario ("Folder menu label equals '" + $expectedLabel + "'") `
        -RegPath  $dirPath `
        -Cmd      $r.cmd `
        -ResultText ("got='" + $r.value + "'  expected='" + $expectedLabel + "'") `
        -FixHint  $repairHint

    # ---- Step: Icon value points at a real Code.exe ----
    $r = Invoke-RegQuery -RegPath $dirPath -ValueName 'Icon'
    $iconResolved = ''
    $iconExists = $false
    if ($r.exists -and $r.value) {
        $iconResolved = [Environment]::ExpandEnvironmentVariables($r.value.Trim('"'))
        $iconExists = Test-Path -LiteralPath $iconResolved
    }
    Write-StepResult `
        -IsPass:($r.exists -and $iconExists) `
        -Scenario "Folder menu Icon resolves to an existing Code.exe" `
        -RegPath  $dirPath `
        -Cmd      $r.cmd `
        -ResultText ("Icon='" + $r.value + "'  resolved='" + $iconResolved + "'  fileExists=" + $iconExists) `
        -FixHint  $repairHint

    # ---- Step: file-target leaf is ABSENT (we only want folder + background) ----
    $r = Invoke-RegQuery -RegPath $filePath -ValueName ''
    $isFileAbsent = -not $r.exists
    Write-StepResult `
        -IsPass:$isFileAbsent `
        -Scenario "File-target leaf is ABSENT (right-click on FILE should NOT show entry)" `
        -RegPath  $filePath `
        -Cmd      $r.cmd `
        -ResultText $(if ($r.exists) { "leaf STILL PRESENT (label='" + $r.value + "')" } else { "leaf absent (correct)" }) `
        -FixHint  ($repairHintBase + "  # repair removes the file-target leaf")

    Write-Host ""
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
$total = $script:totalPass + $script:totalFail
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  SUMMARY  pass=" + $script:totalPass + "  fail=" + $script:totalFail + "  total=" + $total) -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if ($script:totalFail -eq 0) {
    Write-Host "[OK] Every step passed -- VS Code entries are wired correctly." -ForegroundColor Green
    exit 0
} else {
    Write-Host ("[FAIL] " + $script:totalFail + " step(s) failed. Run the printed 'fix' commands above, then re-run this verifier.") -ForegroundColor Red
    exit 1
}
