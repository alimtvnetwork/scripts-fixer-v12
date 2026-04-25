<#
.SYNOPSIS
    Read-only verification for Script 10. Two layers:
      A. Install state -- folder/background/file leaf exists with correct
         (Default) label, Icon, and \command (Default).
      B. Repair invariants -- file-target ABSENT, no suppression values
         on directory+background, no legacy duplicate siblings.

.DESCRIPTION
    Mirrors Script 54's vscode-check.ps1 + vscode-repair-check.ps1, but
    reads $ed.contextMenuLabel (Script 10's schema) instead of $ed.label.
    The repair-invariant pass is config-shape-agnostic and is implemented
    locally to avoid coupling Script 10's runtime to Script 54's helper
    file existing on disk.

    Public functions:
      Invoke-Script10MenuCheck          -- install-state check (A)
      Invoke-Script10RepairInvariantCheck -- repair-state check (B)
#>

Set-StrictMode -Version Latest

$_helperDir10c = $PSScriptRoot
$_sharedDir10c = Join-Path (Split-Path -Parent (Split-Path -Parent $_helperDir10c)) "shared"
$_loggingPath10c = Join-Path $_sharedDir10c "logging.ps1"
if ((Test-Path $_loggingPath10c) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath10c
}

$script:Check10SuppressionValues = @(
    'ProgrammaticAccessOnly','AppliesTo','NoWorkingDirectory',
    'LegacyDisable','CommandFlags'
)

# Module-level MISS collector. Reset at the top of each top-level check call
# so the run.ps1 wrapper can print one consolidated "what to do next" block.
$script:Check10MissActions = @()

function Reset-Check10MissActions { $script:Check10MissActions = @() }

function Add-Check10MissAction {
    param(
        [Parameter(Mandatory)] [string] $Edition,
        [Parameter(Mandatory)] [string] $Category, # install | invariant
        [Parameter(Mandatory)] [string] $Target,   # file | directory | background | parent
        [Parameter(Mandatory)] [string] $RegPath,  # HKCR\... (reg.exe-friendly, no Registry::)
        [string[]] $Items   = @(),                 # value names / child names
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string] $FixHint,  # exact next command
        [string] $InvariantCode = ''               # I1-FILE-TARGET | I2-SUPPRESSION | I3-LEGACY-DUP | INSTALL-STATE
    )
    $script:Check10MissActions += [pscustomobject]@{
        edition  = $Edition
        category = $Category
        target   = $Target
        regPath  = $RegPath
        items    = @($Items)
        reason   = $Reason
        fixHint  = $FixHint
        invariantCode = $InvariantCode
    }
}

function Get-Check10MissActions { return ,@($script:Check10MissActions) }

function Write-Check10MissActionSummary {
    param([Parameter(Mandatory)][string]$ScriptInvocationHint)
    $actions = $script:Check10MissActions
    if ($actions.Count -eq 0) { return }

    Write-Log "" -Level "info"
    Write-Log "===============================  ACTION SUMMARY  ===============================" -Level "warn"
    Write-Log ("  " + $actions.Count + " MISS finding(s) require attention. Each block below shows:") -Level "warn"
    Write-Log "    - the EXACT registry path triggering the miss" -Level "warn"
    Write-Log "    - the value or child names involved (if any)" -Level "warn"
    Write-Log "    - the next command to run to fix it" -Level "warn"
    Write-Log "================================================================================" -Level "warn"

    $i = 0
    foreach ($a in $actions) {
        $i++
        Write-Log "" -Level "info"
        $codeTag = if ($a.invariantCode) { $a.invariantCode } else { '<unspecified>' }
        Write-Log ("  [" + $i + "/" + $actions.Count + "] [" + $codeTag + "] edition=" + $a.edition + "  category=" + $a.category + "  target=" + $a.target) -Level "error"
        Write-Log ("        Invariant: " + $codeTag + "  (" + (Get-Check10InvariantDescription -Code $codeTag) + ")") -Level "error"
        Write-Log ("        Path  : " + $a.regPath) -Level "error"
        if ($a.items.Count -gt 0) {
            Write-Log ("        Items : " + ($a.items -join ', ')) -Level "error"
            foreach ($it in $a.items) {
                Write-Log ("                  - " + $it) -Level "error"
            }
        }
        Write-Log ("        Why   : " + $a.reason) -Level "error"
        Write-Log ("        Fix   : " + $a.fixHint) -Level "warn"
    }

    Write-Log "" -Level "info"
    Write-Log "  One-shot fix for ALL of the above:" -Level "warn"
    Write-Log ("      " + $ScriptInvocationHint) -Level "warn"
    Write-Log "" -Level "info"
    Write-Log "  Invariant code legend:" -Level "warn"
    Write-Log "      INSTALL-STATE   missing key, wrong (Default) label, missing Icon, or unresolvable exe in \command" -Level "warn"
    Write-Log "      I1-FILE-TARGET  HKCR\*\shell\<Name> still present (menu would appear on individual files)" -Level "warn"
    Write-Log "      I2-SUPPRESSION  ProgrammaticAccessOnly / AppliesTo / NoWorkingDirectory / LegacyDisable / CommandFlags set" -Level "warn"
    Write-Log "      I3-LEGACY-DUP   duplicate sibling key from a prior install (sweeps allow-listed legacyNames only)" -Level "warn"
    Write-Log "================================================================================" -Level "warn"
}

