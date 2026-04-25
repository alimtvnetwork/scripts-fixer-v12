# --------------------------------------------------------------------------
#  helpers/check-interactive.ps1
#  Opt-in interactive prompts that live ON TOP of the existing read-only
#  `check` verb. The check pipeline still produces the same logs and
#  ExitCodeMap output -- this module is consulted AFTER the action
#  collector is finalised and only when the caller passes -Interactive
#  (or one of -PromptEach / -PromptOneShot).
#
#  CI behaviour is preserved: if -ExitCodeMap is on, or stdin is not
#  a TTY, prompts are auto-skipped with a one-line note so a CI log
#  never silently waits for keystrokes.
#
#  Public functions:
#    Get-Check10RepairCommandFor  -- maps a MISS action -> exact `repair` cmd
#    Invoke-Check10Interactive    -- runs the prompt loop, dispatches repairs
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

function Get-Check10RepairCommandFor {
    <#
    .SYNOPSIS
        Map a single MISS action to the narrowest `repair -Only ...`
        command that will fix it.
    .OUTPUTS
        [string] -- ready-to-run command (no PowerShell prefix), or '' on
                    no match.
    #>
    param([Parameter(Mandatory)] $Action)

    $edArg = if ($Action.edition) { " -Edition " + $Action.edition } else { "" }
    $sel = ''
    switch ($Action.invariantCode) {
        'I1-FILE-TARGET' { $sel = 'i1' }
        'I2-SUPPRESSION' { $sel = 'i2' }
        'I3-LEGACY-DUP'  { $sel = 'i3' }
        'INSTALL-STATE'  {
            # INSTALL-STATE is per-target. Map to the smallest selector
            # that re-asserts just that target.
            switch ($Action.target) {
                'directory'  { $sel = 'folder' }
                'background' { $sel = 'background' }
                'file'       { $sel = 'install' }   # rare; full install pass
                default      { $sel = 'install' }
            }
        }
        default { $sel = '' }
    }
    if (-not $sel) { return "" }
    return ".\run.ps1 repair" + $edArg + " -Only " + $sel
}

function _Read-Check10Choice {
    # Wraps Read-Host with a fixed accepted-set so the loop body stays
    # readable. Returns one of: 'y','n','a','q'.
    param([Parameter(Mandatory)] [string] $Prompt)
    while ($true) {
        $raw = Read-Host -Prompt $Prompt
        $t = ([string]$raw).Trim().ToLowerInvariant()
        if ($t -eq '')  { $t = 'n' }   # bare ENTER = decline (safe default)
        if ($t -in @('y','yes'))   { return 'y' }
        if ($t -in @('n','no'))    { return 'n' }
        if ($t -in @('a','all'))   { return 'a' }
        if ($t -in @('q','quit'))  { return 'q' }
        Write-Host "    Please answer y (yes), n (no), a (yes-to-all), or q (quit)." -ForegroundColor Yellow
    }
}

function _Test-Check10Tty {
    # PowerShell does not expose isatty cleanly; we treat $Host.Name +
    # [Console]::IsInputRedirected as the signal. CI runners typically
    # redirect stdin which makes IsInputRedirected $true -> skip prompts.
    try {
        $isRedirected = [Console]::IsInputRedirected
        return -not $isRedirected
    } catch {
        return $true   # If detection fails, assume interactive (safer
                       # than silently skipping when the user asked for it).
    }
}

