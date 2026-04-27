<#
.SYNOPSIS
    _schema.ps1 -- PowerShell sibling of scripts-linux/68-user-mgmt/helpers/_schema.sh.

.DESCRIPTION
    Shared strict-JSON-schema validator for the four Windows *-from-json.ps1
    loaders. The rule DSL, public API, and TSV output contract match the
    bash version verbatim so a single schema definition (allowed/required/
    fields/mutex strings) can be authored once and used on both OSes.

    This implementation does NOT depend on jq -- it walks PSCustomObject
    property trees natively and emits the same TSV rows the bash _report
    helper consumes ('ERROR<TAB>field<TAB>reason' / 'WARN<TAB>...').

.PUBLIC API (mirrors bash names; PS-cased)
    Initialize-UmSchemaArray   <file> <wrapperKey> [-AllowStrings]
        -> sets script-scope $script:UmNormalizedJson (PSObject[]) and
           $script:UmNormalizedCount. Returns $false on parse failure
           (already logged via Write-Log).

    Test-UmSchemaRecord        <rec> <allowed> <required> <specs> [<mutex>]
        -> returns string[] of TSV rows (empty array on clean record).

    Write-UmSchemaReport       <i> <file> <rows> [-Mode rich|plain]
        -> walks rows, emits Write-Log lines, sets $script:UmSchemaErrCount.

    Get-UmSchemaRecordName     <rec>
        -> echoes .name / "<missing>" / "<not-an-object>". Never throws.

.RULE DSL (identical to bash _schema.sh)
    nestr     non-empty string
    str       string (may be empty)
    bool      boolean
    uid       non-negative integer or numeric string
    nestrarr  array of non-empty strings

    Mutex pairs: space-separated 'a,b'. Both true => ERROR on field 'a'.

.CODE RED
    Every failure path includes the exact JSON path under inspection so
    the operator can grep their input file. The wrapping templates in
    log-messages.json supply the file path; this helper supplies the
    record index + field.
#>

if ($script:UmSchemaLoaded) { return }
$script:UmSchemaLoaded = $true

# --------------------------------------------------------------------------
# Initialize-UmSchemaArray <file> <wrapper> [-AllowStrings]
# Mirrors um_schema_normalize_array.
# --------------------------------------------------------------------------
function Initialize-UmSchemaArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$WrapperKey,
        [switch]$AllowStrings
    )

    if (-not (Test-Path -LiteralPath $File)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "JSON parse failed for exact path: '$File' (failure: file does not exist)" -Level "fail"
        }
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $File -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "JSON parse failed for exact path: '$File' (failure: $($_.Exception.Message))" -Level "fail"
        }
        return $false
    }

    # Normalise into a single PSObject[] regardless of input shape.
    $array = $null
    if ($parsed -is [System.Array]) {
        $array = @($parsed)
    } elseif ($parsed -is [PSCustomObject] -and ($parsed.PSObject.Properties.Name -contains $WrapperKey)) {
        $inner = $parsed.$WrapperKey
        if ($inner -isnot [System.Array]) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "JSON parse failed for exact path: '$File' (failure: top-level '.$WrapperKey' must be an array)" -Level "fail"
            }
            return $false
        }
        $array = @($inner)
    } elseif ($parsed -is [PSCustomObject]) {
        $array = @($parsed)
    } else {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "JSON parse failed for exact path: '$File' (failure: top-level must be object or array)" -Level "fail"
        }
        return $false
    }

    if ($AllowStrings) {
        $array = @(
            foreach ($el in $array) {
                if ($el -is [string]) { [PSCustomObject]@{ name = $el } } else { $el }
            }
        )
    }

    $script:UmNormalizedJson  = $array
    $script:UmNormalizedCount = $array.Count
    return $true
}

# --------------------------------------------------------------------------
# Get-UmSchemaRecordName <rec>
# Mirrors um_schema_record_name.
# --------------------------------------------------------------------------
function Get-UmSchemaRecordName {
    param([Parameter(Mandatory)]$Record)
    if ($null -eq $Record)            { return "<not-an-object>" }
    if ($Record -isnot [PSCustomObject]) { return "<not-an-object>" }
    if (-not ($Record.PSObject.Properties.Name -contains "name")) { return "<missing>" }
    $n = $Record.name
    if ($null -eq $n) { return "<missing>" }
    return [string]$n
}

# --------------------------------------------------------------------------
# Internal: cheap PS analogue of jq's `type` -> string.
# Returns one of: null, boolean, number, string, array, object.
# --------------------------------------------------------------------------
function _Get-UmJsonType {
    param($Value)
    if ($null -eq $Value)              { return "null" }
    if ($Value -is [bool])             { return "boolean" }
    if ($Value -is [string])           { return "string" }
    if ($Value -is [System.Array])     { return "array" }
    # ConvertFrom-Json emits Int32/Int64/Double for numbers.
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return "number"
    }
    if ($Value -is [PSCustomObject])   { return "object" }
    return "object"   # fallback -- treat unknowns as object so they fail type checks loudly
}

