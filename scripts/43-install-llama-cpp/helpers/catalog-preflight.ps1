# --------------------------------------------------------------------------
#  helpers/catalog-preflight.ps1
#  Schema validator for models-catalog.json. Run before any tool that reads
#  or mutates the catalog (regen-list, fill-sha256) so failures surface as
#  precise, actionable errors instead of late ConvertFrom-Json crashes.
#
#  Public functions:
#    Test-CatalogSchema   -- validates file + structure, returns $true/$false
#    Assert-CatalogSchema -- same, but logs a banner + exits caller via $false
#
#  Validation layers (CODE RED: every failure logs exact path + reason):
#    1. File exists + readable + parses as JSON.
#    2. Top-level: 'models' array is present and non-empty.
#    3. Per-model required keys: id, displayName, family, fileSizeGB,
#       ramRequiredGB, downloadUrl.
#    4. sha256 field is present on every model (may be empty string;
#       fill-sha256 needs the property to exist so it can populate it).
#    5. Duplicate id detection.
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

# Required per-model keys. Keep this list in sync with models-catalog.json.
$script:CatalogRequiredKeys = @(
    'id',
    'displayName',
    'family',
    'fileSizeGB',
    'ramRequiredGB',
    'downloadUrl'
)

function Test-CatalogSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CatalogPath,
        [switch] $Quiet
    )

    function _logFail([string]$msg) {
        if (-not $Quiet) { Write-Log $msg -Level "error" }
    }
    function _logOk([string]$msg) {
        if (-not $Quiet) { Write-Log $msg -Level "info" }
    }

    # -- Layer 1: file exists ------------------------------------------------
    $isMissing = -not (Test-Path -LiteralPath $CatalogPath)
    if ($isMissing) {
        _logFail "[PREFLIGHT] Catalog not found: $CatalogPath (failure: file does not exist)"
        return $false
    }

    # -- Layer 1b: file parses as JSON --------------------------------------
    try {
        $raw     = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop
        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        _logFail "[PREFLIGHT] Catalog JSON parse failed: $CatalogPath (failure: $($_.Exception.Message))"
        return $false
    }

    # -- Layer 2: top-level 'models' array ----------------------------------
    $hasModels = $catalog.PSObject.Properties.Name -contains "models"
    if (-not $hasModels) {
        _logFail "[PREFLIGHT] Catalog missing 'models' array: $CatalogPath (failure: top-level schema mismatch)"
        return $false
    }
    $models = @($catalog.models)
    $isEmpty = $models.Count -eq 0
    if ($isEmpty) {
        _logFail "[PREFLIGHT] Catalog 'models' array is empty: $CatalogPath (failure: nothing to process)"
        return $false
    }

    # -- Layer 3+4: per-model checks ----------------------------------------
    $errors    = @()
    $seenIds   = @{}
    $missingSha = 0
    $i = 0
    foreach ($m in $models) {
        $rowLabel = if ($m.PSObject.Properties.Name -contains "id" -and $m.id) { $m.id } else { "<row-$i>" }

        foreach ($key in $script:CatalogRequiredKeys) {
            $hasKey = $m.PSObject.Properties.Name -contains $key
            if (-not $hasKey) {
                $errors += "[PREFLIGHT] Model '$rowLabel' missing required key '$key' (failure: per-model schema mismatch in $CatalogPath)"
                continue
            }
            $val = $m.$key
            $isBlank = ($null -eq $val) -or ([string]::IsNullOrWhiteSpace([string]$val))
            if ($isBlank) {
                $errors += "[PREFLIGHT] Model '$rowLabel' has blank required key '$key' (failure: per-model schema mismatch in $CatalogPath)"
            }
        }

        # sha256 must exist as a property (may be empty string)
        $hasSha = $m.PSObject.Properties.Name -contains "sha256"
        if (-not $hasSha) {
            $errors += "[PREFLIGHT] Model '$rowLabel' missing 'sha256' field (failure: fill-sha256 requires the property to exist; add ""sha256"": """" in $CatalogPath)"
        } else {
            $shaVal = [string]$m.sha256
            $isShaBlank = [string]::IsNullOrWhiteSpace($shaVal)
            if ($isShaBlank) { $missingSha++ }
        }

        # duplicate id detection
        if ($m.PSObject.Properties.Name -contains "id" -and $m.id) {
            $idKey = ([string]$m.id).ToLowerInvariant()
            if ($seenIds.ContainsKey($idKey)) {
                $errors += "[PREFLIGHT] Duplicate model id '$($m.id)' at row $i (failure: id must be unique in $CatalogPath; first seen at row $($seenIds[$idKey]))"
            } else {
                $seenIds[$idKey] = $i
            }
        }

        $i++
    }

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { _logFail $e }
        _logFail "[PREFLIGHT] Catalog validation failed: $($errors.Count) issue(s) in $CatalogPath"
        return $false
    }

    _logOk "[PREFLIGHT] Catalog OK: $($models.Count) models, $($seenIds.Count) unique ids, $missingSha missing sha256"
    return $true
}

function Assert-CatalogSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $CatalogPath)
    return (Test-CatalogSchema -CatalogPath $CatalogPath)
}
