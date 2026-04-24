<#
.SYNOPSIS
    Pre-install snapshot of every registry key the installer is about to
    touch. Always runs on install (per user spec).

.DESCRIPTION
    Uses reg.exe export to write each target's current state to a single
    .reg file under .audit/snapshots/snapshot-<yyyyMMdd-HHmmss>.reg.

    Why .reg (not JSON):
      * reg.exe import restores the exact byte content -- including value
        types we don't model (REG_BINARY, REG_EXPAND_SZ, etc.).
      * One file per run is human-auditable AND directly importable.

    Snapshot contains only the paths in config.json::editions.<n>.
    registryPaths -- never enumerates siblings (same surgical guarantee
    as uninstall).

    The 'rollback' command in run.ps1 does NOT auto-import this file --
    per user spec, rollback just removes what we added (alias for the
    surgical uninstall). The snapshot is here for manual recovery:

        reg.exe import .audit\snapshots\snapshot-<stamp>.reg

    Public functions:
      New-PreInstallSnapshot   -- export every target key to one .reg file
      Get-LatestSnapshotPath   -- newest snapshot file or $null
#>

Set-StrictMode -Version Latest

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function ConvertTo-RegExePathS {
    param([string]$PsPath)
    $p = $PsPath -replace '^Registry::', ''
    return ($p -replace '^HKEY_CLASSES_ROOT', 'HKCR')
}

function New-PreInstallSnapshot {
    <#
    .SYNOPSIS
        Snapshots every target registry key to a single .reg file.
    .OUTPUTS
        String -- path to the snapshot file, or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $ScriptDir
    )

    $snapDir = Join-Path $ScriptDir ".audit\snapshots"
    $isDirMissing = -not (Test-Path -LiteralPath $snapDir)
    if ($isDirMissing) {
        try {
            $null = New-Item -ItemType Directory -Path $snapDir -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to create snapshots dir: $snapDir (failure: $($_.Exception.Message))" -Level "error"
            return $null
        }
    }

    $stamp    = Get-Date -Format "yyyyMMdd-HHmmss"
    $snapPath = Join-Path $snapDir ("snapshot-{0}.reg" -f $stamp)

    # Collect every (edition, target, regPath) tuple from config.
    $entries = @()
    foreach ($edName in @($Config.enabledEditions)) {
        $hasEd = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEd) { continue }
        $ed = $Config.editions.$edName
        foreach ($target in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $target
            if (-not $hasTarget) { continue }
            $entries += [pscustomobject]@{
                Edition = $edName
                Target  = $target
                RegPath = $ed.registryPaths.$target
            }
        }
    }

    $isEmpty = $entries.Count -eq 0
    if ($isEmpty) {
        Write-Log "Snapshot skipped: no registryPaths in config (failure: nothing to back up at $snapDir)" -Level "warn"
        return $null
    }

    # reg.exe export creates one file per call. Export each into a temp
    # file then concatenate -- single .reg can hold multiple keys back to
    # back, and reg.exe import accepts that shape.
    $tmpFiles = @()
    $exported = 0
    $missing  = 0
    try {
        foreach ($e in $entries) {
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
                ("vscode54-snap-{0}-{1}-{2}.reg" -f $e.Edition, $e.Target, [Guid]::NewGuid().ToString("N")))
            $tmpFiles += $tmp

            $exePath = ConvertTo-RegExePathS $e.RegPath

            # Probe first -- absent keys are normal (first-time install)
            $null = reg.exe query $exePath 2>&1
            $isAbsent = ($LASTEXITCODE -ne 0)
            if ($isAbsent) {
                $missing++
                # Write a comment placeholder so the snapshot file documents
                # which keys did NOT exist at snapshot time.
                $stub = "; ABSENT at snapshot time: $exePath  (edition=$($e.Edition) target=$($e.Target))`r`n"
                Set-Content -LiteralPath $tmp -Value $stub -Encoding ASCII -NoNewline
                continue
            }

            $null = reg.exe export $exePath $tmp /y 2>&1
            $isExportOk = ($LASTEXITCODE -eq 0)
            if (-not $isExportOk) {
                Write-Log "reg.exe export failed for: $exePath (failure: exit $LASTEXITCODE; tmp=$tmp)" -Level "warn"
                continue
            }
            $exported++
        }

        # Concatenate. First file's "Windows Registry Editor Version 5.00"
        # header is kept; strip the duplicate header from subsequent files.
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Windows Registry Editor Version 5.00")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("; Pre-install snapshot for script 54 (vscode-menu-installer)")
        [void]$sb.AppendLine("; Created: $(Get-Date -Format 'o')")
        [void]$sb.AppendLine("; Host: $env:COMPUTERNAME  User: $env:USERNAME")
        [void]$sb.AppendLine("; Entries snapshotted: $($entries.Count)  exported: $exported  absent: $missing")
        [void]$sb.AppendLine("; Restore manually with:  reg.exe import ""$snapPath""")
        [void]$sb.AppendLine("")

        for ($i = 0; $i -lt $tmpFiles.Count; $i++) {
            $tmp = $tmpFiles[$i]
            $isTmpMissing = -not (Test-Path -LiteralPath $tmp)
            if ($isTmpMissing) { continue }
            $content = Get-Content -LiteralPath $tmp -Raw -Encoding Unicode -ErrorAction SilentlyContinue
            if ($null -eq $content) {
                # Fallback for ASCII stub files
                $content = Get-Content -LiteralPath $tmp -Raw -ErrorAction SilentlyContinue
            }
            if ([string]::IsNullOrEmpty($content)) { continue }
            # Strip the version header from concatenated bodies
            $stripped = $content -replace '^\s*Windows Registry Editor Version 5\.00\s*\r?\n', ''
            [void]$sb.AppendLine("; --- entry $($i + 1)/$($entries.Count): $($entries[$i].Edition)/$($entries[$i].Target) ---")
            [void]$sb.AppendLine($stripped)
        }

        Set-Content -LiteralPath $snapPath -Value $sb.ToString() -Encoding Unicode -ErrorAction Stop

        Write-Log "Snapshot written: $snapPath ($exported exported, $missing absent of $($entries.Count) total)" -Level "success"
        return $snapPath
    } catch {
        Write-Log "Snapshot creation failed: $snapPath (failure: $($_.Exception.Message))" -Level "error"
        return $null
    } finally {
        foreach ($t in $tmpFiles) {
            if (Test-Path -LiteralPath $t) {
                Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-LatestSnapshotPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ScriptDir)

    $snapDir = Join-Path $ScriptDir ".audit\snapshots"
    $isDirMissing = -not (Test-Path -LiteralPath $snapDir)
    if ($isDirMissing) { return $null }

    $latest = Get-ChildItem -LiteralPath $snapDir -Filter "snapshot-*.reg" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latest) { return $null }
    return $latest.FullName
}
