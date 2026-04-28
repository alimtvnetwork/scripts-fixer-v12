# --------------------------------------------------------------------------
#  Scripts Fixer -- Models Orchestrator
#  Pick a backend (llama.cpp / Ollama), then browse and install models.
#  Spec: spec/models/readme.md
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Args,

    [string]$Backend,
    [string]$Install,
    [switch]$List,
    [switch]$Force,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir   = Join-Path (Split-Path -Parent $scriptDir) "shared"
$scriptsRoot = Split-Path -Parent $scriptDir

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source orchestrator helpers -----------------------------------------
. (Join-Path $scriptDir "helpers\picker.ps1")
. (Join-Path $scriptDir "helpers\ollama-search.ps1")
. (Join-Path $scriptDir "helpers\uninstall.ps1")

# -- Load config & log messages ----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help) {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "AI model dispatcher" `
    -Action "Dispatch" `
    -Source "$scriptDir\config.json (model catalog)" `
    -Temp   ($env:TEMP + "\scripts-fixer\models") `
    -Target ("varies per backend (Ollama / llama.cpp install dirs)")
Initialize-Logging -ScriptName $logMessages.scriptName

try {
    # ── Parse positional args ────────────────────────────────────────────
    # First positional may be: "list", a CSV of model ids, or empty (interactive)
    $firstArg = if ($Args -and $Args.Count -gt 0) { $Args[0].Trim() } else { "" }
    $secondArg = if ($Args -and $Args.Count -gt 1) { $Args[1].Trim() } else { "" }

    $isListMode      = $List -or $firstArg.ToLower() -eq "list"
    $isSearchMode    = $firstArg.ToLower() -eq "search"
    $isUninstallMode = $firstArg.ToLower() -eq "uninstall" -or $firstArg.ToLower() -eq "remove" -or $firstArg.ToLower() -eq "rm"
    $hasInstallParam = -not [string]::IsNullOrWhiteSpace($Install)
    $reservedFirstArgs = @("list", "search", "uninstall", "remove", "rm")
    $hasCsvFirstArg  = $firstArg -and ($reservedFirstArgs -notcontains $firstArg.ToLower()) -and $firstArg -match '[a-z0-9]'

    # ── List mode ────────────────────────────────────────────────────────
    if ($isListMode) {
        $filter = if ($firstArg.ToLower() -eq "list") { $secondArg.ToLower() } else { "" }

        $all = @()
        if (-not $filter -or $filter -eq "llama" -or $filter -eq "llama-cpp") {
            $all += Get-BackendCatalog -Backend "llama-cpp" -Config $config -ScriptsRoot $scriptsRoot
        }
        if (-not $filter -or $filter -eq "ollama") {
            $all += Get-BackendCatalog -Backend "ollama" -Config $config -ScriptsRoot $scriptsRoot
        }
        $label = if ($filter) { $filter } else { "all backends" }
        Show-ModelList -Models $all -BackendLabel $label
        return
    }

    # ── Search mode (Ollama Hub) ─────────────────────────────────────────
    # Usage: .\run.ps1 models search <query>  -- scrapes ollama.com/library
    # for any pullable model, not just the static defaults in script 42's config.
    if ($isSearchMode) {
        $query = $secondArg
        if ([string]::IsNullOrWhiteSpace($query)) {
            $query = Read-Host -Prompt "  Search Ollama Hub for"
        }

        $results = Invoke-OllamaHubSearch -Query $query
        $hasResults = $results.Count -gt 0
        if (-not $hasResults) {
            Write-Log $logMessages.messages.searchNoResults -Level "warn"
            return
        }

        Show-OllamaHubResults -Results $results -Query $query

        $picks = Read-OllamaHubSelection -MaxIndex $results.Count
        if ($null -eq $picks) {
            Write-Log $logMessages.messages.searchAborted -Level "info"
            return
        }
        if ($picks.Count -eq 0) {
            Write-Log $logMessages.messages.searchSkipped -Level "info"
            return
        }

        # Build CSV of slugs (with optional :tag) and dispatch to script 42 via env var.
        $slugs = @()
        foreach ($p in $picks) {
            $r = $results[$p.Index - 1]
            $slug = if ($p.Tag) { "$($r.slug):$($p.Tag)" } else { $r.slug }
            $slugs += $slug
        }
        $csvSlugs = $slugs -join ","
        $line = $logMessages.messages.searchDispatching -replace '\{slugs\}', $csvSlugs
        Write-Log $line -Level "info"

        $folder = $config.backends.ollama.scriptFolder
        $target = Join-Path (Join-Path $scriptsRoot $folder) "run.ps1"
        $env:OLLAMA_PULL_MODELS = $csvSlugs
        try {
            & $target pull
        } finally {
            Remove-Item Env:\OLLAMA_PULL_MODELS -ErrorAction SilentlyContinue
        }

        Write-Log $logMessages.messages.complete -Level "success"
        return
    }

    # ── Uninstall mode ───────────────────────────────────────────────────
    # Lists everything currently on this machine across both backends, lets
    # the user multi-select with the same syntax (1,3 | 1-5 | all), then
    # deletes via each backend's natural removal path.
    if ($isUninstallMode) {
        $projectRoot = Split-Path -Parent $scriptsRoot

        Write-Log $logMessages.messages.uninstallScanning -Level "info"
        $llamaModels  = Get-InstalledLlamaCppModels -ScriptsRoot $scriptsRoot -ProjectRoot $projectRoot
        $ollamaModels = Get-InstalledOllamaModels

        # Optional backend filter from secondArg or -Backend param
        $uninstFilter = if ($Backend) { $Backend.ToLower() } elseif ($secondArg) { $secondArg.ToLower() } else { "" }
        $combined = @()
        if (-not $uninstFilter -or $uninstFilter -eq "llama" -or $uninstFilter -eq "llama-cpp") {
            $combined += $llamaModels
        }
        if (-not $uninstFilter -or $uninstFilter -eq "ollama") {
            $combined += $ollamaModels
        }

        if ($combined.Count -eq 0) {
            Write-Log $logMessages.messages.uninstallNothing -Level "info"
            return
        }

        Show-UninstallList -All $combined
        $picks = Read-UninstallSelection -MaxIndex $combined.Count
        if ($null -eq $picks) {
            Write-Log $logMessages.messages.uninstallAborted -Level "info"
            return
        }
        if ($picks.Count -eq 0) {
            Write-Log $logMessages.messages.uninstallSkipped -Level "info"
            return
        }

        $targets = @()
        foreach ($i in $picks) { $targets += $combined[$i - 1] }

        if ($Force) {
            Write-Log $logMessages.messages.uninstallForceSkip -Level "warn"
        } else {
            $isConfirmed = Confirm-Uninstall -Targets $targets
            if (-not $isConfirmed) {
                Write-Log $logMessages.messages.uninstallAborted -Level "info"
                return
            }
        }

        $summary = Invoke-ModelUninstall -Targets $targets
        $hasFailures = $summary.Fail -gt 0
        if ($hasFailures) {
            Write-Log $logMessages.messages.uninstallPartial -Level "warn"
        } else {
            Write-Log $logMessages.messages.uninstallComplete -Level "success"
        }
        return
    }

    # ── CSV install mode (positional or -Install) ────────────────────────
    $csv = if ($hasInstallParam) { $Install } elseif ($hasCsvFirstArg) { $firstArg } else { "" }
    $hasCsv = -not [string]::IsNullOrWhiteSpace($csv)

    if ($hasCsv) {
        # Build catalog from selected backend or both
        $backends = if ($Backend) { @($Backend.ToLower()) } else { @("llama-cpp", "ollama") }
        $allModels = @()
        foreach ($b in $backends) {
            $allModels += Get-BackendCatalog -Backend $b -Config $config -ScriptsRoot $scriptsRoot
        }

        $matched = Resolve-CsvIds -Csv $csv -AllModels $allModels -LogMessages $logMessages
        if ($matched.Count -eq 0) {
            Write-Log $logMessages.messages.csvNoneFound -Level "error"
            return
        }
        Invoke-BackendInstall -Models $matched -Config $config -ScriptsRoot $scriptsRoot -LogMessages $logMessages
        Write-Log $logMessages.messages.complete -Level "success"
        return
    }

    # ── Interactive mode ─────────────────────────────────────────────────
    $chosen = if ($Backend) { $Backend.ToLower() } else { Show-BackendPicker -LogMessages $logMessages }
    if (-not $chosen) {
        Write-Log $logMessages.messages.noBackendSelected -Level "warn"
        return
    }

    if ($chosen -eq "both") {
        $all  = @()
        $all += Get-BackendCatalog -Backend "llama-cpp" -Config $config -ScriptsRoot $scriptsRoot
        $all += Get-BackendCatalog -Backend "ollama"    -Config $config -ScriptsRoot $scriptsRoot
        Show-ModelList -Models $all -BackendLabel "both"
        Write-Host "  Tip: re-run with a CSV to install, e.g. .\run.ps1 models <id1>,<id2>" -ForegroundColor DarkGray
        return
    }

    # Dispatch to the backend's own interactive picker (script 42 or 43)
    $folder = $config.backends.$chosen.scriptFolder
    $target = Join-Path (Join-Path $scriptsRoot $folder) "run.ps1"
    $line = $logMessages.messages.dispatching -replace '\{backend\}', $chosen
    Write-Log $line -Level "info"
    & $target

    Write-Log $logMessages.messages.complete -Level "success"

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
