<#
.SYNOPSIS
    Helpers for the folder-only VS Code context menu repair (script 52).

.DESCRIPTION
    Reuses the registry conversion + VS Code path resolution helpers from
    script 10. Adds focused remove / ensure / verify operations that operate
    only on the targets listed in config.json (removeFromTargets,
    ensureOnTargets) plus an explorer.exe restart routine.
#>

# -- Bootstrap shared logging --------------------------------------------------
$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# -- Reuse helpers from script 10 ---------------------------------------------
$_script10Helpers = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "10-vscode-context-menu-fix\helpers\registry.ps1"
if (Test-Path $_script10Helpers) {
    . $_script10Helpers
} else {
    throw "Required helper not found: $_script10Helpers (script 10 must remain present)"
}

function ConvertTo-RegPathLocal {
    # Local alias for ConvertTo-RegPath in case caller needs it without dot-source order issues.
    param([string]$PsPath)
    return (ConvertTo-RegPath $PsPath)
}

function Remove-ContextMenuTarget {
    <#
    .SYNOPSIS
        Removes a single registry-based context menu entry and its \command subkey.
        Logs exact path + reason on every failure (CODE RED rule).
    #>
    param(
        [string]$TargetName,
        [string]$RegistryPath,
        [PSObject]$LogMsgs
    )

    $regPath = ConvertTo-RegPath $RegistryPath
    $isPresent = $false
    $null = reg.exe query $regPath 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)

    if (-not $isPresent) {
        Write-Log (($LogMsgs.messages.targetMissing -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "info"
        return $true
    }

    Write-Log (($LogMsgs.messages.removingTarget -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "info"

    try {
        $null = reg.exe delete $regPath /f 2>&1
        $hasFailed = ($LASTEXITCODE -ne 0)
        if ($hasFailed) {
            $msg = ($LogMsgs.messages.removeFailed -replace '\{target\}', $TargetName) `
                                                   -replace '\{path\}',   $regPath `
                                                   -replace '\{error\}',  ("reg.exe exit " + $LASTEXITCODE)
            Write-Log $msg -Level "error"
            return $false
        }
        Write-Log (($LogMsgs.messages.removed -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "success"
        return $true
    } catch {
        $msg = ($LogMsgs.messages.removeFailed -replace '\{target\}', $TargetName) `
                                               -replace '\{path\}',   $regPath `
                                               -replace '\{error\}',  $_
        Write-Log $msg -Level "error"
        return $false
    }
}

function Set-FolderContextMenuEntry {
    <#
    .SYNOPSIS
        Ensures the folder (Directory) context menu entry exists with correct
        label, icon and command pointing at the resolved VS Code executable.
    #>
    param(
        [string]$TargetName,
        [string]$RegistryPath,
        [string]$Label,
        [string]$VsCodeExe,
        [PSObject]$LogMsgs
    )

    $regPath  = ConvertTo-RegPath $RegistryPath
    $iconVal  = "`"$VsCodeExe`""
    $cmdArg   = "`"$VsCodeExe`" `"%V`""

    Write-Log (($LogMsgs.messages.ensuringTarget -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "info"

    try {
        $subKeyPath = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

        $key = $hkcr.CreateSubKey($subKeyPath)
        $key.SetValue("",     $Label)
        $key.SetValue("Icon", $iconVal)
        $key.Close()

        $cmdKey = $hkcr.CreateSubKey("$subKeyPath\command")
        $cmdKey.SetValue("", $cmdArg)
        $cmdKey.Close()

        $msg = ($LogMsgs.messages.ensureSet -replace '\{target\}', $TargetName) `
                                            -replace '\{label\}',  $Label `
                                            -replace '\{path\}',   $regPath
        Write-Log $msg -Level "success"
        return $true
    } catch {
        $msg = ($LogMsgs.messages.ensureFailed -replace '\{target\}', $TargetName) `
                                               -replace '\{path\}',   $regPath `
                                               -replace '\{error\}',  $_
        Write-Log $msg -Level "error"
        return $false
    }
}

function Test-TargetState {
    <#
    .SYNOPSIS
        Verifies a target is in the expected state (present | absent).
    #>
    param(
        [string]$TargetName,
        [string]$RegistryPath,
        [ValidateSet("present","absent")][string]$Expected,
        [PSObject]$LogMsgs
    )

    $regPath = ConvertTo-RegPath $RegistryPath
    $null = reg.exe query $regPath 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)

    if ($Expected -eq "absent") {
        if ($isPresent) {
            Write-Log (($LogMsgs.messages.unexpectedPresent -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "error"
            return $false
        }
        Write-Log (($LogMsgs.messages.expectedAbsent -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "success"
        return $true
    }

    if ($isPresent) {
        Write-Log (($LogMsgs.messages.expectedPresent -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "success"
        return $true
    }
    Write-Log (($LogMsgs.messages.unexpectedAbsent -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath) -Level "error"
    return $false
}

# --------------------------------------------------------------------------
#  Friendly mapping: registry "target" name -> the real-world Explorer
#  right-click scenario the user actually sees. Keep this in sync with
#  config.removeFromTargets / config.ensureOnTargets.
# --------------------------------------------------------------------------
$script:_TargetScenarioMap = @{
    'directory'  = 'Right-click ON a folder'
    'background' = 'Right-click on EMPTY space inside a folder'
    'file'       = 'Right-click on a FILE'
}

function Get-TargetScenario {
    param([string]$TargetName)
    $hasMapping = $script:_TargetScenarioMap.ContainsKey($TargetName)
    if ($hasMapping) { return $script:_TargetScenarioMap[$TargetName] }
    return "Right-click target: $TargetName"
}

function Write-VerificationSummary {
    <#
    .SYNOPSIS
        Renders a colored PASS/FAIL table contrasting where the VS Code
        entry must be PRESENT (folder right-clicks) vs ABSENT (empty
        space / file right-clicks). Returns $true if every row passed.
    .PARAMETER Results
        Array of hashtables with keys:
          Edition  -- e.g. 'stable'
          Target   -- registry target key ('directory','background','file')
          Expected -- 'present' | 'absent'
          Actual   -- 'present' | 'absent'
          Pass     -- [bool]
          Path     -- registry path that was checked
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  Context Menu Verification Summary' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('  {0,-9}  {1,-11}  {2,-44}  {3,-8}  {4}' -f 'EDITION','TARGET','SCENARIO','EXPECT','RESULT') -ForegroundColor DarkGray
    Write-Host ('  {0}' -f ('-' * 96)) -ForegroundColor DarkGray

    $passCount = 0
    $failCount = 0

    foreach ($row in $Results) {
        $scenario = Get-TargetScenario -TargetName $row.Target
        $isPass   = [bool]$row.Pass
        $label    = if ($isPass) { 'PASS' } else { 'FAIL' }
        $color    = if ($isPass) { 'Green' } else { 'Red' }
        if ($isPass) { $passCount++ } else { $failCount++ }

        Write-Host ('  {0,-9}  {1,-11}  {2,-44}  {3,-8}  ' -f `
            $row.Edition, $row.Target, $scenario, $row.Expected.ToUpper()) `
            -ForegroundColor White -NoNewline
        Write-Host $label -ForegroundColor $color

        # On failure, surface actual + path so the user can investigate.
        if (-not $isPass) {
            Write-Host ('             actual: {0}  ({1})' -f $row.Actual.ToUpper(), $row.Path) -ForegroundColor DarkRed
        }
    }

    Write-Host ('  {0}' -f ('-' * 96)) -ForegroundColor DarkGray
    $totalColor = if ($failCount -eq 0) { 'Green' } else { 'Red' }
    $totalLabel = if ($failCount -eq 0) { 'OVERALL: PASS' } else { 'OVERALL: FAIL' }
    Write-Host ('  {0}   pass={1}   fail={2}   total={3}' -f `
        $totalLabel, $passCount, $failCount, $Results.Count) -ForegroundColor $totalColor
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''

    return ($failCount -eq 0)
}

function Restart-Explorer {
    <#
    .SYNOPSIS
        Stops and restarts explorer.exe so context menu changes take effect
        without requiring a full sign-out.
    #>
    param(
        [int]$WaitMs = 800,
        [PSObject]$LogMsgs
    )

    Write-Log $LogMsgs.messages.restartingExplorer -Level "info"
    try {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill() } catch { }
        }
        Write-Log $LogMsgs.messages.explorerStopped -Level "success"

        Start-Sleep -Milliseconds $WaitMs

        $isExplorerStillRunning = $null -ne (Get-Process -Name explorer -ErrorAction SilentlyContinue)
        if (-not $isExplorerStillRunning) {
            Start-Process -FilePath "explorer.exe" | Out-Null
        }
        Write-Log $LogMsgs.messages.explorerStarted -Level "success"
        return $true
    } catch {
        Write-Log ($LogMsgs.messages.explorerFailed -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Invoke-ShellRefresh {
    <#
    .SYNOPSIS
        Minimal shell refresh -- forces Explorer to reload context menus,
        icon cache, and shell associations WITHOUT killing explorer.exe.

    .DESCRIPTION
        Sends two well-known notifications:
          1) SHChangeNotify(SHCNE_ASSOCCHANGED) -- tells the shell to flush
             cached file/registry associations (the bag that drives the
             right-click menu).
          2) WM_SETTINGCHANGE broadcast with lParam = 'Environment' -- nudges
             every top-level window to re-read environment + shell settings.

        This is the lightest possible "post-repair" hook: no processes are
        killed, no taskbar flicker, no open Explorer windows are closed.
        On rare cases where the menu cache is genuinely stuck (very old
        Windows 10 builds, or after corrupted registry edits) callers can
        pass -FullRestart to fall back to the classic Restart-Explorer.

    .PARAMETER FullRestart
        If set, ALSO kills + relaunches explorer.exe after the lightweight
        refresh. Equivalent to the old behaviour. Off by default.

    .PARAMETER WaitMs
        Forwarded to Restart-Explorer when -FullRestart is on.

    .PARAMETER SendAssoc
        If set, sends SHChangeNotify(SHCNE_ASSOCCHANGED). Default: ON.
        Use -SendAssoc:$false to skip.

    .PARAMETER SendBroadcast
        If set, sends WM_SETTINGCHANGE broadcast with lParam='Environment'.
        Default: ON. Use -SendBroadcast:$false to skip.

        At least one of SendAssoc / SendBroadcast must be enabled, otherwise
        the function logs an error and returns $false.
    #>
    param(
        [PSObject]$LogMsgs,
        [switch]$FullRestart,
        [int]$WaitMs = 800,
        [bool]$SendAssoc = $true,
        [bool]$SendBroadcast = $true
    )

    Write-Log $LogMsgs.messages.refreshingShell -Level "info"

    $isNothingSelected = (-not $SendAssoc) -and (-not $SendBroadcast) -and (-not $FullRestart)
    if ($isNothingSelected) {
        Write-Log $LogMsgs.messages.refreshNothingSelected -Level "error"
        return $false
    }

    # Print the exact plan up-front so the user sees what will be sent.
    $planParts = @()
    if ($SendAssoc)     { $planParts += "SHChangeNotify(SHCNE_ASSOCCHANGED=0x08000000, SHCNF_IDLIST=0x0000, NULL, NULL)" }
    if ($SendBroadcast) { $planParts += "SendMessageTimeout(HWND_BROADCAST=0xFFFF, WM_SETTINGCHANGE=0x001A, 0, 'Environment', SMTO_ABORTIFHUNG=0x0002, 5000ms)" }
    if ($FullRestart)   { $planParts += "Restart-Explorer(WaitMs=$WaitMs)" }
    $planText = if ($planParts.Count -gt 0) { $planParts -join ' | ' } else { '(none)' }
    Write-Log (($LogMsgs.messages.refreshPlan -replace '\{plan\}', $planText)) -Level "info"

    $hasFailed = $false

    # Track per-step outcomes for the final on-screen summary.
    # Values: 'sent' | 'skipped' | 'failed'
    $stepStatus = [ordered]@{
        'SHChangeNotify(SHCNE_ASSOCCHANGED)'             = 'skipped'
        "WM_SETTINGCHANGE broadcast ('Environment')"     = 'skipped'
        'Restart-Explorer (full kill+relaunch)'          = 'skipped'
    }

    # 1) SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL)
    if ($SendAssoc) { try {
        $shellApiSig = @'
using System;
using System.Runtime.InteropServices;
public static class ShellNotify {
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
        $isTypeMissing = -not ('ShellNotify' -as [type])
        if ($isTypeMissing) {
            Add-Type -TypeDefinition $shellApiSig -ErrorAction Stop
        }

        # SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0x0000
        Write-Log (($LogMsgs.messages.refreshSendingAssoc)) -Level "info"
        [ShellNotify]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-Log $LogMsgs.messages.refreshAssocOk -Level "success"
        $stepStatus['SHChangeNotify(SHCNE_ASSOCCHANGED)'] = 'sent'
    } catch {
        $hasFailed = $true
        $reason = "SHChangeNotify failed -- reason: $($_.Exception.Message)"
        Write-Log (($LogMsgs.messages.refreshFailed -replace '\{step\}', 'SHChangeNotify') -replace '\{error\}', $reason) -Level "error"
        $stepStatus['SHChangeNotify(SHCNE_ASSOCCHANGED)'] = 'failed'
    } } else {
        Write-Log (($LogMsgs.messages.refreshSkipped -replace '\{step\}', 'SHChangeNotify(SHCNE_ASSOCCHANGED)')) -Level "info"
    }

    # 2) WM_SETTINGCHANGE broadcast (HWND_BROADCAST = 0xFFFF, WM_SETTINGCHANGE = 0x001A)
    if ($SendBroadcast) { try {
        # Ensure the P/Invoke type is loaded even when SendAssoc was skipped.
        $isTypeMissing = -not ('ShellNotify' -as [type])
        if ($isTypeMissing) {
            $shellApiSig2 = @'
using System;
using System.Runtime.InteropServices;
public static class ShellNotify {
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
            Add-Type -TypeDefinition $shellApiSig2 -ErrorAction Stop
        }

        $isTypePresent = ('ShellNotify' -as [type]) -ne $null
        if ($isTypePresent) {
            $result = [UIntPtr]::Zero
            # SMTO_ABORTIFHUNG = 0x0002, 5000ms timeout
            Write-Log (($LogMsgs.messages.refreshSendingBroadcast)) -Level "info"
            [void][ShellNotify]::SendMessageTimeout(
                [IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, "Environment",
                0x0002, 5000, [ref]$result)
            Write-Log $LogMsgs.messages.refreshBroadcastOk -Level "success"
            $stepStatus["WM_SETTINGCHANGE broadcast ('Environment')"] = 'sent'
        }
    } catch {
        $hasFailed = $true
        $reason = "WM_SETTINGCHANGE broadcast failed -- reason: $($_.Exception.Message)"
        Write-Log (($LogMsgs.messages.refreshFailed -replace '\{step\}', 'WM_SETTINGCHANGE') -replace '\{error\}', $reason) -Level "error"
        $stepStatus["WM_SETTINGCHANGE broadcast ('Environment')"] = 'failed'
    } } else {
        Write-Log (($LogMsgs.messages.refreshSkipped -replace '\{step\}', "WM_SETTINGCHANGE broadcast ('Environment')")) -Level "info"
    }

    if ($FullRestart) {
        Write-Log $LogMsgs.messages.refreshFullRestart -Level "info"
        $okRestart = Restart-Explorer -WaitMs $WaitMs -LogMsgs $LogMsgs
        if ($okRestart) {
            $stepStatus['Restart-Explorer (full kill+relaunch)'] = 'sent'
        } else {
            $stepStatus['Restart-Explorer (full kill+relaunch)'] = 'failed'
            $hasFailed = $true
        }
    }

    # ---- On-screen summary (always printed) --------------------------------
    Write-Host ""
    Write-Host $LogMsgs.messages.refreshSummaryHeader -ForegroundColor Cyan
    foreach ($step in $stepStatus.Keys) {
        $status = $stepStatus[$step]
        switch ($status) {
            'sent' {
                $line = ($LogMsgs.messages.refreshSummarySent -replace '\{step\}', $step)
                Write-Host $line -ForegroundColor Green
            }
            'failed' {
                $line = ($LogMsgs.messages.refreshSummaryFailed -replace '\{step\}', $step)
                Write-Host $line -ForegroundColor Red
            }
            default {
                $line = ($LogMsgs.messages.refreshSummarySkipped -replace '\{step\}', $step)
                Write-Host $line -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""

    if (-not $hasFailed) {
        Write-Log $LogMsgs.messages.refreshDone -Level "success"
        return $true
    }
    return $false
}

function Test-VsCodeHandlersRegistered {
    <#
    .SYNOPSIS
        Verifies that VS Code context menu handlers are registered in the
        Windows registry and prints PASS/FAIL per target. Read-only.

    .DESCRIPTION
        For each enabled edition, checks the three classic targets
        (file, directory, background). For each target listed in the
        repair's ensureOnTargets the handler MUST be present and have a
        non-empty (default) value on the \command subkey. Targets listed
        in removeFromTargets MUST be absent. Anything else is reported
        as SKIP.

        Returns a hashtable:
            @{
                ok           = [bool]   # true only when all in-scope checks passed
                totalChecked = [int]
                totalFailed  = [int]
                editions     = [ordered]@{ <name> = @{ label=..; targets = @( @{...} ) } }
            }
        Each target entry contains: target, registryPath, expected
        ('present'|'absent'|'out-of-scope'), keyPresent, commandPresent,
        commandValue, status ('PASS'|'FAIL'|'SKIP'), reason.
    #>
    param(
        [PSObject]$Config,
        [PSObject]$LogMsgs,
        [string]$EditionFilter = ''
    )

    Write-Log $LogMsgs.messages.verifyHandlersStart -Level "info"
    Write-Host ""
    Write-Host $LogMsgs.messages.verifyHandlersHeader -ForegroundColor Cyan

    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) { $editions = @($EditionFilter) }

    $ensureTargets = @($Config.ensureOnTargets)
    $removeTargets = @($Config.removeFromTargets)
    $allTargets    = @('file','directory','background')

    $totalChecked = 0
    $totalFailed  = 0
    $editionsReport = [ordered]@{}

    foreach ($editionName in $editions) {
        $editionCfg = $Config.editions.$editionName
        if ($null -eq $editionCfg) {
            Write-Host ("  Edition: $editionName -- UNKNOWN, skipping") -ForegroundColor DarkYellow
            $editionsReport[$editionName] = @{
                label   = $null
                known   = $false
                targets = @()
            }
            continue
        }

        $line = ($LogMsgs.messages.verifyHandlersEdition -replace '\{edition\}', $editionName) -replace '\{label\}', $editionCfg.contextMenuLabel
        Write-Host $line -ForegroundColor White

        $targetsReport = @()

        foreach ($target in $allTargets) {
            $regPath = $editionCfg.registryPaths.$target
            $hasPath = -not [string]::IsNullOrWhiteSpace($regPath)
            if (-not $hasPath) {
                $msg = ($LogMsgs.messages.verifyHandlersTargetSkip -replace '\{target\}', $target) -replace '\{path\}', '(no registry path configured)'
                Write-Host $msg -ForegroundColor DarkGray
                $targetsReport += @{
                    target          = $target
                    registryPath    = $null
                    expected        = 'unconfigured'
                    keyPresent      = $null
                    commandPresent  = $null
                    commandValue    = $null
                    status          = 'SKIP'
                    reason          = 'No registry path configured for this target.'
                }
                continue
            }

            $isExpectedPresent = $ensureTargets -contains $target
            $isExpectedAbsent  = $removeTargets -contains $target
            $isInScope         = $isExpectedPresent -or $isExpectedAbsent
            if (-not $isInScope) {
                $msg = ($LogMsgs.messages.verifyHandlersTargetSkip -replace '\{target\}', $target) -replace '\{path\}', $regPath
                Write-Host $msg -ForegroundColor DarkGray
                $targetsReport += @{
                    target          = $target
                    registryPath    = $regPath
                    expected        = 'out-of-scope'
                    keyPresent      = $null
                    commandPresent  = $null
                    commandValue    = $null
                    status          = 'SKIP'
                    reason          = 'Target not in ensureOnTargets or removeFromTargets.'
                }
                continue
            }

            $totalChecked++

            # Probe key + \command default value via reg.exe (works under HKCR).
            $keyOut = reg.exe query $regPath 2>&1
            $isKeyPresent = ($LASTEXITCODE -eq 0)

            $cmdPath = "$regPath\command"
            $cmdOut  = reg.exe query $cmdPath /ve 2>&1
            $isCmdPresent = ($LASTEXITCODE -eq 0)

            $cmdValue = ''
            if ($isCmdPresent) {
                # Parse "(Default)    REG_SZ    "<exe>" "%V""
                foreach ($ln in $cmdOut) {
                    if ($ln -match '\s*\(Default\)\s+REG_\w+\s+(.+)$') {
                        $cmdValue = $Matches[1].Trim()
                        break
                    }
                }
            }

            $expectedLabel = if ($isExpectedPresent) { 'present' } else { 'absent' }
            $entryStatus = 'FAIL'
            $entryReason = ''

            if ($isExpectedPresent) {
                $isPass = $isKeyPresent -and $isCmdPresent -and -not [string]::IsNullOrWhiteSpace($cmdValue)
                if ($isPass) {
                    $msg = (($LogMsgs.messages.verifyHandlersTargetPass -replace '\{target\}', $target) -replace '\{command\}', $cmdValue)
                    Write-Host $msg -ForegroundColor Green
                    $entryStatus = 'PASS'
                    $entryReason = 'Key + \command + non-empty (Default) value all present.'
                } else {
                    $reason = if (-not $isKeyPresent) { 'expected PRESENT but key is missing' }
                              elseif (-not $isCmdPresent) { 'key present but \command subkey missing' }
                              else { 'command subkey present but (Default) value is empty' }
                    $msg = (($LogMsgs.messages.verifyHandlersTargetFail -replace '\{target\}', $target) -replace '\{reason\}', $reason) -replace '\{path\}', $regPath
                    Write-Host $msg -ForegroundColor Red
                    $totalFailed++
                    $entryReason = $reason
                }
            } else {
                # Expected absent
                if (-not $isKeyPresent) {
                    $msg = (($LogMsgs.messages.verifyHandlersTargetPass -replace '\{target\}', $target) -replace '\{command\}', '(absent as expected)')
                    Write-Host $msg -ForegroundColor Green
                    $entryStatus = 'PASS'
                    $entryReason = 'Key absent as expected.'
                } else {
                    $reason = 'expected ABSENT but key is still PRESENT'
                    $msg = (($LogMsgs.messages.verifyHandlersTargetFail -replace '\{target\}', $target) -replace '\{reason\}', $reason) -replace '\{path\}', $regPath
                    Write-Host $msg -ForegroundColor Red
                    $totalFailed++
                    $entryReason = $reason
                }
            }

            $targetsReport += @{
                target          = $target
                registryPath    = $regPath
                expected        = $expectedLabel
                keyPresent      = [bool]$isKeyPresent
                commandPresent  = [bool]$isCmdPresent
                commandValue    = $cmdValue
                status          = $entryStatus
                reason          = $entryReason
            }
        }

        $editionsReport[$editionName] = @{
            label   = $editionCfg.contextMenuLabel
            known   = $true
            targets = $targetsReport
        }
    }

    Write-Host ""
    $isOverallPass = ($totalFailed -eq 0 -and $totalChecked -gt 0)
    if ($totalFailed -eq 0 -and $totalChecked -gt 0) {
        Write-Host $LogMsgs.messages.verifyHandlersOverallPass -ForegroundColor Green
        Write-Log  $LogMsgs.messages.verifyHandlersOverallPass -Level "success"
    } else {
        $line = ($LogMsgs.messages.verifyHandlersOverallFail -replace '\{failed\}', $totalFailed) -replace '\{total\}', $totalChecked
        Write-Host $line -ForegroundColor Red
        Write-Log  $line -Level "error"
    }

    return @{
        ok           = $isOverallPass
        totalChecked = $totalChecked
        totalFailed  = $totalFailed
        editions     = $editionsReport
    }
}

function Save-VerificationReport {
    <#
    .SYNOPSIS
        Persists a verification result hashtable as a JSON troubleshooting
        report under .resolved/52-vscode-folder-repair/verify-reports/.

    .DESCRIPTION
        Writes one timestamped file per call (so users can compare runs)
        AND mirrors the latest run to 'verify-latest.json' for quick sharing.

        Report shape:
            {
              "schemaVersion": 1,
              "scriptVersion": "0.x.y",
              "generatedAt":   "<ISO-8601 local>",
              "generatedAtUtc":"<ISO-8601 UTC>",
              "host": { "computer": "...", "user": "...", "os": "...", "psVersion": "..." },
              "trigger": "refresh-verify" | "verify-handlers",
              "editionFilter": "" | "stable" | "insiders",
              "summary": { "ok": bool, "totalChecked": n, "totalFailed": n },
              "editions": { ... per-target detail ... }
            }

    .PARAMETER Result
        The hashtable returned by Test-VsCodeHandlersRegistered.

    .PARAMETER Trigger
        Free-form label describing what produced the report
        (e.g. 'refresh-verify' or 'verify-handlers').

    .PARAMETER EditionFilter
        The -Edition value used for the run (or '' for all editions).

    .PARAMETER ScriptDir
        Path to the script folder (used to derive .resolved/<folder>/).

    .PARAMETER LogMsgs
        Log-messages object for status output.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$Result,
        [Parameter(Mandatory)] [string]$Trigger,
        [string]$EditionFilter = '',
        [Parameter(Mandatory)] [string]$ScriptDir,
        [PSObject]$LogMsgs
    )

    try {
        # repo-root/.resolved/52-vscode-folder-repair/verify-reports/
        $repoRoot   = Split-Path -Parent (Split-Path -Parent $ScriptDir)
        $scriptName = Split-Path -Leaf $ScriptDir
        $reportsDir = Join-Path (Join-Path $repoRoot ".resolved") $scriptName
        $reportsDir = Join-Path $reportsDir "verify-reports"

        $isDirMissing = -not (Test-Path -LiteralPath $reportsDir)
        if ($isDirMissing) {
            New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null
        }

        # Pull script version from scripts/version.json (best-effort).
        $versionPath = Join-Path (Split-Path -Parent $ScriptDir) "version.json"
        $scriptVersion = "unknown"
        if (Test-Path -LiteralPath $versionPath) {
            try {
                $vRaw = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
                if ($vRaw.PSObject.Properties.Name -contains 'version') {
                    $scriptVersion = [string]$vRaw.version
                }
            } catch { }
        }

        $now    = Get-Date
        $report = [ordered]@{
            schemaVersion  = 1
            scriptVersion  = $scriptVersion
            generatedAt    = $now.ToString("o")
            generatedAtUtc = $now.ToUniversalTime().ToString("o")
            host           = [ordered]@{
                computer  = $env:COMPUTERNAME
                user      = $env:USERNAME
                os        = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
                psVersion = $PSVersionTable.PSVersion.ToString()
            }
            trigger        = $Trigger
            editionFilter  = $EditionFilter
            summary        = [ordered]@{
                ok           = [bool]$Result.ok
                totalChecked = [int]$Result.totalChecked
                totalFailed  = [int]$Result.totalFailed
            }
            editions       = $Result.editions
        }

        $stamp     = $now.ToString("yyyyMMdd-HHmmss")
        $statusTag = if ($Result.ok) { "PASS" } else { "FAIL" }
        $fileName  = "verify-$Trigger-$statusTag-$stamp.json"
        $filePath  = Join-Path $reportsDir $fileName
        $latestPath = Join-Path $reportsDir "verify-latest.json"

        $json = $report | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($filePath,   $json)
        [System.IO.File]::WriteAllText($latestPath, $json)

        Write-Log (($LogMsgs.messages.verifyReportSaved -replace '\{path\}', $filePath))   -Level "success"
        Write-Log (($LogMsgs.messages.verifyReportLatest -replace '\{path\}', $latestPath)) -Level "info"
        return $filePath
    } catch {
        $msg = $_.Exception.Message
        $errPath = if ($filePath) { $filePath } else { '(unresolved -- error before path computed)' }
        Write-Log (($LogMsgs.messages.verifyReportFailed -replace '\{path\}', $errPath) -replace '\{error\}', $msg) -Level "error"
        return $null
    }
}