function Invoke-Check10Interactive {
    <#
    .SYNOPSIS
        Prompt-driven dispatcher that runs after Write-Check10MissActionSummary.
    .PARAMETER Mode
        'each'    -> ask per MISS block
        'oneshot' -> single confirm for the consolidated repair
        'both'    -> per-MISS first, then a one-shot question for whatever
                     was declined
    .PARAMETER OneShotCommand
        The full `.\run.ps1 repair ...` line to offer as the one-shot.
    .PARAMETER AssumeYes
        Skip all prompts and treat every offer as 'y'.
    .PARAMETER DryRun
        Print every command that WOULD run, never invoke it.
    .PARAMETER RunScriptPath
        Absolute path to this script's run.ps1 (used to actually invoke
        the repair calls -- avoids depending on CWD).
    .OUTPUTS
        [pscustomobject] @{ accepted=int; declined=int; quitEarly=bool;
                            invoked=string[]; failures=int }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('each','oneshot','both')] [string] $Mode,
        [Parameter(Mandatory)] [string] $OneShotCommand,
        [Parameter(Mandatory)] [string] $RunScriptPath,
        [switch] $AssumeYes,
        [switch] $DryRun
    )

    $result = [pscustomobject]@{
        accepted  = 0
        declined  = 0
        quitEarly = $false
        invoked   = @()
        failures  = 0
    }

    $actions = Get-Check10MissActions
    if ($actions.Count -eq 0) {
        Write-Log "Interactive prompt skipped: no MISS findings to act on." -Level "info"
        return $result
    }

    # CI / non-TTY guard. Only enforced when the user did NOT pass
    # -AssumeYes (which is the explicit non-interactive escape hatch).
    if (-not $AssumeYes) {
        $isTty = _Test-Check10Tty
        if (-not $isTty) {
            Write-Log "Interactive prompts requested but stdin is redirected (likely CI). Skipping prompts. Re-run in a real terminal or pass -AssumeYes." -Level "warn"
            return $result
        }
    }

    Write-Log "" -Level "info"
    Write-Log "================================  INTERACTIVE FIX  ================================" -Level "warn"
    if ($DryRun) {
        Write-Log "  DryRun ON: every accepted command will be PRINTED, not executed." -Level "warn"
    }
    if ($AssumeYes) {
        Write-Log "  AssumeYes ON: every offer will be auto-accepted (no prompts)." -Level "warn"
    }
    Write-Log "  Answer keys:  y=run this fix   n=skip   a=yes-to-all-remaining   q=quit prompts" -Level "warn"
    Write-Log "====================================================================================" -Level "warn"

    $autoYes  = [bool]$AssumeYes
    $declined = @()   # MISS actions the user said 'n' to (offered again in oneshot mode)

    if ($Mode -in @('each','both')) {
        $i = 0
        foreach ($a in $actions) {
            $i++
            if ($result.quitEarly) { break }

            $cmd = Get-Check10RepairCommandFor -Action $a
            $codeTag = if ($a.invariantCode) { $a.invariantCode } else { '<unspecified>' }

            Write-Host ""
            Write-Host ("  [" + $i + "/" + $actions.Count + "] [" + $codeTag + "]  edition=" + $a.edition + "  target=" + $a.target) -ForegroundColor Red
            Write-Host ("        Path : " + $a.regPath) -ForegroundColor DarkGray
            if ($a.items -and $a.items.Count -gt 0) {
                Write-Host ("        Items: " + ($a.items -join ', ')) -ForegroundColor DarkGray
            }
            if (-not $cmd) {
                Write-Host "        (no targeted repair command available for this miss -- skipped)" -ForegroundColor Yellow
                continue
            }
            Write-Host ("        Will run : " + $cmd) -ForegroundColor Cyan

            $choice = if ($autoYes) { 'y' } else { _Read-Check10Choice -Prompt "        Run this fix? [y/N/a/q]" }
            switch ($choice) {
                'y' { $result.accepted++ }
                'a' { $result.accepted++; $autoYes = $true; Write-Host "        (yes-to-all enabled for remaining prompts)" -ForegroundColor Yellow }
                'n' { $result.declined++; $declined += $a; continue }
                'q' { $result.quitEarly = $true; break }
            }

            if ($DryRun) {
                Write-Host ("        [DryRun] would invoke: " + $cmd) -ForegroundColor DarkYellow
                $result.invoked += $cmd
                continue
            }

            # Translate the printed command into argv for the in-process call.
            # Format is always: .\run.ps1 repair [-Edition X] -Only <sel>
            $repairArgs = @('repair')
            if ($a.edition) { $repairArgs += @('-Edition', $a.edition) }
            $sel = ($cmd -split ' -Only ')[-1].Trim()
            $repairArgs += @('-Only', $sel)

            try {
                & $RunScriptPath @repairArgs
                $rc = $LASTEXITCODE
                if ($rc -ne 0) {
                    $result.failures++
                    Write-Host ("        FAILED (exit " + $rc + "): " + $cmd) -ForegroundColor Red
                } else {
                    Write-Host ("        OK : " + $cmd) -ForegroundColor Green
                }
                $result.invoked += $cmd
            } catch {
                $result.failures++
                Write-Host ("        FAILED (exception): " + $cmd + " (failure: " + $_.Exception.Message + ")") -ForegroundColor Red
            }
        }
    }

    # One-shot prompt: only offered when user is in 'oneshot' mode, OR
    # in 'both' mode AND at least one item was declined / quit.
    $shouldOfferOneShot = $false
    if ($Mode -eq 'oneshot') { $shouldOfferOneShot = $true }
    elseif ($Mode -eq 'both' -and (-not $result.quitEarly) -and ($declined.Count -gt 0)) { $shouldOfferOneShot = $true }

    if ($shouldOfferOneShot -and -not $result.quitEarly) {
        Write-Host ""
        Write-Host "  One-shot fix for ALL outstanding misses:" -ForegroundColor Yellow
        Write-Host ("      " + $OneShotCommand) -ForegroundColor Cyan
        $choice = if ($autoYes) { 'y' } else { _Read-Check10Choice -Prompt "  Run the one-shot now? [y/N/q]" }
        if ($choice -eq 'y') {
            $result.accepted++
            if ($DryRun) {
                Write-Host ("  [DryRun] would invoke: " + $OneShotCommand) -ForegroundColor DarkYellow
                $result.invoked += $OneShotCommand
            } else {
                # The one-shot is always: .\run.ps1 repair [-Edition X]
                $argv = @('repair')
                if ($OneShotCommand -match '-Edition\s+(\S+)') { $argv += @('-Edition', $Matches[1]) }
                try {
                    & $RunScriptPath @argv
                    $rc = $LASTEXITCODE
                    if ($rc -ne 0) {
                        $result.failures++
                        Write-Host ("  FAILED (exit " + $rc + "): " + $OneShotCommand) -ForegroundColor Red
                    } else {
                        Write-Host ("  OK : " + $OneShotCommand) -ForegroundColor Green
                    }
                    $result.invoked += $OneShotCommand
                } catch {
                    $result.failures++
                    Write-Host ("  FAILED (exception): " + $OneShotCommand + " (failure: " + $_.Exception.Message + ")") -ForegroundColor Red
                }
            }
        } else {
            $result.declined++
        }
    }

    Write-Log "" -Level "info"
    Write-Log ("Interactive summary -- accepted: " + $result.accepted + ", declined: " + $result.declined + ", quitEarly: " + $result.quitEarly + ", invoked: " + $result.invoked.Count + ", failures: " + $result.failures) -Level $(if ($result.failures -gt 0) { 'error' } else { 'info' })

    return $result
}