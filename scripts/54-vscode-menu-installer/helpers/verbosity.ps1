# --------------------------------------------------------------------------
#  Script 54 -- helpers/verbosity.ps1
#
#  Centralizes the -Verbosity switch (Quiet | Normal | Debug) used by every
#  entry point (install / uninstall / repair / sync / check) to control how
#  loud the verification + audit-report logging is.
#
#  Levels (lowest -> highest):
#    0 = Quiet   -- only summary totals + failures + warnings/errors.
#                   Suppresses banners, per-row PASS lines, "skipped/already
#                   absent" rows, and the "Added (N): ..." per-key dump.
#                   Use in CI when only the bottom-line PASS/FAIL matters.
#    1 = Normal  -- default; full human-readable report (banners + per-row
#                   PASS/FAIL + scope label + audit JSONL pointer).
#    2 = Debug   -- everything Normal shows PLUS extra diagnostic context:
#                   resolved hive label per row, raw audit record counts,
#                   per-target Test-RegistryKeyExists probes echoed, and
#                   the missing-children list spelled out for PASS rows
#                   too (so the user can confirm coverage explicitly).
#
#  Public API:
#    Set-VerbosityLevel    -Level <Quiet|Normal|Debug>
#    Get-VerbosityLevel                              -> 'Quiet'|'Normal'|'Debug'
#    Test-VerbosityAtLeast -Level <Quiet|Normal|Debug> -> [bool]
#    Write-VLog -Message <s> -Level <log-level> -MinVerbosity <Quiet|Normal|Debug>
#                          -- pass-through to Write-Log only when current
#                             verbosity >= MinVerbosity. Errors/warnings
#                             are NEVER suppressed (always pass through).
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

# Load Write-Log if not already in scope (module loaded standalone for tests).
$_loggingPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared\logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Numeric mapping. Anything not listed defaults to Normal (1).
$script:_VerbosityMap = @{
    'Quiet'  = 0
    'Normal' = 1
    'Debug'  = 2
}

# Default level for any caller that forgets to call Set-VerbosityLevel.
$script:_VerbosityLevel = 'Normal'

function Set-VerbosityLevel {
    <#
    .SYNOPSIS
        Set the process-wide verbosity for verification + audit reporting.
    .PARAMETER Level
        One of: Quiet | Normal | Debug. Case-insensitive. An invalid value
        is logged loudly (CODE RED: include exact bad value) and falls back
        to 'Normal' so the run continues with the safest visible default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Level
    )

    $isKnown = $script:_VerbosityMap.ContainsKey($Level)
    if (-not $isKnown) {
        # Try case-insensitive match before giving up.
        $match = $script:_VerbosityMap.Keys | Where-Object { $_ -ieq $Level } | Select-Object -First 1
        if ($match) { $Level = $match; $isKnown = $true }
    }
    if (-not $isKnown) {
        Write-Log ("Invalid -Verbosity value '" + $Level +
                   "' (failure: not one of Quiet|Normal|Debug). Falling back to 'Normal'.") -Level "warn"
        $Level = 'Normal'
    }
    $script:_VerbosityLevel = $Level
    # Echo the resolution so the audit log captures which mode the run used.
    Write-Log ("Verbosity set to: " + $script:_VerbosityLevel +
               " (numeric=" + $script:_VerbosityMap[$script:_VerbosityLevel] + ")") -Level "info"
}

function Get-VerbosityLevel {
    return $script:_VerbosityLevel
}

function Test-VerbosityAtLeast {
    <#
    .SYNOPSIS
        Return $true when the current verbosity is >= the requested floor.
        Use to gate whole blocks of optional output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Level
    )
    $hasFloor = $script:_VerbosityMap.ContainsKey($Level)
    if (-not $hasFloor) {
        # Misuse by helper code -- fail safe (assume the caller wants output).
        Write-Log ("Test-VerbosityAtLeast called with unknown level '" + $Level +
                   "' (failure: must be Quiet|Normal|Debug). Treating as Quiet (always true).") -Level "warn"
        return $true
    }
    $current = $script:_VerbosityMap[$script:_VerbosityLevel]
    $floor   = $script:_VerbosityMap[$Level]
    return ($current -ge $floor)
}

function Write-VLog {
    <#
    .SYNOPSIS
        Verbosity-gated wrapper around Write-Log.

    .DESCRIPTION
        Emits the message via Write-Log only when the current verbosity is
        at or above MinVerbosity. ERROR and WARN levels ALWAYS pass through
        regardless of verbosity -- silencing failures would defeat the
        purpose of a verification report.

    .PARAMETER Message
        The log line.
    .PARAMETER Level
        Standard Write-Log level: info | success | warn | error.
    .PARAMETER MinVerbosity
        Minimum verbosity required for this line to appear when Level is
        info or success. Defaults to 'Normal'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [ValidateSet('info','success','warn','error')] [string] $Level,
        [ValidateSet('Quiet','Normal','Debug')] [string] $MinVerbosity = 'Normal'
    )

    $isFailure = ($Level -eq 'error' -or $Level -eq 'warn')
    if ($isFailure) {
        # NEVER swallow warnings / errors, even in Quiet mode.
        Write-Log $Message -Level $Level
        return
    }

    $shouldEmit = Test-VerbosityAtLeast -Level $MinVerbosity
    if ($shouldEmit) {
        Write-Log $Message -Level $Level
    }
}