# --------------------------------------------------------------------------
#  Script 54 -- tests/run-tests.ps1
#
#  Plain PowerShell test harness for the VS Code menu installer.
#  READ-ONLY: walks the path allow-list in config.json and asserts that
#  every enabled edition has its expected leaf key + command value, and
#  that the command template matches one of the two known shapes:
#
#    1. Direct dispatch         -- "<exe>" "%1" / "%V"   (default mode)
#    2. confirm-launch wrapper  -- pwsh ... Invoke-ConfirmedCommand ...
#                                  (when confirmBeforeLaunch.enabled = true)
#
#  Mirrors the pattern used by script 53's harness; this one is intentionally
#  a SUBSET (leaf existence + command template only). It does NOT test for
#  Shift-bypass twins because script 54 does not emit them.
#
#  Usage:
#    .\run-tests.ps1                       # all enabled editions, all targets
#    .\run-tests.ps1 -Edition stable       # one edition
#    .\run-tests.ps1 -OnlyTargets file,directory
#    .\run-tests.ps1 -OnlyCases 1,2        # subset of case numbers
#    .\run-tests.ps1 -NoColor              # CI / log-friendly
#    .\run-tests.ps1 -Verbose              # print every PASS line
#    .\run-tests.ps1 -SkipRepairInvariants # ignore Cases 6/7/8 entirely
#
#  Exit codes:
#    0 -- all green
#    1 -- at least one assertion failed
#    2 -- pre-flight failed (config missing, no enabled editions, etc.)
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]   $Edition      = "",                      # empty = use config.enabledEditions
    [string[]] $OnlyTargets  = @(),                     # subset of file/directory/background
    [int[]]    $OnlyCases    = @(),                     # subset of case numbers
    [switch]   $NoColor,
    [switch]   $SkipRepairInvariants                    # opt out of Cases 6/7/8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$installerDir = Split-Path -Parent $scriptDir
$configPath  = Join-Path $installerDir "config.json"

# ---- Pre-flight: config.json -----------------------------------------------
$isConfigMissing = -not (Test-Path -LiteralPath $configPath)
if ($isConfigMissing) {
    Write-Host "FATAL: config.json not found at $configPath" -ForegroundColor Red
    exit 2
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

# ---- Repair-invariant config: read the same flag the `check` verb uses ----
function Test-RepairInvariantsEnforcedHarness {
    param($Cfg)
    $hasRepair = $Cfg.PSObject.Properties.Name -contains 'repair'
    if (-not $hasRepair) { return $true }
    $hasFlag = $Cfg.repair.PSObject.Properties.Name -contains 'enforceInvariants'
    if (-not $hasFlag) { return $true }
    return [bool]$Cfg.repair.enforceInvariants
}
function Get-RepairLegacyNamesHarness {
    param($Cfg)
    $hasRepair = $Cfg.PSObject.Properties.Name -contains 'repair'
    $hasList   = $hasRepair -and ($Cfg.repair.PSObject.Properties.Name -contains 'legacyNames')
    if ($hasList) { return @($Cfg.repair.legacyNames) }
    return @(
        'VSCode2','VSCode3','VSCodeOld','VSCode_old',
        'OpenWithCode','OpenWithVSCode','Open with Code','OpenCode',
        'VSCodeInsiders2','VSCodeInsidersOld','OpenWithInsiders'
    )
}
$script:RepairSuppressionValues = @(
    'ProgrammaticAccessOnly','AppliesTo','NoWorkingDirectory',
    'LegacyDisable','CommandFlags'
)
$invariantsEnforced = (Test-RepairInvariantsEnforcedHarness $config) -and (-not $SkipRepairInvariants)
$legacyNamesList   = Get-RepairLegacyNamesHarness $config

# ---- Decide which editions / targets to test -------------------------------
$editionsToTest = if ([string]::IsNullOrWhiteSpace($Edition)) {
    @($config.enabledEditions)
} else {
    @($Edition)
}

$targetsAll = @('file', 'directory', 'background')
$targetsToTest = if ($OnlyTargets.Count -gt 0) {
    $targetsAll | Where-Object { $OnlyTargets -contains $_ }
} else { $targetsAll }

# ---- Confirm-launch detection (mirrors install.ps1 logic) ------------------
$isWrapperMode = $false
$hasConfirmBlock = $config.PSObject.Properties.Name -contains 'confirmBeforeLaunch'
if ($hasConfirmBlock) {
    $cfg = $config.confirmBeforeLaunch
    if ($null -ne $cfg -and $cfg.PSObject.Properties.Name -contains 'enabled') {
        $isWrapperMode = [bool]$cfg.enabled
    }
}

# ---- Output / accounting helpers -------------------------------------------
$script:results = @()
$script:passN   = 0
$script:failN   = 0
$script:skipN   = 0
$script:currentCase = 0

function Write-C {
    param([string]$Text, [string]$Color = "White")
    if ($NoColor) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:passN++
        $script:results += [PSCustomObject]@{ Case = $script:currentCase; Name = $Name; Status = "PASS"; Detail = $Detail }
        if ($VerbosePreference -eq "Continue") { Write-C "    [PASS] $Name" "Green" }
    } else {
        $script:failN++
        $script:results += [PSCustomObject]@{ Case = $script:currentCase; Name = $Name; Status = "FAIL"; Detail = $Detail }
        Write-C "    [FAIL] $Name" "Red"
        if ($Detail) { Write-C "           $Detail" "DarkGray" }
    }
}

