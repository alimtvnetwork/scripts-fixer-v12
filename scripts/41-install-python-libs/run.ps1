# --------------------------------------------------------------------------
#  Script 41 -- Install Python Libraries
#  Installs common Python/ML libraries via pip into PYTHONUSERBASE.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Args,

    [switch]$Help
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
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\pip-libs.ps1")

# -- Load config & log messages -----------------------------------------------
$config       = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages  = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Resolve mode: param > env var > default -----------------------------------
$hasDefaultCommand = $Command.ToLower() -eq "all"
if ($hasDefaultCommand) {
    $envMode = $env:PYTHON_LIBS_MODE
    $hasEnvMode = -not [string]::IsNullOrWhiteSpace($envMode)
    if ($hasEnvMode) {
        $modeParts = $envMode -split '\s+', 2
        $Command = $modeParts[0]
        $hasModeArg = $modeParts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($modeParts[1])
        $hasArgs = $null -ne $Args -and $Args.Count -gt 0
        $isArgsMissing = -not $hasArgs
        if ($hasModeArg -and $isArgsMissing) {
            $Args = @($modeParts[1])
        }
    }
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Python libraries (pip)" `
    -Source "https://pypi.org (pip install via Python)" `
    -Temp   ($env:TEMP + "\scripts-fixer\pip-cache") `
    -Target ($env:APPDATA + "\Python\Site-Packages")

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

# -- Assert Python available ---------------------------------------------------
$isPythonReady = Assert-PythonAvailable -LogMessages $logMessages
if (-not $isPythonReady) { return }

# -- Resolve user site flag ----------------------------------------------------
$useUserSite = $config.installToUserSite
$hasUserBase = -not [string]::IsNullOrWhiteSpace($env:PYTHONUSERBASE)
if ($useUserSite -and $hasUserBase) {
    Write-Log ($logMessages.messages.usingUserSite -replace '\{path\}', $env:PYTHONUSERBASE) -Level "info"
} elseif ($useUserSite -and -not $hasUserBase) {
    Write-Log $logMessages.messages.noUserSite -Level "warn"
    $useUserSite = $false
}

# -- Execute subcommand --------------------------------------------------------
switch ($Command.ToLower()) {
    "all" {
        $successCount = Install-AllLibraries -Config $config -LogMessages $logMessages -UserSite:$useUserSite
    }
    "group" {
        $hasGroupArg = $Args -and $Args.Count -gt 0
        if (-not $hasGroupArg) {
            Write-Log "Usage: .\run.ps1 group <name>. Use 'list' to see groups." -Level "error"
            return
        }
        $successCount = Install-LibraryGroup -GroupName $Args[0] -Config $config -LogMessages $logMessages -UserSite:$useUserSite
    }
    "add" {
        $hasPackageArgs = $Args -and $Args.Count -gt 0
        if (-not $hasPackageArgs) {
            Write-Log "Usage: .\run.ps1 add <package1> <package2> ..." -Level "error"
            return
        }
        $pkgList = $Args -join ", "
        Write-Log ($logMessages.messages.installingCustom -replace '\{packages\}', $pkgList) -Level "info"
        $successCount = Install-PipPackages -Packages $Args -LogMessages $logMessages -UserSite:$useUserSite
    }
    "list" {
        Show-LibraryGroups -Config $config -LogMessages $logMessages
        return
    }
    "installed" {
        Show-InstalledPipPackages -LogMessages $logMessages
        return
    }
    "uninstall" {
        Uninstall-PipPackages -Packages $Args -Config $config -LogMessages $logMessages
        return
    }
    default {
        Write-Log ($logMessages.messages.unknownCommand -replace '\{command\}', $Command) -Level "error"
        return
    }
}

# -- Save resolved state -------------------------------------------------------
Write-Log $logMessages.messages.savingResolved -Level "info"

$pyExe = Resolve-PythonExe
$pipList = try { & $pyExe -m pip list --format=json 2>$null | ConvertFrom-Json } catch { @() }
$installedNames = ($pipList | ForEach-Object { $_.name }) -join ", "

Save-ResolvedData -ScriptFolder "41-install-python-libs" -Data @{
    installedPackages = $installedNames
    timestamp         = (Get-Date -Format "o")
}

Save-InstalledRecord -Name "python-libs" -Version "$(($pipList).Count) packages"

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
