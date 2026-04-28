# --------------------------------------------------------------------------
#  scripts/shared/registry-backup.ps1
#
#  Reusable registry-backup + change-ledger helpers for any script that
#  mutates HKEY_CLASSES_ROOT / HKLM / HKCU keys.
#
#  Two responsibilities:
#    1. Snapshot keys to a single timestamped .reg file BEFORE any write,
#       so the user can roll back with `reg import <file>`.
#    2. Maintain an in-memory change ledger (one row per write/delete)
#       and persist it as JSON + a colored end-of-run table so every
#       change is auditable.
#
#  Public API:
#    New-RegistryBackup        -- snapshot N keys to one .reg file. Returns
#                                  a [pscustomobject] with FilePath +
#                                  per-key status; CODE RED logs on every
#                                  failure path.
#    Start-RegistryChangeLog   -- reset the in-memory ledger for a new run.
#    Add-RegistryChange        -- record one change row.
#    Get-RegistryChangeLog     -- return the recorded rows.
#    Save-RegistryChangeLog    -- write the ledger to JSON.
#    Write-RegistryChangeLog   -- print a colored end-of-run table with a
#                                  one-liner rollback hint.
#
#  No hard dependency on logging.ps1 -- uses Write-FileError when present
#  (CODE RED rule), otherwise falls back to a colored Write-Host banner.
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

# --------------------------------------------------------------------------
#  Internal helpers
# --------------------------------------------------------------------------

# Strip a "Registry::" prefix and convert PS-style paths to reg.exe paths.
function ConvertTo-RegBackupPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return ($Path -replace '^Registry::', '')
}

# Honor CODE RED: route file/path failures through Write-FileError when the
# project's logging module is loaded; fall back to a self-contained banner
# otherwise. Either way, the EXACT path + reason is always surfaced.
function Write-RegBackupError {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Reason
    )
    $hasWriteFileError = $null -ne (Get-Command -Name 'Write-FileError' -ErrorAction SilentlyContinue)
    if ($hasWriteFileError) {
        Write-FileError -Path $Path -Reason $Reason
    } else {
        Write-Host ''
        Write-Host '  REGISTRY BACKUP ERROR' -ForegroundColor Red
        Write-Host ('    Path   : {0}' -f $Path)   -ForegroundColor Yellow
        Write-Host ('    Reason : {0}' -f $Reason) -ForegroundColor Yellow
        Write-Host ''
    }
}

