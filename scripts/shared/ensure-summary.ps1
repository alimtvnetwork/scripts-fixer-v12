# --------------------------------------------------------------------------
#  Ensure-Tool end-of-run summary
#
#  Wraps the hashtable returned by Ensure-Tool into a per-run collector and
#  prints a colored "Action  Tool        Version  Notes" table at the end.
#
#  Usage:
#
#    Start-EnsureSummary
#    foreach ($t in $tools) {
#        $r = Ensure-Tool -Name $t.Name -Command $t.Cmd -ChocoPackage $t.Pkg
#        Add-EnsureSummary -Name $t.Name -Result $r
#    }
#    Write-EnsureSummary -Title "Advanced profile install"
#
#  Color contract (no em-dashes / no wide Unicode -- per terminal-banners rule):
#    skipped    -> gray   (no work needed)
#    installed  -> green  (fresh install)
#    upgraded   -> cyan   (already present, moved to latest)
#    failed     -> red    (record carries .Error)
#    unknown    -> yellow (Result was $null or had no .Action)
#
#  Every state-file write that fails uses Write-FileError (CODE RED rule).
# --------------------------------------------------------------------------

if (-not (Get-Variable -Name __EnsureSummary -Scope Script -ErrorAction SilentlyContinue)) {
    $script:__EnsureSummary = $null
}

function Start-EnsureSummary {
    <#
    .SYNOPSIS
        Reset the in-memory summary collector. Call once per run before the
        first Ensure-Tool invocation.
    #>
    [CmdletBinding()]
    param()
    $script:__EnsureSummary = [System.Collections.Generic.List[object]]::new()
}

function Add-EnsureSummary {
    <#
    .SYNOPSIS
        Record one Ensure-Tool result. Safe to call even if Start-EnsureSummary
        was skipped -- it will lazily initialise the collector.

    .PARAMETER Name
        Tracking name (matches Ensure-Tool -Name).

    .PARAMETER Result
        The hashtable returned by Ensure-Tool. May be $null if the call threw
        before returning -- the entry is still recorded as "failed".

    .PARAMETER FriendlyName
        Pretty name for the table. Defaults to -Name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Result,
        [string]$FriendlyName = ""
    )

    if ($null -eq $script:__EnsureSummary) { Start-EnsureSummary }
    if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $FriendlyName = $Name }

    $action  = "unknown"
    $version = $null
    $errMsg  = $null
    $tracked = $false

    if ($null -ne $Result) {
        if ($Result.ContainsKey("Action"))  { $action  = [string]$Result.Action }
        if ($Result.ContainsKey("Version")) { $version = $Result.Version }
        if ($Result.ContainsKey("Error"))   { $errMsg  = $Result.Error }
        if ($Result.ContainsKey("Tracked")) { $tracked = [bool]$Result.Tracked }
    } else {
        $action = "failed"
        $errMsg = "Ensure-Tool returned no result"
    }

    $script:__EnsureSummary.Add([pscustomobject]@{
        Name         = $Name
        FriendlyName = $FriendlyName
        Action       = $action
        Version      = $version
        Tracked      = $tracked
        Error        = $errMsg
    }) | Out-Null
}

function Get-EnsureSummary {
    <#
    .SYNOPSIS
        Return the collected entries (array). Empty array if none recorded.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:__EnsureSummary) { return @() }
    return @($script:__EnsureSummary)
}

function Get-EnsureSummaryTotals {
    <#
    .SYNOPSIS
        Hashtable of counts per action plus -Total. Useful for exit codes /
        CI gates (e.g. exit 1 if .failed -gt 0).
    #>
    [CmdletBinding()]
    param()
    $totals = @{
        skipped   = 0
        installed = 0
        upgraded  = 0
        failed    = 0
        unknown   = 0
        total     = 0
    }
    foreach ($e in (Get-EnsureSummary)) {
        $key = if ($totals.ContainsKey($e.Action)) { $e.Action } else { "unknown" }
        $totals[$key]++
        $totals["total"]++
    }
    return $totals
}

