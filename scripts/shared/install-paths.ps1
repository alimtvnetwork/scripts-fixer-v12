<#
.SYNOPSIS
    Standardised "Source / Temp / Target" install-path logging trio.

.DESCRIPTION
    User convention: every install/operation MUST surface three paths so we
    always know:
        Source  — where the install was launched from (script dir, repo root,
                  download URL, or installer .exe path)
        Temp    — where intermediate / cache / scratch files are written
        Target  — final install location (Program Files, %LocalAppData%,
                  PATH bin dir, etc.)

    These three lines are printed in a single coloured block right after the
    script banner (or right before a download / extract / install action) and
    a structured `installPaths` event is appended to the JSON log so it is
    grep-able after the fact.

    CODE RED tie-in: missing values ARE allowed but flagged with `(unknown)`
    in yellow. If you genuinely cannot resolve a path, prefer using
    Write-FileError for the underlying problem and pass through `(unknown)`
    rather than silently omitting the field.

.NOTES
    Helper version: 1.0.0
#>

# Dot-source logging helper if Write-Log isn't already loaded
$loggingPath = Join-Path $PSScriptRoot "logging.ps1"
$isLoggingAvailable = Test-Path $loggingPath
if ($isLoggingAvailable -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $loggingPath
}

function Write-InstallPaths {
    <#
    .SYNOPSIS
        Print the 3-path install trio (Source / Temp / Target) and record it
        as a structured event in the JSON log.

    .PARAMETER Source
        Where the install starts from (script path, repo root, download URL,
        or installer .exe). Required — pass "(unknown)" if you genuinely
        cannot resolve it.

    .PARAMETER Temp
        Scratch / cache / download dir. Required.

    .PARAMETER Target
        Final install location. Required.

    .PARAMETER Tool
        Optional friendly name of what is being installed (used for the
        block heading and the JSON event payload).

    .PARAMETER Action
        Optional verb to display in the heading (default: "Install").
        e.g. "Upgrade", "Repair", "Sync", "Extract".

    .EXAMPLE
        Write-InstallPaths `
            -Tool   "Notepad++" `
            -Source $PSCommandPath `
            -Temp   "$env:TEMP\npp-install" `
            -Target "C:\Program Files\Notepad++"
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Source,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Temp,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Target,

        [string]$Tool,

        [string]$Action = "Install"
    )

    $hasTool = -not [string]::IsNullOrWhiteSpace($Tool)
    $heading = if ($hasTool) { "$Action paths -- $Tool" } else { "$Action paths" }

    $rows = @(
        @{ Label = "Source"; Value = $Source },
        @{ Label = "Temp  "; Value = $Temp   },
        @{ Label = "Target"; Value = $Target }
    )

    Write-Host ""
    Write-Host "  [ PATH ] " -ForegroundColor Magenta -NoNewline
    Write-Host $heading -ForegroundColor White

    foreach ($row in $rows) {
        $val = $row.Value
        $isUnknown = [string]::IsNullOrWhiteSpace($val)
        $displayVal = if ($isUnknown) { "(unknown)" } else { $val }
        $valColor   = if ($isUnknown) { "Yellow" }    else { "Gray"      }

        Write-Host "          $($row.Label) : " -ForegroundColor DarkGray -NoNewline
        Write-Host $displayVal -ForegroundColor $valColor
    }
    Write-Host ""

    # Structured log event so the trio survives in JSON logs
    $hasWriteLog = $null -ne (Get-Command Write-Log -ErrorAction SilentlyContinue)
    if ($hasWriteLog) {
        $payload = "installPaths tool=$Tool action=$Action source=$Source temp=$Temp target=$Target"
        Write-Log $payload -Level "info"
    }
}

function Resolve-DefaultTempDir {
    <#
    .SYNOPSIS
        Convenience: return a per-tool temp dir under $env:TEMP, creating it
        if needed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ToolSlug
    )
    $base = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base "scripts-fixer\$ToolSlug"
    $isPresent = Test-Path $dir
    if (-not $isPresent) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}
