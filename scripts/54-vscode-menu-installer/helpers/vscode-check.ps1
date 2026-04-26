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

function Get-HiveAndSubFromRegistryPath {
    <#
    .SYNOPSIS
        Splits a "Registry::<HIVE>\sub\path" string into the .NET RegistryKey
        root for that hive plus the relative sub-path.

    .DESCRIPTION
        Needed because the per-user vs per-machine implementation rewrites
        the original HKCR-based config paths to either:
          Registry::HKEY_CLASSES_ROOT\...                (AllUsers, machine-wide)
          Registry::HKEY_CURRENT_USER\Software\Classes\... (CurrentUser only)
        and the existing reader hard-coded [Microsoft.Win32.Registry]::ClassesRoot,
        which means a CurrentUser-only entry could only be observed via the
        merged HKCR view -- the check verb couldn't tell which hive it lived in.
        This helper returns the right RegistryKey root for either case so we
        can probe the exact hive the install/uninstall path targeted.
    #>
    param([Parameter(Mandatory)] [string] $PsPath)

    $clean = $PsPath -replace '^Registry::', ''
    if ($clean -like 'HKEY_CLASSES_ROOT\*') {
        return [pscustomobject]@{
            Root  = [Microsoft.Win32.Registry]::ClassesRoot
            Sub   = ($clean -replace '^HKEY_CLASSES_ROOT\\', '')
            Hive  = 'HKCR'
        }
    }
    if ($clean -like 'HKEY_CURRENT_USER\*') {
        return [pscustomobject]@{
            Root  = [Microsoft.Win32.Registry]::CurrentUser
            Sub   = ($clean -replace '^HKEY_CURRENT_USER\\', '')
            Hive  = 'HKCU'
        }
    }
    if ($clean -like 'HKEY_LOCAL_MACHINE\*') {
        return [pscustomobject]@{
            Root  = [Microsoft.Win32.Registry]::LocalMachine
            Sub   = ($clean -replace '^HKEY_LOCAL_MACHINE\\', '')
            Hive  = 'HKLM'
        }
    }
    # Unknown hive: surface the exact failing path so the operator can act.
    Write-Log "Unrecognised registry hive in path: '$PsPath' (failure: cannot probe; expected HKCR / HKCU / HKLM prefix)" -Level "warn"
    return $null
}

