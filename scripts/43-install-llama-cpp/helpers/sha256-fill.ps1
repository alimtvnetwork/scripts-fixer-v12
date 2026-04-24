# --------------------------------------------------------------------------
#  helpers/sha256-fill.ps1
#  Populates empty sha256 fields in models-catalog.json by HEAD-requesting
#  each download URL and reading the X-Linked-Etag response header (which
#  Hugging Face sets to the file's sha256 for all LFS-tracked GGUFs).
#
#  Implements spec/2025-batch/suggestions/02-sha256-population.md.
#
#  Public functions:
#    Invoke-Sha256Fill  -- main entry point
#
#  Behavior:
#    1. Reads catalog, skips entries with non-empty sha256 (idempotent).
#    2. Optional -Ids "id1,id2" filter.
#    3. HEAD each downloadUrl, validates header is 64-hex-char.
#    4. Backup catalog to .bak-<timestamp>, then atomic write.
#
#  Logging prefixes: [FETCH] [FILL] [MANUAL] [SKIP] (per spec 02).
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

function Test-IsValidSha256 {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    return [bool]([regex]::IsMatch($Value, '^[a-f0-9]{64}$'))
}

function Get-LinkedEtag {
    param([Parameter(Mandatory)] [string] $Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head `
            -MaximumRedirection 0 -ErrorAction Stop -UseBasicParsing
    } catch [System.Net.WebException] {
        # HF returns 302 for LFS files; the redirect response still carries
        # X-Linked-Etag in the Headers collection.
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return $null }
    } catch {
        Write-Log "[FETCH] HEAD failed for $Url (failure: $($_.Exception.Message))" -Level "warn"
        return $null
    }

    $etag = $null
    try {
        if ($resp.Headers -is [System.Collections.IDictionary]) {
            if ($resp.Headers.Contains("X-Linked-Etag")) {
                $etag = $resp.Headers["X-Linked-Etag"]
            } elseif ($resp.Headers.Contains("x-linked-etag")) {
                $etag = $resp.Headers["x-linked-etag"]
            }
        } else {
            $etag = $resp.Headers["X-Linked-Etag"]
        }
    } catch { $etag = $null }

    if ($null -eq $etag) { return $null }
    # Strip surrounding quotes and W/ weak prefix if present.
    $etag = ([string]$etag).Trim('"').TrimStart('W','/').Trim('"').ToLowerInvariant()
    return $etag
}

function Invoke-Sha256Fill {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CatalogPath,
        [string] $Ids = ""
    )

    $isCatalogMissing = -not (Test-Path -LiteralPath $CatalogPath)
    if ($isCatalogMissing) {
        Write-Log "Catalog file not found: $CatalogPath (failure: cannot fill sha256 without source catalog)" -Level "error"
        return $false
    }

    try {
        $raw     = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop
        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Failed to parse catalog JSON: $CatalogPath (failure: $($_.Exception.Message))" -Level "error"
        return $false
    }

    $hasModels = $catalog.PSObject.Properties.Name -contains "models"
    if (-not $hasModels) {
        Write-Log "Catalog has no 'models' array: $CatalogPath (failure: schema mismatch)" -Level "error"
        return $false
    }

    $idFilter = @()
    $hasIdFilter = -not [string]::IsNullOrWhiteSpace($Ids)
    if ($hasIdFilter) {
        $idFilter = $Ids.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }
    }

    # -- Backup before any mutation -----------------------------------------
    $stamp     = (Get-Date -Format "yyyyMMdd-HHmmss")
    $backupPath = "$CatalogPath.bak-$stamp"
    try {
        Copy-Item -LiteralPath $CatalogPath -Destination $backupPath -Force -ErrorAction Stop
        Write-Log "Backup written: $backupPath" -Level "info"
    } catch {
        Write-Log "Failed to write backup: $backupPath (failure: $($_.Exception.Message))" -Level "error"
        return $false
    }

    $stats = @{ filled = 0; skipped = 0; manual = 0; errors = 0 }

    foreach ($m in $catalog.models) {
        $hasSha = $m.PSObject.Properties.Name -contains "sha256"
        if (-not $hasSha) {
            Add-Member -InputObject $m -NotePropertyName "sha256" -NotePropertyValue "" -Force
        }
        $existing = [string]$m.sha256
        $isAlreadyFilled = -not [string]::IsNullOrWhiteSpace($existing)
        if ($isAlreadyFilled) {
            Write-Log "[SKIP] $($m.id) already has sha256" -Level "info"
            $stats.skipped++
            continue
        }

        if ($hasIdFilter) {
            $isInFilter = $idFilter -contains $m.id.ToLowerInvariant()
            if (-not $isInFilter) { continue }
        }

        $url = [string]$m.downloadUrl
        $hasUrl = -not [string]::IsNullOrWhiteSpace($url)
        if (-not $hasUrl) {
            Write-Log "[MANUAL] $($m.id) has no downloadUrl (failure: cannot HEAD without URL)" -Level "warn"
            $stats.manual++
            continue
        }

        Write-Log "[FETCH] $($m.id) -> $url" -Level "info"
        $etag = Get-LinkedEtag -Url $url
        $hasEtag = -not [string]::IsNullOrWhiteSpace($etag)
        if (-not $hasEtag) {
            Write-Log "[MANUAL] $($m.id) has no X-Linked-Etag header (failure: HF did not advertise sha256 for $url)" -Level "warn"
            $stats.manual++
            continue
        }

        $isHexValid = Test-IsValidSha256 -Value $etag
        if (-not $isHexValid) {
            Write-Log "[MANUAL] $($m.id) etag '$etag' is not a 64-char sha256 (failure: unexpected header format from $url)" -Level "warn"
            $stats.manual++
            continue
        }

        $m.sha256 = $etag
        Write-Log "[FILL] $($m.id) sha256 = $etag" -Level "success"
        $stats.filled++
    }

    # -- Atomic write -------------------------------------------------------
    $tempPath = "$CatalogPath.tmp"
    try {
        $jsonOut = $catalog | ConvertTo-Json -Depth 12
        Set-Content -LiteralPath $tempPath -Value $jsonOut -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $CatalogPath -Force -ErrorAction Stop
    } catch {
        Write-Log "Failed to write updated catalog: $CatalogPath (failure: $($_.Exception.Message))" -Level "error"
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    Write-Log ("sha256 fill complete: filled={0}, skipped={1}, manual={2}, errors={3}" -f `
        $stats.filled, $stats.skipped, $stats.manual, $stats.errors) -Level "success"
    Write-Log "Backup retained at: $backupPath" -Level "info"
    return $true
}