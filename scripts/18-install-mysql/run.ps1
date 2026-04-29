# --------------------------------------------------------------------------
#  Script 18 -- Install MySQL
#  Popular open-source relational database
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Help,
    [switch]$Interactive,
    [string]$MysqlPort,
    [string]$MysqlDataDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "symlink-utils.ps1")
. (Join-Path $sharedDir "interactive.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\mysql.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Interactive prompt (port + data dir BEFORE installing anything) ---------
#  -Interactive | --interactive | -i  -> ask before any install verb. The
#  captured answers are persisted to .resolved/18-interactive.json and, when
#  they differ from MySQL defaults (3306 / C:\ProgramData\MySQL\MySQL Server
#  X.Y\Data), wired into a my.ini override post-install in a follow-up step.
$argList = @()
try { $argList = @($MyInvocation.UnboundArguments) } catch { $argList = @() }
$isInteractive = $Interactive -or (Test-InteractiveFlag -Argv $argList)
if ([string]::IsNullOrWhiteSpace($MysqlPort))    { $MysqlPort    = '3306' }
if ([string]::IsNullOrWhiteSpace($MysqlDataDir)) { $MysqlDataDir = 'C:\ProgramData\MySQL\Data' }

if ($isInteractive) {
    Write-Host ""
    Write-Host "  --interactive: collecting MySQL port + data directory" -ForegroundColor Cyan
    $MysqlPort    = Read-PromptWithDefault -Label 'MySQL port'             -Default $MysqlPort    -Validator { param($v) Test-PortValue    -Value $v }
    $MysqlDataDir = Read-PromptWithDefault -Label 'MySQL data directory'    -Default $MysqlDataDir -Validator { param($v) Test-PathWritable -Value $v }
    Write-Host ("  -> port='{0}' datadir='{1}'" -f $MysqlPort, $MysqlDataDir) -ForegroundColor Green
}
if (-not (Test-PortValue -Value $MysqlPort)) {
    Write-Host ("Invalid -MysqlPort '{0}' (expected 1..65535)" -f $MysqlPort) -ForegroundColor Red
    return
}
if (-not (Test-PathWritable -Value $MysqlDataDir)) {
    Write-Host ("Invalid -MysqlDataDir '{0}' (must exist or have an existing parent)" -f $MysqlDataDir) -ForegroundColor Red
    return
}
# Persist captured answers.
$resolvedDir = Join-Path (Split-Path -Parent $scriptDir) ".resolved"
try {
    if (-not (Test-Path -LiteralPath $resolvedDir)) {
        [void](New-Item -ItemType Directory -Path $resolvedDir -Force -ErrorAction Stop)
    }
    $rPath = Join-Path $resolvedDir "18-interactive.json"
    @{ port = [int]$MysqlPort; dataDir = $MysqlDataDir; capturedAt = (Get-Date).ToString('o'); interactive = [bool]$isInteractive } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $rPath -Encoding UTF8
    Write-Host ("  Wrote MySQL port/datadir selection to {0}" -f $rPath) -ForegroundColor DarkGray
} catch {
    Write-Host ("[FILE-ERROR] path={0} reason={1}" -f $resolvedDir, $_.Exception.Message) -ForegroundColor Red
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "MySQL Server" `
    -Source "https://chocolatey.org/install (pkg: mysql)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\MySQL\MySQL Server"
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
if ($hasPathParam) {
    $devDir = $Path
    Write-Log "Using user-specified dev directory: $devDir" -Level "info"
} else {
    $devDir = Resolve-DevDir -Config $config.devDir
}
Initialize-DevDir -Path $devDir
$env:DEV_DIR = $devDir

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-Mysql -DbConfig $config.database -LogMessages $logMessages
    return
}

# -- Install -------------------------------------------------------------------
$ok = Install-Mysql -DbConfig $config.database -LogMessages $logMessages 

# -- Create symlink to dev directory ------------------------------------------
if ($ok) {
    New-DbSymlink -Name ($config.database.chocoPackage) -VerifyCommand ($config.database.verifyCommand) -DevDir $devDir
}

$isSuccess = $ok -eq $true
if ($isSuccess) {
    Write-Log $logMessages.messages.setupComplete -Level "success"
} else {
    Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
}

# -- Save log ------------------------------------------------------------------

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}