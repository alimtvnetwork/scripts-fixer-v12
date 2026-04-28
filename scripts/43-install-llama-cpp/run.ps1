# --------------------------------------------------------------------------
#  Script 43 -- Install llama.cpp
#  Downloads llama.cpp binaries (CUDA/AVX2/KoboldCPP), extracts, adds to
#  PATH, and interactively downloads GGUF/GGML models via aria2c.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Help,

    [switch]$CheckUpdates,

    [switch]$Apply,

    [string]$Family = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "path-utils.ps1")
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "download-retry.ps1")
. (Join-Path $sharedDir "disk-space.ps1")
. (Join-Path $sharedDir "url-freshness.ps1")
. (Join-Path $sharedDir "aria2c-download.ps1")
. (Join-Path $sharedDir "aria2c-batch.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\llama-cpp.ps1")
. (Join-Path $scriptDir "helpers\model-picker.ps1")
. (Join-Path $scriptDir "helpers\catalog-update.ps1")
. (Join-Path $scriptDir "helpers\regen-models-list.ps1")
. (Join-Path $scriptDir "helpers\sha256-fill.ps1")
. (Join-Path $scriptDir "helpers\catalog-preflight.ps1")

# -- Load config & log messages -----------------------------------------------
$config       = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages  = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$catalogPath  = Join-Path $scriptDir "models-catalog.json"

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Catalog update mode (no admin / no install required) ---------------------
$isCheckUpdatesMode = $CheckUpdates -or ($Command -ieq "check-updates") -or ($Command -ieq "--check-updates")
if ($isCheckUpdatesMode) {
    Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "llama.cpp" `
    -Source "https://github.com/ggerganov/llama.cpp/releases (prebuilt zip)" `
    -Temp   ($env:TEMP + "\scripts-fixer\llama-cpp") `
    -Target ($env:LOCALAPPDATA + "\llama-cpp")
    Initialize-Logging -ScriptName $logMessages.scriptName
    try {
        Invoke-CatalogUpdateCheck -CatalogPath $catalogPath -ScriptDir $scriptDir `
            -FamilyFilter $Family -Apply:$Apply
    } catch {
        Write-Log "Catalog update check failed: $_" -Level "error"
        Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
    } finally {
        $hasAnyErrors = $script:_LogErrors.Count -gt 0
        Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
    }
    return
}

# -- Regenerate models-list.md (no admin required) ---------------------------
$isRegenListMode = ($Command -ieq "regen-list") -or ($Command -ieq "--regen-list")
if ($isRegenListMode) {
    Write-Banner -Title $logMessages.scriptName
    Initialize-Logging -ScriptName $logMessages.scriptName
    try {
        Write-Log $logMessages.messages.preflightStart -Level "info"
        $isCatalogValid = Test-CatalogSchema -CatalogPath $catalogPath
        if (-not $isCatalogValid) {
            Write-Log $logMessages.messages.preflightAbort -Level "error"
            return
        }
        $listPath = Join-Path $scriptDir "models-list.md"
        $isOk = Invoke-ModelsListRegen -CatalogPath $catalogPath -OutputPath $listPath
        if (-not $isOk) {
            Write-Log "models-list.md regeneration failed (failure: see preceding errors)" -Level "error"
        }
    } catch {
        Write-Log "regen-list crashed: $_" -Level "error"
        Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
    } finally {
        $hasAnyErrors = $script:_LogErrors.Count -gt 0
        Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
    }
    return
}

