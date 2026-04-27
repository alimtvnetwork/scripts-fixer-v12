<#
.SYNOPSIS
    Cross-OS SSH key state ledger helpers.

.DESCRIPTION
    Reads/writes a JSON ledger at ~/.lovable/ssh-keys-state.json that
    records every SSH key operation performed by the os subcommands
    (gen-key / install-key / revoke-key) on this host. The same schema
    is honoured by the Unix shell helpers so the ledger survives when
    the same home dir is shared (e.g. WSL <-> Windows over a roaming
    profile, or NFS-mounted home dirs).

    Schema (top-level object):
      {
        "version": 1,
        "host": "<computername>",
        "user": "<username>",
        "updated": "<ISO8601 UTC>",
        "entries": [
          {
            "ts":          "<ISO8601 UTC>",
            "action":      "generate" | "install" | "revoke",
            "fingerprint": "SHA256:...",
            "keyPath":     "<absolute path to .pub or authorized_keys>",
            "source":      "gen-key" | "install-key" | "revoke-key" | "...",
            "comment":     "<key comment / GECOS, optional>",
            "host":        "<computername>",
            "user":        "<username>"
          }
        ]
      }

    All writes are atomic (write-temp + rename). All reads tolerate a
    missing/corrupt ledger and fall back to a fresh schema, logging the
    EXACT path + reason for any IO failure (CODE-RED rule).
#>

function Get-SshLedgerPath {
    $dir = Join-Path $env:USERPROFILE ".lovable"
    return (Join-Path $dir "ssh-keys-state.json")
}

function Get-NowIso8601Utc {
    return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Read-SshLedger {
    $path = Get-SshLedgerPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{
            version = 1
            host    = $env:COMPUTERNAME
            user    = $env:USERNAME
            updated = (Get-NowIso8601Utc)
            entries = @()
        }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $obj.entries) { $obj | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force }
        return $obj
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "SSH ledger unreadable at exact path: '$path' (failure: $($_.Exception.Message)). Starting fresh." -Level "warn"
        }
        return [PSCustomObject]@{
            version = 1
            host    = $env:COMPUTERNAME
            user    = $env:USERNAME
            updated = (Get-NowIso8601Utc)
            entries = @()
        }
    }
}

function Write-SshLedger {
    param([Parameter(Mandatory)]$Ledger)

    $path = Get-SshLedgerPath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "Failed to create ledger dir at exact path: '$dir' (failure: $($_.Exception.Message))" -Level "fail"
            }
            return $false
        }
    }
    $Ledger.updated = (Get-NowIso8601Utc)
    $tmp = "$path.tmp"
    try {
        $json = $Ledger | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        return $true
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Failed to write SSH ledger at exact path: '$path' (failure: $($_.Exception.Message))" -Level "fail"
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Add-SshLedgerEntry {
    param(
        [Parameter(Mandatory)][ValidateSet("generate","install","revoke")][string]$Action,
        [string]$Fingerprint,
        [string]$KeyPath,
        [string]$Source,
        [string]$Comment
    )
    $ledger = Read-SshLedger
    $entry = [PSCustomObject]@{
        ts          = (Get-NowIso8601Utc)
        action      = $Action
        fingerprint = $Fingerprint
        keyPath     = $KeyPath
        source      = $Source
        comment     = $Comment
        host        = $env:COMPUTERNAME
        user        = $env:USERNAME
    }
    $ledger.entries = @($ledger.entries) + $entry
    return (Write-SshLedger -Ledger $ledger)
}