# --------------------------------------------------------------------------
#  Snapshot N keys into one .reg file
# --------------------------------------------------------------------------
function New-RegistryBackup {
    <#
    .SYNOPSIS
        Snapshot a list of registry keys to ONE timestamped .reg file using
        reg.exe export. Missing keys are recorded as a comment line so the
        backup is self-describing.
    .PARAMETER Keys
        Array of full registry paths (e.g.
        'HKEY_CLASSES_ROOT\Directory\shell\VSCode'). Accepts either bare
        paths or "Registry::"-prefixed PS paths.
    .PARAMETER OutputDir
        Directory the .reg file is written to. Created if missing.
    .PARAMETER Tag
        Short slug embedded in the filename (e.g. 'script52-stable').
    .OUTPUTS
        [pscustomobject] @{
            FilePath = '<absolute path to .reg file>'
            Keys     = @(@{ Path=...; Present=$true/$false; Exported=$true/$false }, ...)
            Ok       = $true if every present key exported successfully
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Keys,
        [Parameter(Mandatory)] [string]$OutputDir,
        [Parameter(Mandatory)] [string]$Tag
    )

    # Ensure output dir exists -- CODE RED on failure.
    $isDirMissing = -not (Test-Path -LiteralPath $OutputDir)
    if ($isDirMissing) {
        try {
            $null = New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop
        } catch {
            Write-RegBackupError -Path $OutputDir -Reason ("Could not create backup directory: {0}" -f $_.Exception.Message)
            return [pscustomobject]@{ FilePath = $null; Keys = @(); Ok = $false }
        }
    }

    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTag   = ($Tag -replace '[^A-Za-z0-9._-]', '_')
    $fileName  = "registry-backup-{0}-{1}.reg" -f $safeTag, $stamp
    $filePath  = Join-Path $OutputDir $fileName

    # Initialize the file with a header so it is always valid + readable.
    try {
        Set-Content -LiteralPath $filePath -Value @(
            "Windows Registry Editor Version 5.00",
            "",
            "; ============================================================",
            "; Registry backup",
            ";   tag       : $Tag",
            ";   created   : $(Get-Date -Format 'o')",
            ";   key count : $($Keys.Count)",
            "; To roll back: reg import `"$filePath`"",
            "; ============================================================",
            ""
        ) -Encoding ASCII -ErrorAction Stop
    } catch {
        Write-RegBackupError -Path $filePath -Reason ("Could not initialize backup file: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ FilePath = $null; Keys = @(); Ok = $false }
    }

    $rows = @()
    $isAllOk = $true

    foreach ($rawKey in $Keys) {
        $keyPath = ConvertTo-RegBackupPath $rawKey

        # Probe presence first -- absent keys are documented, not exported.
        $null = reg.exe query $keyPath 2>&1
        $isPresent = ($LASTEXITCODE -eq 0)

        if (-not $isPresent) {
            try {
                Add-Content -LiteralPath $filePath -Value @(
                    "; ----- $keyPath ----- (absent at backup time, nothing to roll back)",
                    ""
                ) -Encoding ASCII
            } catch {
                Write-RegBackupError -Path $filePath -Reason ("Could not append absence marker for {0}: {1}" -f $keyPath, $_.Exception.Message)
                $isAllOk = $false
            }
            $rows += @{ Path = $keyPath; Present = $false; Exported = $false }
            continue
        }

        # Export to a temp file then concatenate into the master backup.
        $tmp = [IO.Path]::GetTempFileName()
        try {
            $null = reg.exe export $keyPath $tmp /y 2>&1
            $isExported = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tmp)
            if ($isExported) {
                # Drop reg.exe's per-file header line ("Windows Registry
                # Editor Version 5.00") so the master file has only one.
                $body = Get-Content -LiteralPath $tmp | Select-Object -Skip 1
                Add-Content -LiteralPath $filePath -Value @(
                    "; ----- $keyPath -----"
                ) -Encoding ASCII
                Add-Content -LiteralPath $filePath -Value $body -Encoding ASCII
                Add-Content -LiteralPath $filePath -Value '' -Encoding ASCII
                $rows += @{ Path = $keyPath; Present = $true; Exported = $true }
            } else {
                Write-RegBackupError -Path $keyPath -Reason ("reg.exe export failed (exit {0}); backup file: {1}" -f $LASTEXITCODE, $filePath)
                Add-Content -LiteralPath $filePath -Value @(
                    "; ----- $keyPath ----- (EXPORT FAILED -- exit $LASTEXITCODE)",
                    ""
                ) -Encoding ASCII
                $rows += @{ Path = $keyPath; Present = $true; Exported = $false }
                $isAllOk = $false
            }
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    return [pscustomobject]@{
        FilePath = $filePath
        Keys     = $rows
        Ok       = $isAllOk
    }
}

# --------------------------------------------------------------------------
#  Change ledger (in-memory, per-run)
# --------------------------------------------------------------------------
$script:_RegistryChangeLog = @()

function Start-RegistryChangeLog {
    [CmdletBinding()]
    param()
    $script:_RegistryChangeLog = @()
}

function Add-RegistryChange {
    <#
    .SYNOPSIS
        Record one change row. Operation must be one of:
        BACKUP | WRITE | DELETE | SKIP | FAIL
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('BACKUP','WRITE','DELETE','SKIP','FAIL')] [string]$Operation,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Detail   = '',
        [string]$Edition  = '',
        [string]$Target   = '',
        [bool]  $Success  = $true
    )
    $script:_RegistryChangeLog += [pscustomobject]@{
        Timestamp = (Get-Date -Format 'o')
        Operation = $Operation
        Edition   = $Edition
        Target    = $Target
        Path      = $Path
        Detail    = $Detail
        Success   = $Success
    }
}

function Get-RegistryChangeLog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return ,$script:_RegistryChangeLog
}

function Save-RegistryChangeLog {
    <#
    .SYNOPSIS
        Persist the in-memory ledger to JSON for later auditing / diffing.
        Returns the absolute file path; CODE RED on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$OutputDir,
        [Parameter(Mandatory)] [string]$Tag
    )

    $isDirMissing = -not (Test-Path -LiteralPath $OutputDir)
    if ($isDirMissing) {
        try {
            $null = New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop
        } catch {
            Write-RegBackupError -Path $OutputDir -Reason ("Could not create change-log directory: {0}" -f $_.Exception.Message)
            return $null
        }
    }

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTag  = ($Tag -replace '[^A-Za-z0-9._-]', '_')
    $filePath = Join-Path $OutputDir ("registry-changes-{0}-{1}.json" -f $safeTag, $stamp)

    try {
        $payload = [pscustomobject]@{
            tag       = $Tag
            createdAt = (Get-Date -Format 'o')
            count     = $script:_RegistryChangeLog.Count
            changes   = $script:_RegistryChangeLog
        }
        $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $filePath -Encoding UTF8 -ErrorAction Stop
        return $filePath
    } catch {
        Write-RegBackupError -Path $filePath -Reason ("Could not write change-log JSON: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Write-RegistryChangeLog {
    <#
    .SYNOPSIS
        Print a colored end-of-run table of every recorded change with a
        one-liner rollback hint pointing at the .reg backup file.
    #>
    [CmdletBinding()]
    param(
        [string]$BackupFilePath = '',
        [string]$JsonLogPath    = ''
    )

    $rows = $script:_RegistryChangeLog
    $hasRows = $rows.Count -gt 0
    if (-not $hasRows) {
        Write-Host ''
        Write-Host '  Registry change log: (no changes recorded this run)' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    $opColor = @{
        'BACKUP' = 'Cyan'
        'WRITE'  = 'Green'
        'DELETE' = 'Yellow'
        'SKIP'   = 'DarkGray'
        'FAIL'   = 'Red'
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  Registry Change Log' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('  {0,-8}  {1,-9}  {2,-11}  {3}' -f 'OP','EDITION','TARGET','PATH') -ForegroundColor DarkGray
    Write-Host ('  {0}' -f ('-' * 96)) -ForegroundColor DarkGray

    foreach ($r in $rows) {
        $color = if ($opColor.ContainsKey($r.Operation)) { $opColor[$r.Operation] } else { 'White' }
        Write-Host ('  {0,-8}  ' -f $r.Operation) -ForegroundColor $color -NoNewline
        Write-Host ('{0,-9}  {1,-11}  {2}' -f $r.Edition, $r.Target, $r.Path) -ForegroundColor White
        if (-not [string]::IsNullOrWhiteSpace($r.Detail)) {
            Write-Host ('             {0}' -f $r.Detail) -ForegroundColor DarkGray
        }
    }

    Write-Host ('  {0}' -f ('-' * 96)) -ForegroundColor DarkGray
    Write-Host ('  total changes: {0}' -f $rows.Count) -ForegroundColor White

    if (-not [string]::IsNullOrWhiteSpace($BackupFilePath)) {
        Write-Host ''
        Write-Host '  Rollback (run from an elevated shell):' -ForegroundColor Cyan
        Write-Host ('    reg import "{0}"' -f $BackupFilePath) -ForegroundColor White
    }
    if (-not [string]::IsNullOrWhiteSpace($JsonLogPath)) {
        Write-Host ('  Audit log: {0}' -f $JsonLogPath) -ForegroundColor DarkGray
    }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}
