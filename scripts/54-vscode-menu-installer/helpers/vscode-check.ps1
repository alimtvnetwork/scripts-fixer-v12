<#
.SYNOPSIS
    Quick read-only verification of VS Code context-menu registry entries.

.DESCRIPTION
    For every enabled edition in config.json, inspects the three target
    keys (file / directory / background) and reports:
      - key exists           ([Microsoft.Win32.Registry]::ClassesRoot)
      - (Default) label matches config label
      - Icon value present
      - \command (Default) is non-empty
      - the exe path embedded in the command resolves on disk

    Pure read-only -- never writes to the registry. Returns a structured
    result object so callers (run.ps1, CI) can react to PASS / MISS counts.

    Naming follows project convention: is/has booleans, no bare -not.
#>

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function Get-HkcrSubkeyPathLocal {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function Get-VsCodeMenuEntryStatus {
    <#
    .SYNOPSIS
        Inspect a single context-menu key and return a status hashtable.
    #>
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

    $sub  = Get-HkcrSubkeyPathLocal $RegistryPath
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
    } finally {
        $key.Close()
    }

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
    } finally {
        $cmdKey.Close()
    }

    # Extract the first quoted token = exe path
    $hasMatch = $status.commandValue -match '^\s*"([^"]+)"'
    if ($hasMatch) {
        $exe = $Matches[1]
        $expanded = [System.Environment]::ExpandEnvironmentVariables($exe)
        $status.exePath       = $expanded
        $status.exeResolvable = Test-Path -LiteralPath $expanded
    }

    # Verdict: every check must pass
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

function Invoke-VsCodeMenuCheck {
    <#
    .SYNOPSIS
        Run quick verification across every enabled edition + target.
    .OUTPUTS
        PSCustomObject with .editions[], .totalPass, .totalMiss
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $LogMsgs,
        [string] $EditionFilter = ""
    )

    $editionResults = @()
    $totalPass = 0
    $totalMiss = 0

    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) {
        $editions = $editions | Where-Object { $_ -ieq $EditionFilter }
    }

    foreach ($edName in $editions) {
        $hasEditionBlock = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEditionBlock) {
            Write-Log "Edition '$edName' has no editions.$edName block in config.json (failure: cannot verify unknown edition)" -Level "warn"
            continue
        }
        $ed = $Config.editions.$edName

        Write-Log "" -Level "info"
        Write-Log ("Checking edition '" + $edName + "' (" + $ed.label + ")") -Level "info"

        $perTarget = @()
        foreach ($targetName in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $targetName
            if (-not $hasTarget) {
                Write-Log "  [skip] $targetName -- no registryPaths.$targetName entry in config" -Level "warn"
                continue
            }
            $regPath = $ed.registryPaths.$targetName
            $st = Get-VsCodeMenuEntryStatus -TargetName $targetName -RegistryPath $regPath -ExpectedLabel $ed.label
            $perTarget += $st

            $tag = if ($targetName -eq 'directory') { 'folder    ' }
                   elseif ($targetName -eq 'background') { 'background' }
                   else { 'file      ' }
            $line = "  [{0}] {1}  {2}" -f $st.verdict, $tag, $regPath
            $level = if ($st.verdict -eq 'PASS') { 'success' } else { 'error' }
            Write-Log $line -Level $level
            if ($st.verdict -ne 'PASS' -and $st.reason) {
                Write-Log ("           reason: " + $st.reason + " (failure path: " + $regPath + ")") -Level "error"
            }
            if ($st.verdict -eq 'PASS') { $totalPass++ } else { $totalMiss++ }
        }

        $folderResult = $perTarget | Where-Object { $_.target -eq 'directory'  } | Select-Object -First 1
        $bgResult     = $perTarget | Where-Object { $_.target -eq 'background' } | Select-Object -First 1
        $folderTag    = if ($folderResult) { $folderResult.verdict } else { "n/a" }
        $bgTag        = if ($bgResult)     { $bgResult.verdict     } else { "n/a" }
        Write-Log ("  summary: folder=" + $folderTag + ", background=" + $bgTag) -Level "info"

        $editionResults += [pscustomobject]@{
            edition   = $edName
            label     = $ed.label
            targets   = $perTarget
            folderOk  = ($folderTag -eq 'PASS')
            bgOk      = ($bgTag     -eq 'PASS')
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

function Test-RegistryKeyExists {
    <#
    .SYNOPSIS
        Lightweight HKCR/HKCU existence probe used by post-op verification.
        Accepts the same "Registry::HKEY_*\..." path format the rest of
        the script uses; returns $true/$false. Never throws.
    #>
    param([Parameter(Mandatory)] [string] $RegistryPath)
    try {
        return [bool](Test-Path -LiteralPath $RegistryPath -ErrorAction Stop)
    } catch {
        Write-Log "Failed to probe registry path: $RegistryPath (failure: $($_.Exception.Message))" -Level "warn"
        return $false
    }
}

function Invoke-PostOpVerification {
    <#
    .SYNOPSIS
        Dedicated post-install / post-uninstall verification step.

    .DESCRIPTION
        For every enabled edition + target listed in $Config (already
        rewritten for the resolved scope by the caller), confirms the
        registry key is in the expected state:
          Action='install'   -> key MUST exist + label/icon/command sane
          Action='uninstall' -> key MUST NOT exist

        Prints a clear human-readable report block, then returns a summary
        object so the caller can fold the verification result into its
        own exit status / final log line.

    .OUTPUTS
        PSCustomObject:
          .action        ('install' | 'uninstall')
          .scope         (resolved scope string)
          .pass / .fail  (per-target counts across all editions)
          .details       array of @{ edition; target; regPath; expected; actual; ok; reason }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('install','uninstall')] [string] $Action,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $ResolvedScope,
        [Parameter(Mandatory)] $LogMsgs,
        # Pre-rewritten edition configs keyed by edition name. The caller
        # has already passed each through Convert-EditionPathsForScope so
        # the paths point at the right hive (HKCR vs HKCU\Software\Classes).
        [Parameter(Mandatory)] [hashtable] $ScopedEditions
    )

    Write-Log "" -Level "info"
    Write-Log "============================================================" -Level "info"
    Write-Log (" POST-{0} VERIFICATION (scope={1})" -f $Action.ToUpper(), $ResolvedScope) -Level "info"
    Write-Log "============================================================" -Level "info"

    $details = @()
    $passCount = 0
    $failCount = 0

    foreach ($editionName in $ScopedEditions.Keys) {
        $ed = $ScopedEditions[$editionName]
        $hasPaths = $ed.PSObject.Properties.Name -contains 'registryPaths'
        if (-not $hasPaths) {
            Write-Log ("  [skip] edition '" + $editionName + "' has no registryPaths block") -Level "warn"
            continue
        }

        Write-Log ("Edition: " + $editionName + " (" + $ed.label + ")") -Level "info"

        foreach ($target in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $target
            if (-not $hasTarget) { continue }
            $regPath = $ed.registryPaths.$target
            $exists  = Test-RegistryKeyExists -RegistryPath $regPath

            if ($Action -eq 'install') {
                $expected = 'present'
                $isOk = $exists
                $actual = $(if ($exists) { 'present' } else { 'MISSING' })
            } else {
                $expected = 'absent'
                $isOk = -not $exists
                $actual = $(if ($exists) { 'STILL PRESENT' } else { 'absent' })
            }

            $reason = $null
            if (-not $isOk) {
                $reason = "expected=$expected, actual=$actual at $regPath"
            }

            $tag   = if ($isOk) { 'OK  ' } else { 'FAIL' }
            $level = if ($isOk) { 'success' } else { 'error' }
            $line  = "  [{0}] {1,-10} expected={2,-7} actual={3,-13} {4}" -f $tag, $target, $expected, $actual, $regPath
            Write-Log $line -Level $level
            if (-not $isOk) {
                Write-Log ("        failure path: " + $regPath + " (reason: " + $reason + ")") -Level "error"
            }

            $details += [pscustomobject]@{
                edition  = $editionName
                target   = $target
                regPath  = $regPath
                expected = $expected
                actual   = $actual
                ok       = $isOk
                reason   = $reason
            }
            if ($isOk) { $passCount++ } else { $failCount++ }
        }
    }

    Write-Log "" -Level "info"
    $sumLevel = if ($failCount -eq 0) { 'success' } else { 'error' }
    Write-Log ("Verification totals: PASS=" + $passCount + ", FAIL=" + $failCount) -Level $sumLevel

    return [pscustomobject]@{
        action  = $Action
        scope   = $ResolvedScope
        pass    = $passCount
        fail    = $failCount
        details = $details
    }
}

