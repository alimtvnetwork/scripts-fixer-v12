# --------------------------------------------------------------------------
#  Shared helper: aria2c batch (parallel) downloads
#
#  Implements spec/2025-batch/suggestions/03-parallel-downloads.md.
#  Builds an aria2c --input-file with multiple entries and runs them
#  concurrently. Returns a per-item success map; the caller can fall
#  back to a sequential downloader for the items that failed.
#
#  Public function: Invoke-Aria2BatchDownload
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = $PSScriptRoot
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function Invoke-Aria2BatchDownload {
    <#
    .SYNOPSIS
        Downloads multiple files in parallel using aria2c's --input-file
        feature. Returns a hashtable keyed by item Key with $true/$false
        for per-item success (file present + non-empty after aria2c exits).

    .PARAMETER Items
        Array of [pscustomobject] / hashtables, each with:
          Key       -- caller-defined identifier (returned in the result map)
          Uri       -- download URL
          OutFile   -- absolute target path
          Label     -- (optional) friendly name for logging

    .PARAMETER MaxConcurrent
        Max simultaneous downloads (aria2c -j). Default 3.

    .PARAMETER ConnectionsPerServer
        aria2c -x. Default 8.

    .PARAMETER SplitsPerFile
        aria2c -s. Default 8.

    .PARAMETER ContinueDownload
        Resume partials. Default $true.

    .RETURNS
        Hashtable: @{ <Key> = $true|$false; ... }.
        Returns $null if aria2c is unavailable (caller must fall back).
    #>
    param(
        [Parameter(Mandatory)] [array] $Items,
        [int]    $MaxConcurrent        = 3,
        [int]    $ConnectionsPerServer = 8,
        [int]    $SplitsPerFile        = 8,
        [bool]   $ContinueDownload     = $true
    )

    $results = @{}

    $hasItems = $Items.Count -gt 0
    if (-not $hasItems) { return $results }

    $aria2Cmd = Get-Command aria2c.exe -ErrorAction SilentlyContinue
    $isAria2Available = $null -ne $aria2Cmd
    if (-not $isAria2Available) {
        Write-Log "[PARALLEL] aria2c not available; batch mode unavailable." -Level "warn"
        return $null
    }

    # -- Build input file -------------------------------------------------------
    $stamp     = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $inputFile = Join-Path $env:TEMP ("aria2c-batch-{0}.txt" -f $stamp)

    $sb = New-Object System.Text.StringBuilder
    foreach ($item in $Items) {
        $uri     = [string]$item.Uri
        $outFile = [string]$item.OutFile

        $hasUri = -not [string]::IsNullOrWhiteSpace($uri)
        $hasOut = -not [string]::IsNullOrWhiteSpace($outFile)
        if (-not ($hasUri -and $hasOut)) {
            Write-FileError -FilePath $outFile -Operation "batch-prepare" -Reason "Missing Uri or OutFile for batch entry (key: $($item.Key))" -Module "Invoke-Aria2BatchDownload"
            $results[$item.Key] = $false
            continue
        }

        $outDir  = Split-Path -Parent $outFile
        $outName = Split-Path -Leaf   $outFile

        $isDirMissing = -not (Test-Path -LiteralPath $outDir)
        if ($isDirMissing) {
            try {
                New-Item -Path $outDir -ItemType Directory -Force | Out-Null
            } catch {
                Write-FileError -FilePath $outDir -Operation "mkdir" -Reason $_.Exception.Message -Module "Invoke-Aria2BatchDownload"
                $results[$item.Key] = $false
                continue
            }
        }

        # aria2c input-file format: URL on its own line, options indented
        # with at least one whitespace.
        [void]$sb.AppendLine($uri)
        [void]$sb.AppendLine("  out=$outName")
        [void]$sb.AppendLine("  dir=$outDir")
    }

    $hasContent = $sb.Length -gt 0
    if (-not $hasContent) {
        Write-Log "[BATCH] No valid entries to download." -Level "warn"
        return $results
    }

    try {
        Set-Content -LiteralPath $inputFile -Value $sb.ToString() -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-FileError -FilePath $inputFile -Operation "write" -Reason $_.Exception.Message -Module "Invoke-Aria2BatchDownload"
        # Mark all as failed so caller can fall back per-item.
        foreach ($item in $Items) { $results[$item.Key] = $false }
        return $results
    }

    Write-Log "[BATCH] Wrote batch input file with $($Items.Count) entr$(if ($Items.Count -eq 1) { 'y' } else { 'ies' }): $inputFile" -Level "info"

    # -- Build aria2c arguments -------------------------------------------------
    $arguments = @(
        "--input-file=$inputFile",
        "--max-concurrent-downloads=$MaxConcurrent",
        "--max-connection-per-server=$ConnectionsPerServer",
        "--split=$SplitsPerFile",
        "--file-allocation=none",
        "--max-tries=3",
        "--retry-wait=5",
        "--timeout=60",
        "--auto-file-renaming=false",
        "--console-log-level=warn",
        "--summary-interval=5"
    )
    if ($ContinueDownload) { $arguments += "--continue=true" }

    Write-Log "[PARALLEL] aria2c started -- concurrency=$MaxConcurrent, conns/server=$ConnectionsPerServer, splits=$SplitsPerFile" -Level "info"

    $exitCode = -1
    try {
        $process = Start-Process -FilePath "aria2c.exe" -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $exitCode = $process.ExitCode
    } catch {
        Write-Log "aria2c batch invocation failed: $($_.Exception.Message)" -Level "error"
    } finally {
        # Best-effort cleanup of the temp input file.
        try { Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue } catch { }
    }

    $isExitOk = $exitCode -eq 0
    if (-not $isExitOk) {
        Write-Log "aria2c batch exited with code $exitCode (per-file results will be verified)." -Level "warn"
    }

    # -- Per-item verification --------------------------------------------------
    foreach ($item in $Items) {
        # Skip items already marked failed during prep.
        if ($results.ContainsKey($item.Key) -and -not $results[$item.Key]) { continue }

        $outFile = [string]$item.OutFile
        $isPresent = Test-Path -LiteralPath $outFile
        $isValid   = $false
        if ($isPresent) {
            try {
                $isValid = (Get-Item -LiteralPath $outFile -ErrorAction Stop).Length -gt 0
            } catch { $isValid = $false }
        }

        if ($isValid) {
            $results[$item.Key] = $true
        } else {
            $results[$item.Key] = $false
            $reason = if ($isPresent) { "File exists but is empty after batch run" } else { "File missing after batch run (aria2c exit=$exitCode)" }
            Write-FileError -FilePath $outFile -Operation "batch-verify" -Reason $reason -Module "Invoke-Aria2BatchDownload"
        }
    }

    return $results
}