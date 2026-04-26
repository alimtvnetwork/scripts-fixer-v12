<#
.SYNOPSIS
    Timestamped audit log for every registry key added or removed by the
    VS Code menu installer/uninstaller.

.DESCRIPTION
    One audit FILE per run (created lazily on the first event) under:
        scripts/54-vscode-menu-installer/.audit/

    Filename format:
        audit-<action>-<yyyyMMdd-HHmmss>.jsonl

    Each line is a self-contained JSON record (JSONL) so the file can be
    tailed during a run, diffed across runs, or grepped for a path.

    Record shape:
        {
          "ts":        "2026-04-24T10:15:23.123+08:00",
          "action":    "install" | "uninstall",
          "operation": "add" | "remove" | "skip-absent" | "fail",
          "edition":   "stable",
          "target":    "file" | "directory" | "background",
          "regPath":   "HKCR\\Directory\\shell\\VSCode",
          "values":    { "(Default)": "...", "Icon": "...", "command": "..." },
          "reason":    "<failure message>"   // only on operation=fail
        }

    The helper exposes:
      Initialize-RegistryAudit  -- opens the run-scoped log file
      Write-RegistryAuditEvent  -- append one event
      Get-RegistryAuditPath     -- current run's audit file path

    Audit writes never throw -- a broken audit file must not abort the
    main install/uninstall flow. Failures are logged via Write-Log so the
    CODE RED file/path-error rule is honoured (exact path + reason).
#>

Set-StrictMode -Version Latest

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Module-scope state -- one audit file per script run.
$script:AuditFilePath = $null
$script:AuditAction   = $null

function Initialize-RegistryAudit {
    <#
    .SYNOPSIS
        Decides the audit file path for this run and ensures the .audit/
        directory exists. Safe to call more than once -- subsequent calls
        in the same run keep the original file path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('install','uninstall')]
        [string] $Action,

        [Parameter(Mandatory)]
        [string] $ScriptDir
    )

    $isAlreadyInitialized = -not [string]::IsNullOrWhiteSpace($script:AuditFilePath)
    if ($isAlreadyInitialized) { return $script:AuditFilePath }

    $auditDir = Join-Path $ScriptDir ".audit"
    $isDirMissing = -not (Test-Path -LiteralPath $auditDir)
    if ($isDirMissing) {
        try {
            $null = New-Item -ItemType Directory -Path $auditDir -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to create audit dir: $auditDir (failure: $($_.Exception.Message))" -Level "error"
            return $null
        }
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:AuditFilePath = Join-Path $auditDir ("audit-{0}-{1}.jsonl" -f $Action, $stamp)
    $script:AuditAction   = $Action

    # Write a header record so empty / corrupt files are easy to spot.
    $header = [ordered]@{
        ts        = (Get-Date -Format "o")
        action    = $Action
        operation = "session-start"
        host      = $env:COMPUTERNAME
        user      = $env:USERNAME
        pid       = $PID
        scriptDir = $ScriptDir
    }
    $isHeaderOk = _Append-AuditLine -Record $header
    if ($isHeaderOk) {
        Write-Log "Audit log opened: $script:AuditFilePath" -Level "info"
    }
    return $script:AuditFilePath
}

function Get-RegistryAuditPath {
    return $script:AuditFilePath
}

function _Append-AuditLine {
    <#
    .SYNOPSIS
        Internal: serialize one record + append it as a single JSONL line.
        Never throws -- logs and returns $false on any IO failure.
    #>
    param([Parameter(Mandatory)] $Record)

    $isPathMissing = [string]::IsNullOrWhiteSpace($script:AuditFilePath)
    if ($isPathMissing) { return $false }

    try {
        # Compress=$true keeps each record on a single line (true JSONL).
        $line = $Record | ConvertTo-Json -Depth 6 -Compress
        Add-Content -LiteralPath $script:AuditFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        Write-Log "Failed to append to audit file: $script:AuditFilePath (failure: $($_.Exception.Message))" -Level "warn"
        return $false
    }
}

