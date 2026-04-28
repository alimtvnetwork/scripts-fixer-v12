# --------------------------------------------------------------------------
#  Models orchestrator -- backend picker, catalog loading, CSV resolution
# --------------------------------------------------------------------------

function Get-BackendCatalog {
    <#
    .SYNOPSIS
        Loads the model catalog for a backend ("llama-cpp" or "ollama").
        Returns array of {id, displayName, backend} objects.
    #>
    param(
        [Parameter(Mandatory)] [string]$Backend,
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [string]$ScriptsRoot
    )

    $backendCfg = $Config.backends.$Backend
    if (-not $backendCfg) { return @() }

    $catalogPath = Join-Path $ScriptsRoot $backendCfg.scriptFolder $backendCfg.catalogFile
    $hasCatalog = Test-Path $catalogPath
    if (-not $hasCatalog) {
        Write-Log "Catalog not found: $catalogPath" -Level "warn"
        return @()
    }

    $raw = Get-Content $catalogPath -Raw | ConvertFrom-Json

    # Drill into nested path if specified (e.g. ollama config has "defaultModels")
    $items = if ($backendCfg.catalogPath) { $raw.($backendCfg.catalogPath) } else { $raw.models }

    $idField   = $backendCfg.idField
    $nameField = $backendCfg.displayField

    $result = @()
    foreach ($item in $items) {
        $result += [PSCustomObject]@{
            id          = $item.$idField
            displayName = $item.$nameField
            backend     = $Backend
            raw         = $item
        }
    }
    return $result
}

function Show-BackendPicker {
    <#
    .SYNOPSIS
        Interactive backend chooser. Returns "llama-cpp", "ollama", "both", or $null.
    #>
    param([Parameter(Mandatory)] [PSObject]$LogMessages)

    Write-Host ""
    Write-Host $LogMessages.messages.pickBackend -ForegroundColor Cyan
    Write-Host ""
    Write-Host $LogMessages.messages.backendLlama  -ForegroundColor White
    Write-Host $LogMessages.messages.backendOllama -ForegroundColor White
    Write-Host $LogMessages.messages.backendBoth   -ForegroundColor White
    Write-Host ""
    Write-Host $LogMessages.messages.backendQuit   -ForegroundColor DarkGray
    Write-Host ""

    $input = Read-Host -Prompt $LogMessages.messages.backendPrompt
    $trimmed = $input.Trim().ToLower()

    switch ($trimmed) {
        "1"        { return "llama-cpp" }
        "llama"    { return "llama-cpp" }
        "llama-cpp"{ return "llama-cpp" }
        "2"        { return "ollama" }
        "ollama"   { return "ollama" }
        "3"        { return "both" }
        "both"     { return "both" }
        default    { return $null }
    }
}

function Show-ModelList {
    <#
    .SYNOPSIS
        Prints a flat list of models from one or both catalogs.
    #>
    param(
        [Parameter(Mandatory)] [array]$Models,
        [string]$BackendLabel = "all backends"
    )

    Write-Host ""
    Write-Host "  Available models ($BackendLabel): $($Models.Count)" -ForegroundColor Cyan
    Write-Host ""
    $idCol = 42
    Write-Host ("  {0,-8} {1,-$idCol} {2}" -f "Backend", "Id", "Display Name") -ForegroundColor Yellow
    Write-Host ("  " + ("-" * 90)) -ForegroundColor DarkGray
    foreach ($m in $Models) {
        $color = if ($m.backend -eq "llama-cpp") { "White" } else { "Cyan" }
        Write-Host ("  {0,-8} {1,-$idCol} {2}" -f $m.backend, $m.id, $m.displayName) -ForegroundColor $color
    }
    Write-Host ""
}

function Resolve-CsvIds {
    <#
    .SYNOPSIS
        Given a CSV string of model ids, returns matching catalog entries
        (case-insensitive, partial-match-friendly via -like).
    #>
    param(
        [Parameter(Mandatory)] [string]$Csv,
        [Parameter(Mandatory)] [array]$AllModels,
        [Parameter(Mandatory)] [PSObject]$LogMessages
    )

    $ids = $Csv -split '[,\s]+' | Where-Object { $_.Length -gt 0 }
    Write-Log ($LogMessages.messages.csvResolveStart -replace '\{count\}', $ids.Count) -Level "info"

    $matched = @()
    foreach ($id in $ids) {
        $needle = $id.Trim().ToLower()
        $hit = $AllModels | Where-Object { $_.id.ToLower() -eq $needle } | Select-Object -First 1
        if (-not $hit) {
            # Try partial match (e.g. "qwen2.5-coder" matches "qwen2.5-coder-3b")
            $hit = $AllModels | Where-Object { $_.id.ToLower() -like "*$needle*" } | Select-Object -First 1
        }
        if ($hit) {
            $line = $LogMessages.messages.csvResolved -replace '\{id\}', $id -replace '\{backend\}', $hit.backend
            Write-Log $line -Level "success"
            $matched += $hit
        } else {
            $line = $LogMessages.messages.csvUnknown -replace '\{id\}', $id
            Write-Log $line -Level "warn"
        }
    }
    return $matched
}

function Invoke-BackendInstall {
    <#
    .SYNOPSIS
        Dispatches install of one or more models to the appropriate backend script.
        Models param: array of {id, backend, raw} entries.
    #>
    param(
        [Parameter(Mandatory)] [array]$Models,
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [PSObject]$LogMessages
    )

    $byBackend = $Models | Group-Object backend
    foreach ($group in $byBackend) {
        $backend = $group.Name
        $ids     = ($group.Group | ForEach-Object { $_.id }) -join ","
        $folder  = $Config.backends.$backend.scriptFolder
        $script  = Join-Path (Join-Path $ScriptsRoot $folder) "run.ps1"

        $line = $LogMessages.messages.dispatching -replace '\{backend\}', $backend
        Write-Log $line -Level "info"

        if ($backend -eq "ollama") {
            # Pass model slugs via env var; script 42 reads OLLAMA_PULL_MODELS
            $env:OLLAMA_PULL_MODELS = $ids
            & $script pull
            Remove-Item Env:\OLLAMA_PULL_MODELS -ErrorAction SilentlyContinue
        } else {
            # llama.cpp: pass via env var read by helpers/model-picker.ps1
            $env:LLAMA_CPP_INSTALL_IDS = $ids
            & $script all
            Remove-Item Env:\LLAMA_CPP_INSTALL_IDS -ErrorAction SilentlyContinue
        }
    }
}