function Skip-Case {
    param([string]$Reason)
    $script:skipN++
    $script:results += [PSCustomObject]@{ Case = $script:currentCase; Name = "(skipped)"; Status = "SKIP"; Detail = $Reason }
    Write-C "    [SKIP] $Reason" "Yellow"
}

function Should-Run { param([int]$N) return ($OnlyCases.Count -eq 0) -or ($OnlyCases -contains $N) }

function Start-Case {
    param([int]$Num, [string]$Title)
    $script:currentCase = $Num
    Write-C ""
    Write-C "Case $Num : $Title" "Cyan"
}

# ---- Registry helpers ------------------------------------------------------
function Resolve-VsCodeExe {
    param([string]$ConfigPath)
    # Mirror what install.ps1 does: expand %ENV%-style vars.
    return [Environment]::ExpandEnvironmentVariables($ConfigPath)
}

function Get-DefaultValue {
    param([string]$PsPath)
    $isPresent = Test-Path -LiteralPath $PsPath
    if (-not $isPresent) { return $null }
    $prop = Get-ItemProperty -LiteralPath $PsPath -ErrorAction SilentlyContinue
    if ($null -eq $prop) { return $null }
    # The default value is exposed under the property "(default)"
    $names = $prop.PSObject.Properties.Name
    if ($names -contains '(default)') { return $prop.'(default)' }
    return $null
}

# ---- Pre-flight banner -----------------------------------------------------
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " VS Code Menu Installer (54) -- read-only test harness"          "DarkCyan"
Write-C "================================================================" "DarkCyan"
Write-C "  Editions tested : $($editionsToTest -join ', ')"
Write-C "  Targets tested  : $($targetsToTest -join ', ')"
Write-C "  Mode            : $(if ($isWrapperMode) { 'confirm-launch wrapper' } else { 'direct dispatch' })"
Write-C "  Repair invariants : $(if ($invariantsEnforced) { 'ENFORCED (Cases 6/7/8)' } else { 'skipped' })"
Write-C ""

if ($editionsToTest.Count -eq 0) {
    Write-C "FATAL: no editions to test (config.enabledEditions is empty and -Edition not supplied)" "Red"
    exit 2
}