# --------------------------------------------------------------------------
# Test-UmSchemaRecord <rec> <allowed> <required> <specs> [<mutex>]
# Mirrors um_schema_validate_record. Returns string[] of TSV rows.
# --------------------------------------------------------------------------
function Test-UmSchemaRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Allowed,
        [string]$Required = "",
        [string]$Specs = "",
        [string]$Mutex = ""
    )

    $rows = New-Object System.Collections.Generic.List[string]

    # Top-level shape check first (mirrors bash early-return on non-object).
    if ($Record -isnot [PSCustomObject]) {
        $t = _Get-UmJsonType $Record
        $rows.Add("ERROR`t<root>`tnot an object (got $t)") | Out-Null
        return $rows.ToArray()
    }

    $present = @{}
    foreach ($p in $Record.PSObject.Properties) { $present[$p.Name] = $true }

    # ---- Required-field checks ----
    foreach ($r in ($Required -split '\s+' | Where-Object { $_ })) {
        if (-not $present.ContainsKey($r)) {
            $rows.Add("ERROR`t$r`tmissing required field") | Out-Null
        }
    }

    # ---- Per-field rule clauses ----
    foreach ($item in ($Specs -split '\s+' | Where-Object { $_ })) {
        $field, $rule = $item -split ':', 2
        if (-not $present.ContainsKey($field)) { continue }   # absent => skip (matches jq `if has(field)` gate)
        $val = $Record.$field
        $vt  = _Get-UmJsonType $val

        switch ($rule) {
            'nestr' {
                if ($vt -eq 'null')          { $rows.Add("ERROR`t$field`tnull value") | Out-Null }
                elseif ($vt -ne 'string')    { $rows.Add("ERROR`t$field`twrong type: expected string, got $vt") | Out-Null }
                elseif ($val.Length -eq 0)   { $rows.Add("ERROR`t$field`tempty string") | Out-Null }
            }
            'str' {
                if ($vt -ne 'string')        { $rows.Add("ERROR`t$field`twrong type: expected string, got $vt") | Out-Null }
            }
            'bool' {
                if ($vt -ne 'boolean')       { $rows.Add("ERROR`t$field`twrong type: expected boolean, got $vt") | Out-Null }
            }
            'uid' {
                if ($vt -eq 'number') {
                    if ([Math]::Floor([double]$val) -ne [double]$val -or [double]$val -lt 0) {
                        $rows.Add("ERROR`t$field`tnot a non-negative integer ($val)") | Out-Null
                    }
                } elseif ($vt -eq 'string') {
                    if ($val -notmatch '^[0-9]+$') {
                        $rows.Add("ERROR`t$field`tstring is not numeric ($val)") | Out-Null
                    }
                } else {
                    $rows.Add("ERROR`t$field`twrong type: expected integer or numeric string, got $vt") | Out-Null
                }
            }
            'nestrarr' {
                if ($vt -ne 'array') {
                    $rows.Add("ERROR`t$field`twrong type: expected array, got $vt -- did you forget the [...] brackets?") | Out-Null
                } else {
                    for ($i = 0; $i -lt $val.Count; $i++) {
                        $iv  = $val[$i]
                        $ivt = _Get-UmJsonType $iv
                        if ($ivt -ne 'string') {
                            $preview = if ($null -eq $iv) { 'null' } else { ([string]$iv).Substring(0, [Math]::Min(80, ([string]$iv).Length)) }
                            $rows.Add("ERROR`t$field[$i]`twrong type: expected non-empty string, got $ivt (value=$preview)") | Out-Null
                        } elseif ($iv.Length -eq 0) {
                            $rows.Add("ERROR`t$field[$i]`tempty string") | Out-Null
                        }
                    }
                }
            }
            default {
                # Unknown rule -- silently ignored (matches bash behaviour).
            }
        }
    }

    # ---- Mutex pairs ----
    if ($Mutex) {
        foreach ($pair in ($Mutex -split '\s+' | Where-Object { $_ })) {
            $a, $b = $pair -split ',', 2
            if ((($Record.PSObject.Properties.Name -contains $a) -and ($Record.$a -eq $true)) -and
                (($Record.PSObject.Properties.Name -contains $b) -and ($Record.$b -eq $true))) {
                $rows.Add("ERROR`t$a`tcannot be true while $b is also true") | Out-Null
            }
        }
    }

    # ---- Unknown-field warnings (typo guard) ----
    $known = @{}
    foreach ($k in ($Allowed -split '\s+' | Where-Object { $_ })) { $known[$k] = $true }
    foreach ($k in $present.Keys) {
        if (-not $known.ContainsKey($k)) {
            $rows.Add("WARN`t$k`tunknown field (allowed: $Allowed)") | Out-Null
        }
    }

    return $rows.ToArray()
}

# --------------------------------------------------------------------------
# Write-UmSchemaReport <i> <file> <rows> [-Mode rich|plain]
# Mirrors um_schema_report. Sets $script:UmSchemaErrCount.
# --------------------------------------------------------------------------
function Write-UmSchemaReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rows,
        [ValidateSet('rich', 'plain')][string]$Mode = 'plain'
    )

    $script:UmSchemaErrCount = 0
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    foreach ($row in $Rows) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        $parts = $row -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $severity = $parts[0]; $field = $parts[1]; $reason = $parts[2]

        if ($severity -eq 'ERROR') {
            $script:UmSchemaErrCount++
            $msg = "JSON record #$Index in '$File' field '$field': $reason (failure: rejecting record)"
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log $msg -Level "fail"
            } else {
                Write-Host "[FAIL] $msg" -ForegroundColor Red
            }
        } elseif ($severity -eq 'WARN') {
            $msg = "JSON record #$Index in '$File' field '$field': $reason"
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log $msg -Level "warn"
            } else {
                Write-Host "[WARN] $msg" -ForegroundColor Yellow
            }
        }
    }
}