function Write-RegistryAuditReport {
    <#
    .SYNOPSIS
        Render the audit summary as a clear, grouped log block so the
        user can see at a glance every key the script ADDED, REMOVED,
        SKIPPED (already absent), or FAILED on -- without opening the
        JSONL file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [ValidateSet('install','uninstall')] [string] $Action
    )

    Write-Log "" -Level "info"
    Write-Log "------------------------------------------------------------" -Level "info"
    Write-Log " REGISTRY CHANGE REPORT" -Level "info"
    Write-Log "------------------------------------------------------------" -Level "info"

    if ($Summary.totalAdded -gt 0) {
        Write-Log ("Added ({0}):" -f $Summary.totalAdded) -Level "success"
        foreach ($a in $Summary.added) {
            Write-Log ("  + [{0}/{1}] {2}" -f $a.edition, $a.target, $a.regPath) -Level "success"
        }
    } elseif ($Action -eq 'install') {
        Write-Log "Added (0): no new keys were written this run." -Level "warn"
    }

    if ($Summary.totalRemoved -gt 0) {
        Write-Log ("Removed ({0}):" -f $Summary.totalRemoved) -Level "success"
        foreach ($r in $Summary.removed) {
            Write-Log ("  - [{0}/{1}] {2}" -f $r.edition, $r.target, $r.regPath) -Level "success"
        }
    } elseif ($Action -eq 'uninstall') {
        Write-Log "Removed (0): nothing was actually deleted this run." -Level "warn"
    }

    if ($Summary.totalSkipped -gt 0) {
        Write-Log ("Skipped / already absent ({0}):" -f $Summary.totalSkipped) -Level "info"
        foreach ($s in $Summary.skipped) {
            Write-Log ("  ~ [{0}/{1}] {2}" -f $s.edition, $s.target, $s.regPath) -Level "info"
        }
    }

    if ($Summary.totalFailed -gt 0) {
        Write-Log ("FAILED ({0}):" -f $Summary.totalFailed) -Level "error"
        foreach ($f in $Summary.failed) {
            $reason = if ($f.reason) { $f.reason } else { "no reason captured" }
            Write-Log ("  ! [{0}/{1}] {2} (failure: {3})" -f $f.edition, $f.target, $f.regPath, $reason) -Level "error"
        }
    }

    $hasNoChanges = ($Summary.totalAdded + $Summary.totalRemoved + $Summary.totalFailed + $Summary.totalSkipped) -eq 0
    if ($hasNoChanges) {
        Write-Log "No registry change events were recorded for this run." -Level "warn"
    }

    if ($Summary.auditPath) {
        Write-Log ("Full JSONL trail: " + $Summary.auditPath) -Level "info"
    }
}
