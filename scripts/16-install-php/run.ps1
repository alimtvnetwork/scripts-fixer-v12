# --------------------------------------------------------------------------
#  Script 16 -- Install PHP (+ phpMyAdmin)
#  Supports 3 modes via -Mode parameter:
#    php+phpmyadmin  (default) -- PHP + phpMyAdmin
#    php-only                  -- PHP only
#    phpmyadmin-only           -- phpMyAdmin only
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Help,
    [switch]$Interactive,
    [string]$PhpVersion,
    [ValidateSet("php+phpmyadmin", "php-only", "phpmyadmin-only")]
    [string]$Mode = ""
)

# -- Resolve mode: param > env var > default -----------------------------------
if ([string]::IsNullOrWhiteSpace($Mode)) {
    $envMode = $env:PHP_MODE
    $hasEnvMode = -not [string]::IsNullOrWhiteSpace($envMode)
    if ($hasEnvMode) {
        $Mode = $envMode
    } else {
        $Mode = "php+phpmyadmin"
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

$script:ScriptDir = $scriptDir

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "interactive.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\php.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Interactive prompt (collect PHP version BEFORE installing anything) -----
#  -Interactive | --interactive | -i  -> ask before any install verb.
#  Windows Chocolatey installs the latest by default; the captured answer is
#  persisted to .resolved/16-interactive.json so downstream tools have an
#  audit trail of what the operator requested.
$argList = @()
try { $argList = @($MyInvocation.UnboundArguments) } catch { $argList = @() }
$isInteractive = $Interactive -or (Test-InteractiveFlag -Argv $argList)
if ([string]::IsNullOrWhiteSpace($PhpVersion)) { $PhpVersion = 'latest' }

if ($isInteractive) {
    Write-Host ""
    Write-Host "  --interactive: collecting PHP version" -ForegroundColor Cyan
    $PhpVersion = Read-PromptWithDefault -Label 'PHP version (latest|8.1|8.2|8.3)' -Default $PhpVersion -Validator { param($v) Test-PhpVersion -Value $v }
    Write-Host ("  -> PHP version='{0}'" -f $PhpVersion) -ForegroundColor Green
}
if (-not (Test-PhpVersion -Value $PhpVersion)) {
    Write-Host ("Invalid -PhpVersion '{0}' (expected: latest|8.1|8.2|8.3)" -f $PhpVersion) -ForegroundColor Red
    return
}
# Persist captured answer.
$resolvedDir = Join-Path (Split-Path -Parent $scriptDir) ".resolved"
try {
    if (-not (Test-Path -LiteralPath $resolvedDir)) {
        [void](New-Item -ItemType Directory -Path $resolvedDir -Force -ErrorAction Stop)
    }
    $rPath = Join-Path $resolvedDir "16-interactive.json"
    @{ phpVersion = $PhpVersion; capturedAt = (Get-Date).ToString('o'); interactive = [bool]$isInteractive } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $rPath -Encoding UTF8
    Write-Host ("  Wrote PHP version selection to {0}" -f $rPath) -ForegroundColor DarkGray
} catch {
    Write-Host ("[FILE-ERROR] path={0} reason={1}" -f $resolvedDir, $_.Exception.Message) -ForegroundColor Red
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "PHP" `
    -Source "https://chocolatey.org/install (pkg: php)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\tools\php"
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

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-Php -Config $config -LogMessages $logMessages
    return
}

# -- Mode announcement ---------------------------------------------------------
$modeLabel = switch ($Mode) {
    "php+phpmyadmin"  { "PHP + phpMyAdmin (install both)" }
    "php-only"        { "PHP only (no phpMyAdmin)" }
    "phpmyadmin-only" { "phpMyAdmin only (no PHP install)" }
}
Write-Log "Mode: $modeLabel" -Level "info"
Write-Host ""

# -- Install PHP ---------------------------------------------------------------
$phpOk = $true
$isPhpNeeded = $Mode -ne "phpmyadmin-only"
if ($isPhpNeeded) {
    $phpOk = Install-Php -Config $config.php -LogMessages $logMessages
} else {
    Write-Log "Skipping PHP installation (phpmyadmin-only mode)" -Level "info"
}

# -- Install phpMyAdmin --------------------------------------------------------
$pmaOk = $true
$isPmaNeeded = $Mode -ne "php-only"
if ($isPmaNeeded) {
    $pmaOk = Install-PhpMyAdmin -PmaConfig $config.phpmyadmin -LogMessages $logMessages
} else {
    Write-Log $logMessages.messages.pmaSkipped -Level "info"
}

# -- Summary -------------------------------------------------------------------
$isAllGood = $phpOk -and $pmaOk
if ($isAllGood) {
    Write-Log $logMessages.messages.setupComplete -Level "success"
} else {
    Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
}

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
