# --------------------------------------------------------------------------
#  Script 30 -- Install Databases (Orchestrator)
#  Interactive database installer menu that dispatches to individual
#  numbered DB scripts (18-29).
#  Supports: -All, -Only, -Skip, -Uninstall, -DryRun.
# --------------------------------------------------------------------------
param(
    [string]$Path,
    [switch]$All,
    [string]$Skip,
    [string]$Only,
    [string]$Drive,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir   = Join-Path (Split-Path -Parent $scriptDir) "shared"
$scriptsRoot = Split-Path -Parent $scriptDir

$script:ScriptDir = $scriptDir

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "symlink-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\menu.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help) {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Database installer dispatcher" `
    -Action "Dispatch" `
    -Source "$scriptDir\config.json (db catalog)" `
    -Temp   ($env:TEMP + "\scripts-fixer\databases") `
    -Target ("varies per chosen DB (forwards to scripts/18..29)")

# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Assert admin --------------------------------------------------------------
$hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isNotAdmin = -not $hasAdminRights
if ($isNotAdmin) {
    Write-Log $logMessages.messages.notAdmin -Level "error"
    return
}

# -- Resolve dev directory -----------------------------------------------------
$hasPathParam = -not [string]::IsNullOrWhiteSpace($Path)
$hasDriveOverride = -not [string]::IsNullOrWhiteSpace($Drive)
if ($hasPathParam) {
    $devDir = $Path
    Write-Log "Using user-specified dev directory: $devDir" -Level "info"
} elseif ($hasDriveOverride) {
    $driveLetter = $Drive.TrimEnd(':', '\').Substring(0, 1).ToUpper()
    $devDir = "${driveLetter}:\dev-tool"
    Write-Log ($logMessages.messages.driveOverride -replace '\{drive\}', "${driveLetter}:") -Level "info"
} else {
    $devDir = Resolve-DevDir -Config $config.devDir
}
Initialize-DevDir -Path $devDir
$env:DEV_DIR = $devDir

# -- Build database list -------------------------------------------------------
$sequence = $config.sequence
$dbs      = $config.databases

# Apply -Only filter
$hasOnly = -not [string]::IsNullOrWhiteSpace($Only)
if ($hasOnly) {
    $onlyList = $Only -split ',' | ForEach-Object { $_.Trim().ToLower() }
    $sequence = $sequence | Where-Object { $_ -in $onlyList }
}

# Apply -Skip filter
$hasSkip = -not [string]::IsNullOrWhiteSpace($Skip)
if ($hasSkip) {
    $skipList = $Skip -split ',' | ForEach-Object { $_.Trim().ToLower() }
    $sequence = $sequence | Where-Object { $_ -notin $skipList }
}

# -- Helper: verify symlink after install --------------------------------------
function Test-PostInstallSymlink {
    param([string]$Key, [string]$Name)

    $dbDir = Join-Path $devDir "databases" $Key
    $hasLink = Test-Path $dbDir
    if (-not $hasLink) {
        Write-Log ($logMessages.messages.symlinkVerifyMissing -replace '\{name\}', $Name) -Level "warn"
        return
    }

    $item = Get-Item $dbDir -Force
    $isJunction = $item.Attributes -band [IO.FileAttributes]::ReparsePoint
    if ($isJunction) {
        $target = $item.Target
        Write-Log ($logMessages.messages.symlinkVerifyOk -replace '\{name\}', $Name -replace '\{path\}', $dbDir -replace '\{target\}', $target) -Level "success"
    } else {
        Write-Log ($logMessages.messages.symlinkVerifyNotJunction -replace '\{name\}', $Name -replace '\{path\}', $dbDir) -Level "warn"
    }
}

# -- Helper: invoke an individual DB script ------------------------------------
function Invoke-DbScript {
    param(
        [string]$Folder,
        [string]$Name,
        [string]$Key,
        [switch]$DryRun
    )

    $scriptPath = Join-Path (Join-Path $scriptsRoot $Folder) "run.ps1"
    $hasScript = Test-Path $scriptPath
    if (-not $hasScript) {
        Write-Log "Script not found: $scriptPath" -Level "error"
        return "fail"
    }

    if ($DryRun) {
        Write-Host "  [DRY] Would run: $Folder\run.ps1" -ForegroundColor Yellow
        return "skip"
    }

    Write-Log "Running $Name ($Folder)..." -Level "info"
    try {
        & $scriptPath
        Test-PostInstallSymlink -Key $Key -Name $Name
        return "ok"
    } catch {
        Write-Log "Failed: $($_.Exception.Message)" -Level "error"
        return "fail"
    }
}

# -- Helper: invoke uninstall for an individual DB script ----------------------
function Invoke-DbUninstall {
    param(
        [string]$Folder,
        [string]$Name,
        [string]$Key,
        [switch]$DryRun
    )

    $scriptPath = Join-Path (Join-Path $scriptsRoot $Folder) "run.ps1"
    $hasScript = Test-Path $scriptPath
    if (-not $hasScript) {
        Write-Log "Script not found: $scriptPath" -Level "error"
        return "fail"
    }

    if ($DryRun) {
        Write-Host "  [DRY] Would uninstall: $Folder\run.ps1 uninstall" -ForegroundColor Yellow
        return "skip"
    }

    Write-Log ($logMessages.messages.uninstallRunning -replace '\{name\}', $Name) -Level "info"
    try {
        & $scriptPath uninstall
        return "ok"
    } catch {
        Write-Log ($logMessages.messages.uninstallScriptFailed -replace '\{name\}', $Name -replace '\{error\}', $_.Exception.Message) -Level "error"
        return "fail"
    }
}

# -- Show summary --------------------------------------------------------------
function Show-DbSummary {
    param($SelectedKeys, $Results, $Dbs, [string]$ActionLabel = "Install")

    Write-Host ""
    $title = if ($ActionLabel -eq "Uninstall") { $logMessages.messages.uninstallSummaryTitle } else { $logMessages.messages.summaryTitle }
    Write-Host "  $title" -ForegroundColor Cyan
    foreach ($key in $SelectedKeys) {
        $dbConfig = $Dbs.$key
        $status = $Results[$key]
        $isOk = $status -eq "ok"
        $isFail = $status -eq "fail"
        if ($isOk) {
            Write-Host "    " -NoNewline; Write-Host "[OK]   " -ForegroundColor Green -NoNewline; Write-Host $dbConfig.name
        } elseif ($isFail) {
            Write-Host "    " -NoNewline; Write-Host "[FAIL] " -ForegroundColor Red -NoNewline; Write-Host $dbConfig.name
        } else {
            Write-Host "    " -NoNewline; Write-Host "[SKIP] " -ForegroundColor DarkGray -NoNewline; Write-Host $dbConfig.name
        }
    }
    Write-Host ""
}

# ==============================================================================
#  UNINSTALL MODE
# ==============================================================================
if ($Uninstall) {
    $selectedKeys = @()

    if ($All) {
        $selectedKeys = $sequence
    } elseif ($hasOnly) {
        $selectedKeys = $sequence
    } else {
        # Interactive: reuse the DB menu for selection
        $selectedKeys = Show-DbMenu -Config $config -LogMessages $logMessages
        $isQuit = $selectedKeys.Count -eq 0
        if ($isQuit) {
            Write-Log $logMessages.messages.menuInputQuit -Level "info"
            return
        }
    }

    # Dry run
    if ($DryRun) {
        Write-Host ""
        Write-Log $logMessages.messages.uninstallDryRunBanner -Level "warn"
        Write-Host ""
        foreach ($key in $selectedKeys) {
            $dbConfig = $dbs.$key
            $hasNoConfig = -not $dbConfig
            if ($hasNoConfig) { continue }
            Write-Host "  [WOULD UNINSTALL] $($dbConfig.name)" -ForegroundColor Yellow
        }
        Write-Log ("Dry run complete. {0} database(s) would be uninstalled." -f $selectedKeys.Count) -Level "success"
        return
    }

    # Confirmation prompt
    Write-Host ""
    Write-Log ($logMessages.messages.uninstallConfirmPrompt -replace '\{count\}', $selectedKeys.Count) -Level "warn"
    foreach ($key in $selectedKeys) {
        $dbConfig = $dbs.$key
        $hasNoConfig = -not $dbConfig
        if ($hasNoConfig) { continue }
        Write-Host "    $($dbConfig.name)" -ForegroundColor Yellow
    }
    Write-Host ""
    $confirm = Read-Host "  Type YES to confirm uninstall (or anything else to cancel)"
    $isConfirmed = $confirm -eq "YES"
    if (-not $isConfirmed) {
        Write-Log $logMessages.messages.uninstallCancelled -Level "info"
        return
    }

    # Execute uninstalls in reverse order
    $reversedKeys = @($selectedKeys)
    [array]::Reverse($reversedKeys)

    Write-Log ($logMessages.messages.uninstallStarting -replace '\{count\}', $selectedKeys.Count) -Level "info"
    $results = @{}
    foreach ($key in $reversedKeys) {
        $dbConfig = $dbs.$key
        $hasNoConfig = -not $dbConfig
        if ($hasNoConfig) { continue }

        $results[$key] = Invoke-DbUninstall -Folder $dbConfig.folder -Name $dbConfig.name -Key $key
    }

    Show-DbSummary -SelectedKeys $selectedKeys -Results $results -Dbs $dbs -ActionLabel "Uninstall"

    Save-ResolvedData -ScriptFolder "databases" -Data @{
        action    = "uninstall"
        results   = $results
        timestamp = (Get-Date -Format "o")
    }

    Write-Log $logMessages.messages.uninstallComplete -Level "success"
    return
}

# ==============================================================================
#  INSTALL MODE (existing behaviour)
# ==============================================================================

# -- Interactive menu (loop) or direct install ---------------------------------
$selectedKeys = @()

if ($All) {
    $selectedKeys = $sequence
} elseif ($hasOnly) {
    $selectedKeys = $sequence
} else {
    # Interactive menu loop
    while ($true) {
        $selectedKeys = Show-DbMenu -Config $config -LogMessages $logMessages

        $isQuit = $selectedKeys.Count -eq 0
        if ($isQuit) { return }

        # Run individual scripts for each selected DB
        $results = @{}
        foreach ($key in $selectedKeys) {
            $dbConfig = $dbs.$key
            $hasNoConfig = -not $dbConfig
            if ($hasNoConfig) { continue }

            $results[$key] = Invoke-DbScript -Folder $dbConfig.folder -Name $dbConfig.name -Key $key -DryRun:$DryRun
        }

        Show-DbSummary -SelectedKeys $selectedKeys -Results $results -Dbs $dbs

        # Save resolved state
        Save-ResolvedData -ScriptFolder "databases" -Data @{
            results   = $results
            timestamp = (Get-Date -Format "o")
        }

        Write-Log $logMessages.messages.loopBack -Level "info"
    }
}

# -- Non-interactive install (for -All or -Only) -------------------------------
if ($selectedKeys.Count -gt 0 -and ($All -or $hasOnly)) {
    $results = @{}
    foreach ($key in $selectedKeys) {
        $dbConfig = $dbs.$key
        $hasNoConfig = -not $dbConfig
        if ($hasNoConfig) { continue }

        $results[$key] = Invoke-DbScript -Folder $dbConfig.folder -Name $dbConfig.name -Key $key -DryRun:$DryRun
    }

    Show-DbSummary -SelectedKeys $selectedKeys -Results $results -Dbs $dbs
}

Write-Host ""
Write-Log $logMessages.messages.setupComplete -Level "success"

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
