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