function Get-Check10InvariantDescription {
    param([string]$Code)
    switch ($Code) {
        'I1-FILE-TARGET' { return 'file-target key still present' }
        'I2-SUPPRESSION' { return 'forbidden value name(s) on directory/background' }
        'I3-LEGACY-DUP'  { return 'legacy duplicate sibling key(s) under shell parent' }
        'INSTALL-STATE'  { return 'install-state mismatch (key/label/icon/command)' }
        default          { return 'unspecified' }
    }
}

function Get-HkcrSubPath10 {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function ConvertTo-Check10RegExePath {
    # Strip the PowerShell-only "Registry::" prefix so the path is something
    # the user can paste straight into `reg.exe query <path>`.
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::', '')
}

function Get-Check10MenuEntryStatus {
    param(
        [Parameter(Mandatory)] [string] $TargetName,
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $ExpectedLabel
    )

    $status = [ordered]@{
        target          = $TargetName
        registryPath    = $RegistryPath
        keyExists       = $false
        labelOk         = $false
        actualLabel     = $null
        iconPresent     = $false
        commandPresent  = $false
        commandValue    = $null
        exeResolvable   = $false
        exePath         = $null
        verdict         = "MISS"
        reason          = $null
    }

    $sub  = Get-HkcrSubPath10 $RegistryPath
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    $key = $hkcr.OpenSubKey($sub)
    $isKeyMissing = $null -eq $key
    if ($isKeyMissing) {
        $status.reason = "registry key not found: $RegistryPath"
        return [pscustomobject]$status
    }
    $status.keyExists = $true
    try {
        $defaultVal = $key.GetValue("")
        $iconVal    = $key.GetValue("Icon")
        $status.actualLabel = [string]$defaultVal
        $status.iconPresent = -not [string]::IsNullOrWhiteSpace([string]$iconVal)
        $status.labelOk     = ($status.actualLabel -eq $ExpectedLabel)
    } finally { $key.Close() }

    $cmdKey = $hkcr.OpenSubKey("$sub\command")
    $isCmdMissing = $null -eq $cmdKey
    if ($isCmdMissing) {
        $status.reason = "missing \\command subkey under: $RegistryPath"
        return [pscustomobject]$status
    }
    try {
        $cmdLine = [string]$cmdKey.GetValue("")
        $status.commandValue   = $cmdLine
        $status.commandPresent = -not [string]::IsNullOrWhiteSpace($cmdLine)
    } finally { $cmdKey.Close() }

    $hasMatch = $status.commandValue -match '^\s*"([^"]+)"'
    if ($hasMatch) {
        $exe = $Matches[1]
        $expanded = [System.Environment]::ExpandEnvironmentVariables($exe)
        $status.exePath       = $expanded
        $status.exeResolvable = Test-Path -LiteralPath $expanded
    }

    $isAllOk = $status.keyExists -and $status.labelOk -and $status.iconPresent `
        -and $status.commandPresent -and $status.exeResolvable
    if ($isAllOk) {
        $status.verdict = "PASS"
    } else {
        $reasons = @()
        if (-not $status.labelOk)        { $reasons += "label mismatch (got '$($status.actualLabel)', expected '$ExpectedLabel')" }
        if (-not $status.iconPresent)    { $reasons += "missing Icon value" }
        if (-not $status.commandPresent) { $reasons += "empty \\command (Default)" }
        if (-not $status.exeResolvable -and $status.exePath) {
            $reasons += "exe path not on disk: $($status.exePath)"
        } elseif (-not $status.exeResolvable) {
            $reasons += "could not parse exe path from command"
        }
        $status.reason = ($reasons -join "; ")
    }
    return [pscustomobject]$status
}

function Invoke-Script10MenuCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string] $EditionFilter = ""
    )

    # Note: caller is responsible for resetting the MISS collector ONCE at
    # the top of the run if it wants a single combined summary across both
    # check passes (run.ps1 does this). We do NOT reset here so that
    # Invoke-Script10MenuCheck + Invoke-Script10RepairInvariantCheck can
    # accumulate into the same list.
    $editionResults = @()
    $totalPass = 0
    $totalMiss = 0

    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) { $editions = $editions | Where-Object { $_ -ieq $EditionFilter } }

    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) {
            Write-Log "Edition '$edName' has no editions.$edName block in config.json (failure: cannot verify unknown edition)" -Level "warn"
            continue
        }
        $ed = $Config.editions.$edName
        Write-Log "" -Level "info"
        Write-Log ("Checking edition '" + $edName + "' (" + $ed.contextMenuLabel + ")") -Level "info"

        $perTarget = @()
        foreach ($targetName in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $targetName
            if (-not $hasTarget) {
                Write-Log "  [skip] $targetName -- no registryPaths.$targetName entry in config" -Level "warn"
                continue
            }
            $regPath = $ed.registryPaths.$targetName
            $st = Get-Check10MenuEntryStatus -TargetName $targetName -RegistryPath $regPath -ExpectedLabel $ed.contextMenuLabel
            $perTarget += $st

            $tag = if ($targetName -eq 'directory') { 'folder    ' }
                   elseif ($targetName -eq 'background') { 'background' }
                   else { 'file      ' }
            $regExe = ConvertTo-Check10RegExePath $regPath
            $line = "  [{0}] {1}  {2}" -f $st.verdict, $tag, $regExe
            $level = if ($st.verdict -eq 'PASS') { 'success' } else { 'error' }
            Write-Log $line -Level $level
            if ($st.verdict -ne 'PASS') {
                # Build precise per-failure detail. We list every distinct
                # cause as its own bullet so the user knows exactly what to
                # fix without re-reading the upstream log.
                $bullets = @()
                $items   = @()
                if (-not $st.keyExists) {
                    $bullets += "registry key NOT FOUND: " + $regExe
                    $items   += "<missing key>"
                } else {
                    if (-not $st.labelOk) {
                        $bullets += "value '(Default)' = '" + $st.actualLabel + "' (expected '" + $ed.contextMenuLabel + "')"
                        $items   += "(Default)"
                    }
                    if (-not $st.iconPresent) {
                        $bullets += "value 'Icon' is missing or empty"
                        $items   += "Icon"
                    }
                    if (-not $st.commandPresent) {
                        $bullets += "subkey '\command' (Default) is missing or empty"
                        $items   += "\command\(Default)"
                    } elseif (-not $st.exeResolvable) {
                        $exeShown = if ($st.exePath) { $st.exePath } else { '<unparseable>' }
                        $bullets += "exe path NOT ON DISK: " + $exeShown
                        $items   += "\command\(Default) -> exe"
                    }
                }
                if ($bullets.Count -eq 0) { $bullets = @($st.reason) }

                Write-Log ("           Path : " + $regExe) -Level "error"
                foreach ($b in $bullets) {
                    Write-Log ("           Why  : " + $b) -Level "error"
                }
                Write-Log ("           Fix  : .\run.ps1 repair -Edition " + $edName + "   (re-asserts label/Icon/command from config + resolves exe via installationType)") -Level "warn"

                Add-Check10MissAction -Edition $edName -Category 'install' -Target $targetName `
                    -RegPath $regExe -Items $items `
                    -Reason ($bullets -join '; ') `
                    -FixHint (".\run.ps1 repair -Edition " + $edName) `
                    -InvariantCode 'INSTALL-STATE'
            }
            if ($st.verdict -eq 'PASS') { $totalPass++ } else { $totalMiss++ }
        }

        $editionResults += [pscustomobject]@{
            edition = $edName
            label   = $ed.contextMenuLabel
            targets = $perTarget
        }
    }

    Write-Log "" -Level "info"
    Write-Log ("Verification totals: PASS=" + $totalPass + ", MISS=" + $totalMiss) -Level $(if ($totalMiss -eq 0) { 'success' } else { 'error' })

    return [pscustomobject]@{
        editions  = $editionResults
        totalPass = $totalPass
        totalMiss = $totalMiss
    }
}

# ---------------------------------------------------------------------------
#  Repair invariants
# ---------------------------------------------------------------------------

function Test-Check10RepairEnforced {
    param($Config)
    $hasRepair = $Config.PSObject.Properties.Name -contains 'repair'
    if (-not $hasRepair) { return $true }
    $hasFlag = $Config.repair.PSObject.Properties.Name -contains 'enforceInvariants'
    if (-not $hasFlag) { return $true }
    return [bool]$Config.repair.enforceInvariants
}

function Get-Check10LegacyNames {
    param($Config)
    $hasRepair = $Config.PSObject.Properties.Name -contains 'repair'
    $hasList   = $hasRepair -and ($Config.repair.PSObject.Properties.Name -contains 'legacyNames')
    if ($hasList) { return @($Config.repair.legacyNames) }
    return @(
        'VSCode2','VSCode3','VSCodeOld','VSCode_old',
        'OpenWithCode','OpenWithVSCode','Open with Code','OpenCode',
        'VSCodeInsiders2','VSCodeInsidersOld','OpenWithInsiders'
    )
}

function Get-Check10ShellParentSub {
    param([string]$RegistryPath)
    $sub = Get-HkcrSubPath10 $RegistryPath
    $idx = $sub.LastIndexOf('\')
    if ($idx -lt 0) { return $sub }
    return $sub.Substring(0, $idx)
}

function Invoke-Script10RepairInvariantCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string] $EditionFilter = ""
    )

    $enforced = Test-Check10RepairEnforced -Config $Config
    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) { $editions = $editions | Where-Object { $_ -ieq $EditionFilter } }

    $legacyNames = Get-Check10LegacyNames -Config $Config
    $totalPass = 0
    $totalMiss = 0

    Write-Log "" -Level "info"
    if ($enforced) {
        Write-Log ("Repair invariants: file-target ABSENT, no suppression values, no legacy duplicates (" + $legacyNames.Count + " allow-list names).") -Level "info"
    } else {
        Write-Log "Repair invariants: NOT enforced (config.repair.enforceInvariants = false). Reporting only." -Level "warn"
    }

    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    foreach ($edName in $editions) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) { continue }
        $ed = $Config.editions.$edName
        Write-Log ("Repair-invariant check for edition '" + $edName + "' (" + $ed.contextMenuLabel + ")") -Level "info"

        $passes = 0
        $misses = 0

        # Invariant 1: file-target absent
        $hasFile = $ed.registryPaths.PSObject.Properties.Name -contains 'file'
        if ($hasFile) {
            $fileReg = $ed.registryPaths.file
            $fileRegExe = ConvertTo-Check10RegExePath $fileReg
            $sub = Get-HkcrSubPath10 $fileReg
            $key = $hkcr.OpenSubKey($sub)
            $isAbsent = $null -eq $key
            if (-not $isAbsent) { $key.Close() }
            if ($isAbsent) {
                Write-Log ("  [PASS] file-target absent: " + $fileRegExe) -Level "success"
                $passes++
            } else {
                Write-Log ("  [MISS] [I1-FILE-TARGET] file-target STILL PRESENT  ->  " + $fileRegExe) -Level "error"
                Write-Log ("           Path  : " + $fileRegExe) -Level "error"
                Write-Log  "           Invariant: I1-FILE-TARGET  (file-target key still present)" -Level "error"
                Write-Log  "           Why   : right-clicking individual files shows the menu (should be folders only)" -Level "error"
                Write-Log ("           Fix   : .\run.ps1 repair -Edition " + $edName) -Level "warn"
                Add-Check10MissAction -Edition $edName -Category 'invariant' -Target 'file' `
                    -RegPath $fileRegExe -Items @($fileRegExe) `
                    -Reason "file-target key still present (menu appears on files)" `
                    -FixHint (".\run.ps1 repair -Edition " + $edName) `
                    -InvariantCode 'I1-FILE-TARGET'
                $misses++
            }
        }

        # Invariant 2: no suppression values on directory + background
        foreach ($keep in @('directory','background')) {
            $hasKey = $ed.registryPaths.PSObject.Properties.Name -contains $keep
            if (-not $hasKey) { continue }
            $regPath = $ed.registryPaths.$keep
            $regExe  = ConvertTo-Check10RegExePath $regPath
            $sub = Get-HkcrSubPath10 $regPath
            $key = $hkcr.OpenSubKey($sub)
            $found = @()
            if ($null -ne $key) {
                try {
                    foreach ($v in $key.GetValueNames()) {
                        if ($script:Check10SuppressionValues -contains $v) { $found += $v }
                    }
                } finally { $key.Close() }
            }
            $isClean = $found.Count -eq 0
            if ($isClean) {
                Write-Log ("  [PASS] no suppression values on " + $keep + ": " + $regExe) -Level "success"
                $passes++
            } else {
                Write-Log ("  [MISS] [I2-SUPPRESSION] forbidden value(s) on " + $keep + " -> " + ($found -join ', ') + "   at  " + $regExe) -Level "error"
                Write-Log ("           Path  : " + $regExe) -Level "error"
                Write-Log  "           Invariant: I2-SUPPRESSION  (forbidden value name(s) on directory/background)" -Level "error"
                Write-Log  "           Values:" -Level "error"
                foreach ($vName in $found) {
                    Write-Log ("                    - " + $vName) -Level "error"
                }
                Write-Log  "           Why   : these value names hide the menu in Explorer" -Level "error"
                Write-Log ("           Fix   : .\run.ps1 repair -Edition " + $edName + "   (strips listed values, keeps Default/Icon/command)") -Level "warn"
                Add-Check10MissAction -Edition $edName -Category 'invariant' -Target $keep `
                    -RegPath $regExe -Items $found `
                    -Reason ("suppression values present on " + $keep + ": " + ($found -join ', ')) `
                    -FixHint (".\run.ps1 repair -Edition " + $edName) `
                    -InvariantCode 'I2-SUPPRESSION'
                $misses++
            }
        }

        # Invariant 3: no legacy duplicates under any of the 3 shell parents
        $parentSubs = @{}
        foreach ($t in @('file','directory','background')) {
            $hasT = $ed.registryPaths.PSObject.Properties.Name -contains $t
            if (-not $hasT) { continue }
            $sub = Get-Check10ShellParentSub $ed.registryPaths.$t
            $parentSubs[$sub] = $t
        }
        foreach ($parentSub in $parentSubs.Keys) {
            $assocTarget = $parentSubs[$parentSub]
            $parent = $hkcr.OpenSubKey($parentSub)
            $present = @()
            if ($null -ne $parent) {
                try {
                    foreach ($n in $legacyNames) {
                        $child = $parent.OpenSubKey($n)
                        if ($null -ne $child) { $present += $n; $child.Close() }
                    }
                } finally { $parent.Close() }
            }
            $isClean = $present.Count -eq 0
            $parentExe = "HKCR\" + $parentSub
            if ($isClean) {
                Write-Log ("  [PASS] no legacy duplicates under " + $parentExe) -Level "success"
                $passes++
            } else {
                Write-Log ("  [MISS] [I3-LEGACY-DUP] " + $present.Count + " legacy duplicate child key(s) -> " + ($present -join ', ') + "   under  " + $parentExe) -Level "error"
                Write-Log ("           Path  : " + $parentExe) -Level "error"
                Write-Log  "           Invariant: I3-LEGACY-DUP  (legacy duplicate sibling key(s) under shell parent)" -Level "error"
                Write-Log  "           Children:" -Level "error"
                foreach ($cName in $present) {
                    Write-Log ("                    - " + $parentExe + "\" + $cName) -Level "error"
                }
                Write-Log  "           Why   : duplicate menu entries from legacy installs / partial uninstalls" -Level "error"
                Write-Log ("           Fix   : .\run.ps1 repair -Edition " + $edName + "   (sweeps allow-listed legacyNames only)") -Level "warn"
                Add-Check10MissAction -Edition $edName -Category 'invariant' -Target ('legacy:' + $assocTarget) `
                    -RegPath $parentExe -Items $present `
                    -Reason ("legacy duplicate child keys under " + $parentExe + ": " + ($present -join ', ')) `
                    -FixHint (".\run.ps1 repair -Edition " + $edName) `
                    -InvariantCode 'I3-LEGACY-DUP'
                $misses++
            }
        }

        if ($enforced) {
            $totalPass += $passes
            $totalMiss += $misses
        } else {
            $totalPass += ($passes + $misses)
        }
    }

    Write-Log "" -Level "info"
    $level = if ($totalMiss -eq 0) { 'success' } else { 'error' }
    Write-Log ("Repair-invariant totals: PASS=" + $totalPass + ", MISS=" + $totalMiss + " (enforced=" + $enforced + ")") -Level $level

    return [pscustomobject]@{
        totalPass = $totalPass
        totalMiss = $totalMiss
        enforced  = $enforced
    }
}