# -- Fill sha256 fields (no admin required) ----------------------------------
$isFillShaMode = ($Command -ieq "fill-sha256") -or ($Command -ieq "--fill-sha256")
if ($isFillShaMode) {
    Write-Banner -Title $logMessages.scriptName
    Initialize-Logging -ScriptName $logMessages.scriptName
    try {
        Write-Log $logMessages.messages.preflightStart -Level "info"
        $isCatalogValid = Test-CatalogSchema -CatalogPath $catalogPath
        if (-not $isCatalogValid) {
            Write-Log $logMessages.messages.preflightAbort -Level "error"
            return
        }
        $idsArg = if ($Path) { $Path } else { "" }
        $isOk = Invoke-Sha256Fill -CatalogPath $catalogPath -Ids $idsArg
        if (-not $isOk) {
            Write-Log "sha256 fill failed (failure: see preceding errors)" -Level "error"
        }
    } catch {
        Write-Log "fill-sha256 crashed: $_" -Level "error"
        Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
    } finally {
        $hasAnyErrors = $script:_LogErrors.Count -gt 0
        Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
    }
    return
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Disabled check ------------------------------------------------------------
$isDisabled = -not $config.enabled
if ($isDisabled) {
    Write-Log $logMessages.messages.scriptDisabled -Level "warn"
    return
}

# -- Assert admin --------------------------------------------------------------
$hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isNotAdmin = -not $hasAdminRights
if ($isNotAdmin) {
    Write-Log $logMessages.messages.notAdmin -Level "error"
    return
}

# -- Resolve dev directory -----------------------------------------------------
$hasPathParam = -not [string]::IsNullOrWhiteSpace($Path)
if ($hasPathParam) {
    $devDir = $Path
    Write-Log "Using user-specified dev directory: $devDir" -Level "info"
} elseif ($env:DEV_DIR) {
    $devDir = $env:DEV_DIR
} else {
    $devDir = Resolve-DevDir
}

# -- Resolve base directory for llama-cpp --------------------------------------
$baseDir = Join-Path $devDir $config.devDirSubfolder
$isDirMissing = -not (Test-Path $baseDir)
if ($isDirMissing) {
    New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
}
Write-Log "llama.cpp base directory: $baseDir" -Level "info"

# -- Execute subcommand --------------------------------------------------------
switch ($Command.ToLower()) {
    "all" {
        # Pre-check: validate pinned download URLs still resolve
        Write-Log $logMessages.messages.urlFreshnessCheck -Level "info"
        $isUrlOk = Test-UrlFreshness -Items $config.executables -LabelField "displayName"
        if (-not $isUrlOk) { return }

        # Pre-check disk space for executables
        $exeBytes = Get-TotalDownloadSize -Items $config.executables -SizeBytesField "expectedSizeBytes"
        $isExeDiskOk = Test-DiskSpace -TargetPath $baseDir -RequiredBytes $exeBytes -Label "llama.cpp executables"
        if (-not $isExeDiskOk) { return }

        Install-LlamaCppExecutables -Config $config -LogMessages $logMessages -BaseDir $baseDir

        # Interactive model installer
        Invoke-ModelInstaller -CatalogPath $catalogPath -DevDir $devDir `
            -DefaultModelsSubfolder $config.modelsConfig.devDirSubfolder `
            -Aria2Config $config.aria2c -DownloadConfig $config.download `
            -LogMessages $logMessages
    }
    "executables" {
        Write-Log $logMessages.messages.urlFreshnessCheck -Level "info"
        $isUrlOk = Test-UrlFreshness -Items $config.executables -LabelField "displayName"
        if (-not $isUrlOk) { return }

        $exeBytes = Get-TotalDownloadSize -Items $config.executables -SizeBytesField "expectedSizeBytes"
        $isExeDiskOk = Test-DiskSpace -TargetPath $baseDir -RequiredBytes $exeBytes -Label "llama.cpp executables"
        if (-not $isExeDiskOk) { return }
        Install-LlamaCppExecutables -Config $config -LogMessages $logMessages -BaseDir $baseDir
    }
    "models" {
        Invoke-ModelInstaller -CatalogPath $catalogPath -DevDir $devDir `
            -DefaultModelsSubfolder $config.modelsConfig.devDirSubfolder `
            -Aria2Config $config.aria2c -DownloadConfig $config.download `
            -LogMessages $logMessages
    }
    "uninstall" {
        Uninstall-LlamaCpp -Config $config -LogMessages $logMessages -BaseDir $baseDir
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"

$installedSlugs = @()
foreach ($item in $config.executables) {
    $targetFolder = Join-Path $baseDir $item.targetFolderName
    $isPresent = Test-Path $targetFolder
    if ($isPresent) { $installedSlugs += $item.slug }
}

Save-ResolvedData -ScriptFolder "43-install-llama-cpp" -Data @{
    baseDir        = $baseDir
    installedSlugs = $installedSlugs
    timestamp      = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.llamaSetupComplete -Level "success"

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