function Get-VsCodeMenuEntryStatus {
    <#
    .SYNOPSIS
        Inspect a single context-menu key and return a status hashtable.

    .NOTES
        Probes the EXACT hive named in $RegistryPath. When the caller has
        passed the path through Convert-EditionPathsForScope (or supplied
        an HKCU path directly) we read that specific hive instead of the
        merged HKCR view -- so we can confirm "this entry is in HKCU"
        vs "this entry is in HKLM" rather than the ambiguous "it shows up
        in HKCR somehow".
    #>
    param(
        [Parameter(Mandatory)] [string] $TargetName,
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $ExpectedLabel
    )

    $status = [ordered]@{
        target          = $TargetName
        registryPath    = $RegistryPath
        hive            = $null
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
        # Sub-keys/values we EXPECT to find under $RegistryPath. Populated
        # below so callers can report exactly what is missing instead of
        # bailing on the first failure -- the user explicitly asked for
        # "report any missing sub-keys".
        expectedSubkeys = @('(Default)', 'Icon', 'command', 'command\(Default)')
        missingSubkeys  = @()
    }

    $hiveInfo = Get-HiveAndSubFromRegistryPath -PsPath $RegistryPath
    if ($null -eq $hiveInfo) {
        $status.reason = "unrecognised hive in registry path: $RegistryPath"
        # Whole key is unreadable -- everything under it is "missing".
        $status.missingSubkeys = @($status.expectedSubkeys)
        return [pscustomobject]$status
    }
    $sub          = $hiveInfo.Sub
    $root         = $hiveInfo.Root
    $status.hive  = $hiveInfo.Hive

    $key = $root.OpenSubKey($sub)
    $isKeyMissing = $null -eq $key
    if ($isKeyMissing) {
        $status.reason = "registry key not found in $($hiveInfo.Hive): $RegistryPath"
        $status.missingSubkeys = @($status.expectedSubkeys)
        return [pscustomobject]$status
    }
    $status.keyExists = $true
    try {
        $defaultVal = $key.GetValue("")
        $iconVal    = $key.GetValue("Icon")
        $status.actualLabel = [string]$defaultVal
        $status.iconPresent = -not [string]::IsNullOrWhiteSpace([string]$iconVal)
        $status.labelOk     = ($status.actualLabel -eq $ExpectedLabel)
        if ([string]::IsNullOrWhiteSpace([string]$defaultVal)) { $status.missingSubkeys += '(Default)' }
        if (-not $status.iconPresent)                          { $status.missingSubkeys += 'Icon' }
    } finally {
        $key.Close()
    }

    $cmdKey = $root.OpenSubKey("$sub\command")
    $isCmdMissing = $null -eq $cmdKey
    if ($isCmdMissing) {
        $status.missingSubkeys += 'command'
        $status.missingSubkeys += 'command\(Default)'
        # Don't early-return -- collect every missing piece so the report
        # tells the operator the whole story in one pass.
    } else {
        try {
            $cmdLine = [string]$cmdKey.GetValue("")
            $status.commandValue   = $cmdLine
            $status.commandPresent = -not [string]::IsNullOrWhiteSpace($cmdLine)
            if (-not $status.commandPresent) { $status.missingSubkeys += 'command\(Default)' }
        } finally {
            $cmdKey.Close()
        }
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
        if ($status.missingSubkeys.Count -gt 0) {
            $reasons += "missing sub-keys/values: " + (($status.missingSubkeys | Select-Object -Unique) -join ', ')
        }
        $status.reason = ($reasons -join "; ")
    }

    return [pscustomobject]$status
}

