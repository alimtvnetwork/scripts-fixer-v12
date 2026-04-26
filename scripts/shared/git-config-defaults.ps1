# --------------------------------------------------------------------------
#  shared/git-config-defaults.ps1
#
#  Single source of truth for global git config defaults. Consumed by:
#    - scripts/07-install-git/helpers/git.ps1     (Configure-GitGlobal)
#    - any other script that needs to (re)apply defaults
#
#  The companion bash helper (`scripts-linux/_shared/git-config-defaults.sh`)
#  reads the same `git-config-defaults.json`. Keep the two in sync.
#
#  Public:
#    Get-DefaultGitConfigSpec [-ConfigPath <path>]
#    Apply-DefaultGitConfig   [-ConfigPath <path>] [-LogMessages <obj>]
#                             [-Overrides <hashtable>] [-WhatIf]
#
#  Modes (per entry in defaults[]):
#    set-if-empty          -- write only when `git config --global <k>` is empty
#    set-always            -- always overwrite
#    set-if-missing-value  -- use --add semantics; skip if exact value already present
# --------------------------------------------------------------------------

# Bootstrap shared helpers (logging) when sourced standalone.
$_sharedDir   = Split-Path -Parent $PSCommandPath
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}
$_jsonUtilsPath = Join-Path $_sharedDir "json-utils.ps1"
if ((Test-Path $_jsonUtilsPath) -and -not (Get-Command Import-JsonConfig -ErrorAction SilentlyContinue)) {
    . $_jsonUtilsPath
}

function Get-DefaultGitConfigSpec {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $_sharedDir "git-config-defaults.json"
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-FileError $ConfigPath "git-config-defaults.json missing -- cannot apply defaults"
        return $null
    }
    try {
        return Import-JsonConfig $ConfigPath
    } catch {
        Write-FileError $ConfigPath "failed to parse git-config-defaults.json: $_"
        return $null
    }
}

function _Resolve-GitDefaultsForOS {
    param($Spec)
    # Build a flat list of @{ Key; Value; Mode } after applying OS overrides.
    $os = "windows"  # this helper only runs on PowerShell-on-Windows in production
    $overrides = $null
    $hasOverrides = $Spec.PSObject.Properties.Name -contains "osOverrides"
    if ($hasOverrides -and $Spec.osOverrides.PSObject.Properties.Name -contains $os) {
        $overrides = $Spec.osOverrides.$os
    }
    $list = @()
    foreach ($entry in $Spec.defaults) {
        $key   = $entry.key
        $value = $entry.value
        $mode  = if ($entry.PSObject.Properties.Name -contains "mode") { $entry.mode } else { "set-if-empty" }
        if ($overrides -and ($overrides.PSObject.Properties.Name -contains $key)) {
            $value = $overrides.$key
        }
        $list += [pscustomobject]@{ Key = $key; Value = $value; Mode = $mode }
    }
    return $list
}

function _Get-CurrentGlobal {
    param([string]$Key)
    # Return ALL values for multi-valued keys (safe.directory) joined by `;` (rare).
    # For single-valued keys, returns the single value or '' when unset.
    $vals = & git config --global --get-all $Key 2>$null
    if ($null -eq $vals) { return "" }
    if ($vals -is [System.Array]) { return ($vals -join ";") }
    return [string]$vals
}

function _Apply-OneEntry {
    param(
        [string]$Key,
        [string]$Value,
        [string]$Mode,
        [bool]$WhatIfMode
    )
    $current = _Get-CurrentGlobal -Key $Key
    $hasCurrent = -not [string]::IsNullOrWhiteSpace($current)

    switch ($Mode) {
        "set-if-empty" {
            if ($hasCurrent) {
                Write-Log "[git-config] keep $Key = $current (already set)" -Level "info"
                return
            }
        }
        "set-if-missing-value" {
            # Multi-value key: skip if THIS exact value is already in the list.
            $existingValues = & git config --global --get-all $Key 2>$null
            $isPresent = $false
            if ($null -ne $existingValues) {
                foreach ($v in @($existingValues)) { if ($v -eq $Value) { $isPresent = $true; break } }
            }
            if ($isPresent) {
                Write-Log "[git-config] keep $Key (value '$Value' already present)" -Level "info"
                return
            }
            if ($WhatIfMode) {
                Write-Log "[git-config] WHATIF: git config --global --add $Key '$Value'" -Level "info"
                return
            }
            & git config --global --add $Key $Value
            if ($LASTEXITCODE -eq 0) {
                Write-Log "[git-config] add  $Key = $Value" -Level "success"
            } else {
                Write-FileError "(git config --global --add $Key)" "exit=$LASTEXITCODE"
            }
            return
        }
        "set-always" { } # fall through
        default {
            Write-Log "[git-config] unknown mode '$Mode' for $Key -- skipping" -Level "warn"
            return
        }
    }

    if ($WhatIfMode) {
        Write-Log "[git-config] WHATIF: git config --global $Key '$Value'" -Level "info"
        return
    }
    & git config --global $Key $Value
    if ($LASTEXITCODE -eq 0) {
        Write-Log "[git-config] set  $Key = $Value" -Level "success"
    } else {
        Write-FileError "(git config --global $Key)" "exit=$LASTEXITCODE"
    }
}

function Apply-DefaultGitConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        $LogMessages,
        [hashtable]$Overrides,
        [switch]$WhatIf
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-FileError "(git)" "git not on PATH -- cannot apply defaults"
        return $false
    }
    $spec = Get-DefaultGitConfigSpec -ConfigPath $ConfigPath
    if ($null -eq $spec) { return $false }

    Write-Log "[git-config] applying defaults from $(if($ConfigPath){$ConfigPath}else{'shared/git-config-defaults.json'})" -Level "info"

    # 1. Scalar defaults (with OS-override resolution)
    $entries = _Resolve-GitDefaultsForOS -Spec $spec
    foreach ($e in $entries) {
        $value = $e.Value
        if ($Overrides -and $Overrides.ContainsKey($e.Key)) { $value = [string]$Overrides[$e.Key] }
        _Apply-OneEntry -Key $e.Key -Value $value -Mode $e.Mode -WhatIfMode:$WhatIf.IsPresent
    }

    # 2. URL rewrites (--add semantics; never clobbers existing rewrites)
    $hasRewrites = $spec.PSObject.Properties.Name -contains "urlRewrites"
    if ($hasRewrites) {
        foreach ($r in @($spec.urlRewrites)) {
            $key = "url.$($r.to).insteadOf"
            _Apply-OneEntry -Key $key -Value $r.from -Mode "set-if-missing-value" -WhatIfMode:$WhatIf.IsPresent
        }
    }

    Write-Log "[git-config] defaults applied" -Level "success"
    return $true
}