# ===========================================================================
#  Per-edition cases
#
#  Case numbering (per edition):
#    1. Leaf key exists at every target path in registryPaths
#    2. Leaf (Default) value matches configured label
#    3. command subkey exists and (Default) value is non-empty
#    4. command (Default) matches the expected template shape
#    5. Idempotency sanity -- no duplicate "VSCodeVSCode" / sibling junk
# ===========================================================================
foreach ($editionName in $editionsToTest) {
    $editionCfg = $config.editions.$editionName
    $isUnknown = $null -eq $editionCfg
    if ($isUnknown) {
        Write-C ""
        Write-C "Edition '$editionName' not found in config.editions -- skipping." "Yellow"
        $script:skipN++
        continue
    }

    Write-C ""
    Write-C "================================================================" "DarkGray"
    Write-C " Edition: $editionName  ($($editionCfg.label))"                    "White"
    Write-C "================================================================" "DarkGray"

    $resolvedExe = Resolve-VsCodeExe $editionCfg.vsCodePath

    foreach ($target in $targetsToTest) {
        $hasPath = $editionCfg.registryPaths.PSObject.Properties.Name -contains $target
        if (-not $hasPath) {
            Write-C "  Target '$target' not configured for edition '$editionName' -- skipping." "Yellow"
            continue
        }
        $regPath = $editionCfg.registryPaths.$target
        $cmdTpl  = $editionCfg.commandTemplates.$target
        $cmdPath = "$regPath\command"

        Write-C ""
        Write-C "--- Target: $target ---" "Magenta"
        Write-C "    Path: $regPath" "DarkGray"

        # When repair invariants are enforced, the file-target key MUST be
        # absent. Skip the install-style cases (1-5) for the file target so
        # they don't fight Case 6. Cases 6/7/8 below take over.
        $isFileUnderRepair = ($invariantsEnforced -and ($target -eq 'file'))
        if ($isFileUnderRepair) {
            Write-C "    (Cases 1-5 skipped for file target -- repair invariant requires it absent; see Case 6)" "DarkYellow"
        }

        # ---- Case 1: leaf key exists ----
        if ((Should-Run 1) -and (-not $isFileUnderRepair)) {
            Start-Case 1 "[$editionName/$target] Leaf key exists"
            $exists = Test-Path -LiteralPath $regPath
            Assert-True "Key exists at $regPath" $exists
            if (-not $exists) {
                Skip-Case "leaf missing -- remaining cases for this target depend on it"
                continue
            }
        }

        # ---- Case 2: leaf (Default) matches label ----
        if ((Should-Run 2) -and (-not $isFileUnderRepair)) {
            Start-Case 2 "[$editionName/$target] Leaf (Default) value = configured label"
            $label = Get-DefaultValue $regPath
            Assert-True "Leaf has (Default) value" ($null -ne $label) "Path: $regPath"
            if ($null -ne $label) {
                Assert-True "(Default) matches '$($editionCfg.label)'" `
                    ($label -eq $editionCfg.label) "Got: '$label'"
            }
        }

        # ---- Case 3: command subkey + non-empty value ----
        if ((Should-Run 3) -and (-not $isFileUnderRepair)) {
            Start-Case 3 "[$editionName/$target] command subkey exists with non-empty (Default)"
            $cmdExists = Test-Path -LiteralPath $cmdPath
            Assert-True "command subkey exists at $cmdPath" $cmdExists
            if ($cmdExists) {
                $cmdValue = Get-DefaultValue $cmdPath
                Assert-True "command (Default) is non-empty" `
                    (-not [string]::IsNullOrWhiteSpace($cmdValue)) "Got: '$cmdValue'"
            }
        }

        # ---- Case 4: command matches expected template ----
        if ((Should-Run 4) -and (-not $isFileUnderRepair)) {
            Start-Case 4 "[$editionName/$target] command matches expected template ($(if ($isWrapperMode) {'wrapper'} else {'direct'}))"
            $cmdValue = Get-DefaultValue $cmdPath
            if ($null -eq $cmdValue) {
                Skip-Case "command (Default) missing"
            } else {
                Write-C "    Command: $cmdValue" "DarkGray"
                if ($isWrapperMode) {
                    $hasWrapper = $cmdValue -match 'confirm-launch\.ps1' `
                              -and $cmdValue -match 'Invoke-ConfirmedCommand'
                    Assert-True "Command uses confirm-launch wrapper" $hasWrapper `
                        "Expected 'confirm-launch.ps1' + 'Invoke-ConfirmedCommand' in command line"
                    # The wrapped inner command should still reference the VS Code exe somewhere
                    $hasExe = $cmdValue -match [regex]::Escape((Split-Path -Leaf $resolvedExe))
                    Assert-True "Wrapped command still references the VS Code exe ($([System.IO.Path]::GetFileName($resolvedExe)))" $hasExe
                } else {
                    # Direct dispatch: the command should be the resolved template with {exe} substituted.
                    $expected = $cmdTpl -replace '\{exe\}', [regex]::Escape($resolvedExe)
                    # Compare loosely on the exe portion + the %1 / %V tail
                    $hasExe = $cmdValue -match [regex]::Escape($resolvedExe)
                    Assert-True "Command references resolved exe path ($resolvedExe)" $hasExe
                    $tail = if ($target -eq 'file') { '"%1"' } else { '"%V"' }
                    Assert-True "Command ends with target placeholder $tail" `
                        ($cmdValue.TrimEnd() -like "*$tail") "Tail check failed: '$cmdValue'"
                    Assert-True "Command does NOT contain confirm-launch (wrapper disabled)" `
                        ($cmdValue -notmatch 'confirm-launch\.ps1')
                }
            }
        }

        # ---- Case 5: idempotency / no junk siblings sharing prefix ----
        if ((Should-Run 5) -and (-not $isFileUnderRepair)) {
            Start-Case 5 "[$editionName/$target] Idempotency -- no doubled-up sibling keys"
            # Look at the parent and assert that no sibling key starts with the leaf name twice
            # (e.g. "VSCodeVSCode" or "VSCode_1") which would indicate a botched install.
            $parent = Split-Path -Parent $regPath
            $leafName = Split-Path -Leaf $regPath
            if (Test-Path -LiteralPath $parent) {
                $siblings = @(Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue |
                              Where-Object { $_.PSChildName -ne $leafName -and `
                                             ($_.PSChildName -like "$leafName*" -or $_.PSChildName -like "*$leafName$leafName*") })
                Assert-True "No duplicate / suffixed siblings of '$leafName' under $parent" `
                    ($siblings.Count -eq 0) `
                    "Found: $($siblings.PSChildName -join ', ')"
            } else {
                Skip-Case "parent path $parent does not exist"
            }
        }

        # ===================================================================
        #  Repair-invariant cases (6/7/8). Only run when enforced.
        # ===================================================================
        if (-not $invariantsEnforced) { continue }

        # ---- Case 6: file-target key MUST be absent ----
        if (($target -eq 'file') -and (Should-Run 6)) {
            Start-Case 6 "[$editionName/$target] Repair invariant -- file-target key is ABSENT"
            $stillThere = Test-Path -LiteralPath $regPath
            Assert-True "File-target key is absent at $regPath" (-not $stillThere) `
                "Run '.\run.ps1 -I 54 repair' to remove the file-target entry."
        }

        # ---- Case 7: directory + background carry NO suppression values ----
        if (($target -in @('directory','background')) -and (Should-Run 7)) {
            Start-Case 7 "[$editionName/$target] Repair invariant -- no suppression values present"
            $foundSup = @()
            $isPresent = Test-Path -LiteralPath $regPath
            if ($isPresent) {
                $prop = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
                if ($null -ne $prop) {
                    foreach ($v in $script:RepairSuppressionValues) {
                        if ($prop.PSObject.Properties.Name -contains $v) { $foundSup += $v }
                    }
                }
            }
            $isClean = $foundSup.Count -eq 0
            Assert-True "No suppression values on $regPath" $isClean `
                "Found: $($foundSup -join ', ') -- run 'repair' to strip."
        }

        # ---- Case 8: no legacy duplicate sibling keys under the shell parent ----
        if (Should-Run 8) {
            Start-Case 8 "[$editionName/$target] Repair invariant -- no legacy duplicates under shell parent"
            $parentForLegacy = Split-Path -Parent $regPath
            $foundLegacy = @()
            if (Test-Path -LiteralPath $parentForLegacy) {
                foreach ($name in $legacyNamesList) {
                    $candidate = Join-Path $parentForLegacy $name
                    if (Test-Path -LiteralPath $candidate) { $foundLegacy += $name }
                }
            }
            $isClean = $foundLegacy.Count -eq 0
            Assert-True "No legacy duplicates under $parentForLegacy" $isClean `
                "Found: $($foundLegacy -join ', ') -- run 'repair' to sweep."
        }
    }
}

# ===========================================================================
#  SUMMARY
# ===========================================================================
Write-C ""
Write-C "================================================================" "DarkCyan"
Write-C " Summary"                                                          "DarkCyan"
Write-C "================================================================" "DarkCyan"
Write-C "  PASS : $script:passN" "Green"
Write-C "  FAIL : $script:failN" $(if ($script:failN -gt 0) { "Red" } else { "DarkGray" })
Write-C "  SKIP : $script:skipN" "Yellow"
Write-C ""

if ($script:failN -gt 0) {
    Write-C "Failures:" "Red"
    $script:results | Where-Object Status -eq "FAIL" | ForEach-Object {
        Write-C ("  [Case {0}] {1}" -f $_.Case, $_.Name) "Red"
        if ($_.Detail) { Write-C ("            {0}" -f $_.Detail) "DarkGray" }
    }
    exit 1
}

Write-C "All cases passed." "Green"
exit 0