function Invoke-VsCodeMenuCheck {
    <#
    .SYNOPSIS
        Run quick verification across every enabled edition + target.

    .DESCRIPTION
        When -Scope is supplied (CurrentUser | AllUsers), every config path
        is first rewritten via Convert-EditionPathsForScope so the probe
        targets the EXACT hive that install/uninstall would have used:

          AllUsers    -> Registry::HKEY_CLASSES_ROOT\...
                         (machine-wide; physically lives in HKLM\Software\Classes)
          CurrentUser -> Registry::HKEY_CURRENT_USER\Software\Classes\...
                         (this user only; never observed in HKLM)

        Without this rewrite, a per-user install would still appear to
        "pass" via the merged HKCR view, masking drift between hives.
    .OUTPUTS
        PSCustomObject with .editions[], .totalPass, .totalMiss
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $LogMsgs,
        [string] $EditionFilter = "",
        [ValidateSet('CurrentUser','AllUsers')]
        [string] $Scope = $null
    )

    $editionResults = @()
    $totalPass = 0
    $totalMiss = 0
    $hasScope  = -not [string]::IsNullOrWhiteSpace($Scope)
    # Verbosity gating (Test-VerbosityAtLeast may be absent for unit tests).
    $atLeastNormal = $true
    $atLeastDebug  = $false
    if (Get-Command Test-VerbosityAtLeast -ErrorAction SilentlyContinue) {
        $atLeastNormal = Test-VerbosityAtLeast -Level 'Normal'
        $atLeastDebug  = Test-VerbosityAtLeast -Level 'Debug'
    }
    if ($hasScope -and $atLeastNormal) {
        Write-Log ("Check scope: '" + $Scope + "' -- probing " +
            $(if ($Scope -eq 'AllUsers') { 'HKEY_CLASSES_ROOT (machine-wide)' }
              else                       { 'HKCU\Software\Classes (per-user)' })) -Level "info"
    } elseif ($atLeastNormal) {
        Write-Log "Check scope: not supplied -- probing original config paths (HKCR merged view)." -Level "info"
    }

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
        # When the caller supplied a scope, rewrite every registryPaths.<target>
        # so subsequent probes hit the right hive. Convert-EditionPathsForScope
        # is a no-op for AllUsers (returns input unchanged) so this is safe to
        # run unconditionally when $hasScope.
        if ($hasScope -and (Get-Command Convert-EditionPathsForScope -ErrorAction SilentlyContinue)) {
            $ed = Convert-EditionPathsForScope -EditionConfig $ed -Scope $Scope
        }

        if ($atLeastNormal) {
            Write-Log "" -Level "info"
            Write-Log ("Checking edition '" + $edName + "' (" + $ed.label + ")") -Level "info"
        }

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
            # PASS rows are noise in Quiet mode; misses always print.
            if ($st.verdict -ne 'PASS' -or $atLeastNormal) {
                Write-Log $line -Level $level
            }
            if ($atLeastDebug) {
                Write-Log ("           [debug] hive=" + $st.hive +
                           ", keyExists=" + $st.keyExists +
                           ", missingSubkeys=" + ($st.missingSubkeys -join ',')) -Level "info"
            }
            if ($st.verdict -ne 'PASS' -and $st.reason) {
                Write-Log ("           reason: " + $st.reason + " (failure path: " + $regPath + ")") -Level "error"
            }
            # CODE RED: when sub-keys/values are missing, list each one on
            # its own line with the exact registry path it should live under.
            if ($st.missingSubkeys -and $st.missingSubkeys.Count -gt 0) {
                $unique = @($st.missingSubkeys | Select-Object -Unique)
                Write-Log ("           missing sub-keys/values (" + $unique.Count + "):") -Level "error"
                foreach ($mk in $unique) {
                    $childPath = if ($mk -eq '(Default)' -or $mk -eq 'Icon') {
                        $regPath + '  -> value: ' + $mk
                    } elseif ($mk -eq 'command') {
                        $regPath + '\command  (subkey missing)'
                    } elseif ($mk -eq 'command\(Default)') {
                        $regPath + '\command  -> value: (Default)'
                    } else {
                        $regPath + '\' + $mk
                    }
                    Write-Log ("             - " + $childPath + " (failure: not present in " + $st.hive + ")") -Level "error"
                }
            }
            if ($st.verdict -eq 'PASS') { $totalPass++ } else { $totalMiss++ }
        }

        $folderResult = $perTarget | Where-Object { $_.target -eq 'directory'  } | Select-Object -First 1
        $bgResult     = $perTarget | Where-Object { $_.target -eq 'background' } | Select-Object -First 1
        $folderTag    = if ($folderResult) { $folderResult.verdict } else { "n/a" }
        $bgTag        = if ($bgResult)     { $bgResult.verdict     } else { "n/a" }

        # Folder + background COVERAGE line -- the user explicitly asked
        # for confirmation that BOTH directory + background verbs exist
        # under the resolved scope.
        $hiveLabel = if ($hasScope) {
            if ($Scope -eq 'AllUsers') { 'HKCR (machine-wide)' }
            else                       { 'HKCU\Software\Classes (per-user)' }
        } else { 'HKCR (merged view)' }

        $folderPresent = ($folderResult -and $folderResult.keyExists)
        $bgPresent     = ($bgResult     -and $bgResult.keyExists)
        $coverageOk    = $folderPresent -and $bgPresent
        $coverageLevel = if ($coverageOk) { 'success' } else { 'error' }
        $coverageTag   = if ($coverageOk) { 'OK  ' } else { 'GAP ' }
        if (-not $coverageOk -or $atLeastNormal) {
            Write-Log ("  [{0}] folder+background coverage in {1}: folder={2}, background={3}" -f `
                $coverageTag, $hiveLabel, $folderTag, $bgTag) -Level $coverageLevel
        }
        if (-not $folderPresent) {
            $missPath = if ($folderResult) { $folderResult.registryPath } else { '(no registryPaths.directory entry in config)' }
            Write-Log ("           - directory verb MISSING at: " + $missPath + " (failure: folder right-click won't show this entry)") -Level "error"
        }
        if (-not $bgPresent) {
            $missPath = if ($bgResult) { $bgResult.registryPath } else { '(no registryPaths.background entry in config)' }
            Write-Log ("           - background verb MISSING at: " + $missPath + " (failure: empty-folder right-click won't show this entry)") -Level "error"
        }
        if ($atLeastNormal) {
            Write-Log ("  summary: folder=" + $folderTag + ", background=" + $bgTag) -Level "info"
        }

        $editionResults += [pscustomobject]@{
            edition   = $edName
            label     = $ed.label
            targets   = $perTarget
            folderOk  = ($folderTag -eq 'PASS')
            bgOk      = ($bgTag     -eq 'PASS')
            folderPresent = $folderPresent
            bgPresent     = $bgPresent
            coverageOk    = $coverageOk
        }
    }

    if ($atLeastNormal) { Write-Log "" -Level "info" }
    # Totals always print.
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

    # Verbosity gating: Quiet hides banner + per-row PASS lines, keeps
    # FAIL rows + totals. Debug adds raw exists/cmdExists probes.
    $atLeastNormal = $true
    $atLeastDebug  = $false
    if (Get-Command Test-VerbosityAtLeast -ErrorAction SilentlyContinue) {
        $atLeastNormal = Test-VerbosityAtLeast -Level 'Normal'
        $atLeastDebug  = Test-VerbosityAtLeast -Level 'Debug'
    }

    if ($atLeastNormal) {
        Write-Log "" -Level "info"
        Write-Log "============================================================" -Level "info"
        Write-Log (" POST-{0} VERIFICATION (scope={1})" -f $Action.ToUpper(), $ResolvedScope) -Level "info"
        Write-Log "============================================================" -Level "info"
    }

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

        if ($atLeastNormal) {
            Write-Log ("Edition: " + $editionName + " (" + $ed.label + ")") -Level "info"
        }

        foreach ($target in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $target
            if (-not $hasTarget) { continue }
            $regPath = $ed.registryPaths.$target
            $exists  = Test-RegistryKeyExists -RegistryPath $regPath

            # Sub-key probe: install MUST also leave a \command\(Default) behind.
            # We collect these in a list so the report can name every missing
            # piece -- not just the parent key.
            $missingChildren = @()
            $cmdPath         = $regPath + '\command'
            $cmdExists       = Test-RegistryKeyExists -RegistryPath $cmdPath
            if ($atLeastDebug) {
                Write-Log ("  [debug] probe: parent exists=" + $exists +
                           ", \command exists=" + $cmdExists + " at " + $regPath) -Level "info"
            }
            if ($Action -eq 'install') {
                if (-not $exists)     { $missingChildren += '(parent key)' }
                if (-not $cmdExists)  { $missingChildren += 'command' }
            }

            if ($Action -eq 'install') {
                $expected = 'present + \\command'
                $isOk     = $exists -and $cmdExists
                $actual   = if ($exists -and $cmdExists)        { 'present + \command' }
                            elseif ($exists -and -not $cmdExists){ 'parent OK, \command MISSING' }
                            else                                 { 'MISSING' }
            } else {
                $expected = 'absent'
                $isOk = -not $exists
                $actual = $(if ($exists) { 'STILL PRESENT' } else { 'absent' })
            }

            $reason = $null
            if (-not $isOk) {
                $reason = "expected=$expected, actual=$actual at $regPath"
                if ($missingChildren.Count -gt 0) {
                    $reason += " (missing: " + ($missingChildren -join ', ') + ")"
                }
            }

            $tag   = if ($isOk) { 'OK  ' } else { 'FAIL' }
            $level = if ($isOk) { 'success' } else { 'error' }
            $line  = "  [{0}] {1,-10} expected={2,-25} actual={3,-30} {4}" -f $tag, $target, $expected, $actual, $regPath
            # PASS rows are noise in Quiet mode; FAIL rows always print.
            if (-not $isOk -or $atLeastNormal) {
                Write-Log $line -Level $level
            }
            if (-not $isOk) {
                Write-Log ("        failure path: " + $regPath + " (reason: " + $reason + ")") -Level "error"
                # Per-sub-key breakdown so the operator sees exactly which
                # piece is gone (matches the read-only check verb's output).
                if ($Action -eq 'install') {
                    if (-not $exists) {
                        Write-Log ("        - missing sub-key: " + $regPath + " (failure: parent key not created)") -Level "error"
                    }
                    if (-not $cmdExists) {
                        Write-Log ("        - missing sub-key: " + $cmdPath + " (failure: \\command not created -- the menu would do nothing)") -Level "error"
                    }
                }
            }

            $details += [pscustomobject]@{
                edition  = $editionName
                target   = $target
                regPath  = $regPath
                expected = $expected
                actual   = $actual
                ok       = $isOk
                reason   = $reason
                missingChildren = $missingChildren
            }
            if ($isOk) { $passCount++ } else { $failCount++ }
        }

        # Folder + background coverage line per edition (install only --
        # uninstall already wants both gone, so the per-target FAIL/OK
        # rows above tell the same story without an extra summary).
        if ($Action -eq 'install') {
            $folderRow = $details | Where-Object { $_.edition -eq $editionName -and $_.target -eq 'directory'  } | Select-Object -Last 1
            $bgRow     = $details | Where-Object { $_.edition -eq $editionName -and $_.target -eq 'background' } | Select-Object -Last 1
            $folderOk  = ($folderRow -and $folderRow.ok)
            $bgOk      = ($bgRow     -and $bgRow.ok)
            $covOk     = $folderOk -and $bgOk
            $covTag    = if ($covOk) { 'OK  ' } else { 'GAP ' }
            $covLevel  = if ($covOk) { 'success' } else { 'error' }
            # In Quiet mode, only print the coverage line when it's a GAP.
            if (-not $covOk -or $atLeastNormal) {
                Write-Log ("  [{0}] folder+background coverage under scope='{1}': folder={2}, background={3}" -f `
                    $covTag, $ResolvedScope, `
                    $(if ($folderOk) { 'OK' } else { 'GAP' }), `
                    $(if ($bgOk)     { 'OK' } else { 'GAP' })) -Level $covLevel
            }
            if (-not $folderOk -and $folderRow) {
                Write-Log ("           - directory verb gap at: " + $folderRow.regPath) -Level "error"
            }
            if (-not $bgOk -and $bgRow) {
                Write-Log ("           - background verb gap at: " + $bgRow.regPath) -Level "error"
            }
        }
    }

    if ($atLeastNormal) { Write-Log "" -Level "info" }
    # Totals always print -- this is the bottom-line CI signal.
    $sumLevel = if ($failCount -eq 0) { 'success' } else { 'error' }
    Write-Log ("Verification totals (scope=" + $ResolvedScope + ", action=" + $Action +
               "): PASS=" + $passCount + ", FAIL=" + $failCount) -Level $sumLevel

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
    .NOTES
        Verbosity-aware (helpers/verbosity.ps1):
          Quiet   -- only totals + failures (no banner, no per-row dump).
          Normal  -- banner + per-row added/removed/skipped + failures.
          Debug   -- everything Normal shows + raw record counts header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [ValidateSet('install','uninstall')] [string] $Action
    )

    # Resolve once; default to "Normal" if verbosity helper isn't loaded.
    $atLeastNormal = $true
    $atLeastDebug  = $false
    if (Get-Command Test-VerbosityAtLeast -ErrorAction SilentlyContinue) {
        $atLeastNormal = Test-VerbosityAtLeast -Level 'Normal'
        $atLeastDebug  = Test-VerbosityAtLeast -Level 'Debug'
    }

    if ($atLeastNormal) {
        Write-Log "" -Level "info"
        Write-Log "------------------------------------------------------------" -Level "info"
        Write-Log " REGISTRY CHANGE REPORT" -Level "info"
    }
    $scopeLabel = if ($Summary.PSObject.Properties.Name -contains 'scope' -and $Summary.scope) { $Summary.scope } else { 'unknown' }
    if ($atLeastNormal) {
        Write-Log (" Resolved scope: " + $scopeLabel + "  (hive actually touched this run)") -Level "info"
        Write-Log "------------------------------------------------------------" -Level "info"
    }
    if ($atLeastDebug) {
        Write-Log (" [debug] raw record counts: added=" + $Summary.totalAdded +
                   ", removed=" + $Summary.totalRemoved +
                   ", skipped=" + $Summary.totalSkipped +
                   ", failed="  + $Summary.totalFailed) -Level "info"
    }

    if ($Summary.totalAdded -gt 0) {
        if ($atLeastNormal) {
            Write-Log ("Added ({0}):" -f $Summary.totalAdded) -Level "success"
            foreach ($a in $Summary.added) {
                $rowScope = if ($a.PSObject.Properties.Name -contains 'scope' -and $a.scope) { $a.scope } else { $scopeLabel }
                Write-Log ("  + [{0}/{1}/{2}] {3}" -f $rowScope, $a.edition, $a.target, $a.regPath) -Level "success"
            }
        }
    } elseif ($Action -eq 'install') {
        # Always surface a 0-add install -- this is a real anomaly.
        Write-Log "Added (0): no new keys were written this run." -Level "warn"
    }

    if ($Summary.totalRemoved -gt 0) {
        if ($atLeastNormal) {
            Write-Log ("Removed ({0}):" -f $Summary.totalRemoved) -Level "success"
            foreach ($r in $Summary.removed) {
                $rowScope = if ($r.PSObject.Properties.Name -contains 'scope' -and $r.scope) { $r.scope } else { $scopeLabel }
                Write-Log ("  - [{0}/{1}/{2}] {3}" -f $rowScope, $r.edition, $r.target, $r.regPath) -Level "success"
            }
        }
    } elseif ($Action -eq 'uninstall') {
        Write-Log "Removed (0): nothing was actually deleted this run." -Level "warn"
    }

    # Skipped rows are noise in Quiet mode.
    if ($Summary.totalSkipped -gt 0 -and $atLeastNormal) {
        Write-Log ("Skipped / already absent ({0}):" -f $Summary.totalSkipped) -Level "info"
        foreach ($s in $Summary.skipped) {
            $rowScope = if ($s.PSObject.Properties.Name -contains 'scope' -and $s.scope) { $s.scope } else { $scopeLabel }
            Write-Log ("  ~ [{0}/{1}/{2}] {3}" -f $rowScope, $s.edition, $s.target, $s.regPath) -Level "info"
        }
    }

    # Failures ALWAYS print regardless of verbosity (per Write-VLog contract).
    if ($Summary.totalFailed -gt 0) {
        Write-Log ("FAILED ({0}):" -f $Summary.totalFailed) -Level "error"
        foreach ($f in $Summary.failed) {
            $reason = if ($f.reason) { $f.reason } else { "no reason captured" }
            $rowScope = if ($f.PSObject.Properties.Name -contains 'scope' -and $f.scope) { $f.scope } else { $scopeLabel }
            Write-Log ("  ! [{0}/{1}/{2}] {3} (failure: {4})" -f $rowScope, $f.edition, $f.target, $f.regPath, $reason) -Level "error"
        }
    }

    $hasNoChanges = ($Summary.totalAdded + $Summary.totalRemoved + $Summary.totalFailed + $Summary.totalSkipped) -eq 0
    if ($hasNoChanges) {
        # Always loud -- a no-op verification run is meaningful info.
        Write-Log "No registry change events were recorded for this run." -Level "warn"
    }

    if ($Summary.auditPath -and $atLeastNormal) {
        Write-Log ("Full JSONL trail: " + $Summary.auditPath) -Level "info"
    }
}