function Write-EnsureSummary {
    <#
    .SYNOPSIS
        Print the captured per-tool results as a colored table, followed by
        a one-line totals banner.

    .PARAMETER Title
        Header label printed above the table.

    .PARAMETER NoBanner
        Suppress the banner -- useful when the caller already printed one.

    .PARAMETER JsonPath
        Optional path. When supplied, the structured summary is also written
        to disk so other tools (CI, dashboards) can consume it.
    #>
    [CmdletBinding()]
    param(
        [string]$Title    = "Tool install summary",
        [switch]$NoBanner,
        [string]$JsonPath = ""
    )

    $entries = Get-EnsureSummary
    $totals  = Get-EnsureSummaryTotals

    if (-not $NoBanner) {
        Write-Banner -Lines @(
            ("=" * 60),
            "  $Title",
            ("=" * 60)
        ) -Color "Cyan"
    }

    if ($entries.Count -eq 0) {
        Write-Log "No tools recorded. Did you call Add-EnsureSummary after Ensure-Tool?" -Level "warn"
        return
    }

    # Layout: Action(10) | Tool(20) | Version(24) | Notes
    $hdr = ("{0,-10} {1,-20} {2,-24} {3}" -f "ACTION", "TOOL", "VERSION", "NOTES")
    Write-Host $hdr -ForegroundColor White
    Write-Host ("-" * 78) -ForegroundColor DarkGray

    foreach ($e in $entries) {
        $color = switch ($e.Action) {
            "installed" { "Green" }
            "upgraded"  { "Cyan" }
            "skipped"   { "Gray" }
            "failed"    { "Red" }
            default     { "Yellow" }
        }

        $version = if ($e.Version) { "$($e.Version)" } else { "(unknown)" }
        if ($version.Length -gt 24) { $version = $version.Substring(0, 21) + "..." }

        $notes = ""
        if ($e.Action -eq "failed" -and $e.Error) {
            $notes = $e.Error
            if ($notes.Length -gt 40) { $notes = $notes.Substring(0, 37) + "..." }
        } elseif ($e.Action -eq "skipped" -and $e.Tracked) {
            $notes = "tracked"
        }

        $line = ("{0,-10} {1,-20} {2,-24} {3}" -f
            $e.Action.ToUpperInvariant(),
            $e.FriendlyName,
            $version,
            $notes)
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ("-" * 78) -ForegroundColor DarkGray
    $summaryLine = ("Total: {0}  installed: {1}  upgraded: {2}  skipped: {3}  failed: {4}" -f
        $totals.total, $totals.installed, $totals.upgraded, $totals.skipped, $totals.failed)
    $summaryColor = if ($totals.failed -gt 0) { "Red" } elseif ($totals.installed -gt 0 -or $totals.upgraded -gt 0) { "Green" } else { "Gray" }
    Write-Host $summaryLine -ForegroundColor $summaryColor
    Write-Host ""

    # Optional structured JSON output for CI / dashboards.
    if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
        try {
            $payload = [pscustomobject]@{
                title     = $Title
                generated = (Get-Date).ToString("o")
                totals    = $totals
                entries   = $entries
            }
            $dir = Split-Path -Parent $JsonPath
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            ($payload | ConvertTo-Json -Depth 6) | Set-Content -Path $JsonPath -Encoding UTF8
            Write-Log "Summary written: $JsonPath" -Level "info"
        } catch {
            # CODE RED: always log the exact path + reason on file failures.
            if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
                Write-FileError -Path $JsonPath -Reason "$_"
            } else {
                Write-Log "  [FAIL] path: $JsonPath -- reason: $_" -Level "error"
            }
        }
    }
}

function Reset-EnsureSummary {
    <#
    .SYNOPSIS
        Drop all collected entries (alias-style helper for tests / re-runs
        within the same session).
    #>
    [CmdletBinding()]
    param()
    $script:__EnsureSummary = $null
}