function Write-RegistryAuditEvent {
    <#
    .SYNOPSIS
        Append one structured event to the current run's audit file.
    .PARAMETER Operation
        add          -- a new key was created or its (Default)/command was set
        remove       -- a key that existed was deleted
        skip-absent  -- uninstall asked to remove a key that was already gone
        fail         -- write or delete attempt failed
    .PARAMETER Values
        Optional hashtable of registry values that were written, e.g.
            @{ "(Default)" = "Open with Code"; "Icon" = "..."; "command" = "..." }
        Used on Operation=add to give auditors the exact value blobs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('add','remove','skip-absent','fail')]
        [string] $Operation,

        [Parameter(Mandatory)] [string] $Edition,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $RegPath,

        [hashtable] $Values,
        [string]    $Reason
    )

    $isInitialized = -not [string]::IsNullOrWhiteSpace($script:AuditFilePath)
    if (-not $isInitialized) {
        # Auto-init in the rarely-expected case the caller forgot.
        Write-Log "Audit not initialized -- skipping event ($Operation $RegPath)" -Level "warn"
        return $false
    }

    $record = [ordered]@{
        ts        = (Get-Date -Format "o")
        action    = $script:AuditAction
        operation = $Operation
        edition   = $Edition
        target    = $Target
        regPath   = $RegPath
    }
    if ($PSBoundParameters.ContainsKey('Values') -and $Values) {
        $record["values"] = $Values
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $record["reason"] = $Reason
    }

    return (_Append-AuditLine -Record $record)
}

function Get-RegistryAuditSummary {
    <#
    .SYNOPSIS
        Read back the CURRENT run's audit JSONL file and group every event
        by operation. Used by the post-op verification step so the user
        sees exactly which registry keys were added, removed, skipped, or
        failed -- no need to grep the JSONL by hand.

    .OUTPUTS
        PSCustomObject with:
          .auditPath  -- path to the JSONL file (or $null)
          .added      -- @( @{ regPath; edition; target; values } ... )
          .removed    -- @( @{ regPath; edition; target } ... )
          .skipped    -- @( @{ regPath; edition; target } ... )  (skip-absent)
          .failed     -- @( @{ regPath; edition; target; reason } ... )
          .totalAdded / .totalRemoved / .totalSkipped / .totalFailed
    #>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{
        auditPath    = $script:AuditFilePath
        added        = @()
        removed      = @()
        skipped      = @()
        failed       = @()
        totalAdded   = 0
        totalRemoved = 0
        totalSkipped = 0
        totalFailed  = 0
    }

    $isPathMissing = [string]::IsNullOrWhiteSpace($script:AuditFilePath)
    if ($isPathMissing) { return $result }
    $isFileMissing = -not (Test-Path -LiteralPath $script:AuditFilePath)
    if ($isFileMissing) {
        Write-Log "Audit file not found at: $script:AuditFilePath (failure: cannot summarize a file that does not exist)" -Level "warn"
        return $result
    }

    try {
        $lines = Get-Content -LiteralPath $script:AuditFilePath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Failed to read audit file: $script:AuditFilePath (failure: $($_.Exception.Message))" -Level "warn"
        return $result
    }

    foreach ($line in $lines) {
        $isBlank = [string]::IsNullOrWhiteSpace($line)
        if ($isBlank) { continue }
        try {
            $rec = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            # Skip corrupt line, but flag it -- file path + reason per CODE RED rule.
            Write-Log "Skipping corrupt audit line in: $script:AuditFilePath (failure: $($_.Exception.Message))" -Level "warn"
            continue
        }

        $hasOp = $rec.PSObject.Properties.Name -contains 'operation'
        if (-not $hasOp) { continue }

        switch ($rec.operation) {
            'add' {
                $result.added += [pscustomobject]@{
                    regPath = $rec.regPath
                    edition = $rec.edition
                    target  = $rec.target
                    values  = $(if ($rec.PSObject.Properties.Name -contains 'values') { $rec.values } else { $null })
                }
            }
            'remove' {
                $result.removed += [pscustomobject]@{
                    regPath = $rec.regPath
                    edition = $rec.edition
                    target  = $rec.target
                }
            }
            'skip-absent' {
                $result.skipped += [pscustomobject]@{
                    regPath = $rec.regPath
                    edition = $rec.edition
                    target  = $rec.target
                }
            }
            'fail' {
                $result.failed += [pscustomobject]@{
                    regPath = $rec.regPath
                    edition = $rec.edition
                    target  = $rec.target
                    reason  = $(if ($rec.PSObject.Properties.Name -contains 'reason') { $rec.reason } else { $null })
                }
            }
            default { } # session-start and any future op are ignored on purpose.
        }
    }

    $result.totalAdded   = $result.added.Count
    $result.totalRemoved = $result.removed.Count
    $result.totalSkipped = $result.skipped.Count
    $result.totalFailed  = $result.failed.Count
    return $result
}
