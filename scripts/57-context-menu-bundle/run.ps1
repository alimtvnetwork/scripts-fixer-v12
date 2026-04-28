# --------------------------------------------------------------------------
#  Script 57 -- Context Menu Bundle
#  Runs script 31 (PowerShell Here) + script 52 (VS Code folder repair)
#  in one guided pass, with a final summary of what changed.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'dry-run', 'status', 'all', '--help')]
    [string]$Command = 'install',

    [switch]$Yes,
    [string[]]$Skip,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir   = Split-Path -Parent $scriptDir
$sharedDir = Join-Path $rootDir 'shared'

. (Join-Path $sharedDir 'logging.ps1')
. (Join-Path $sharedDir 'help.ps1')
. (Join-Path $sharedDir "install-paths.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir 'config.json')
$logMessages = Import-JsonConfig (Join-Path $scriptDir 'log-messages.json')

if ($Help -or $Command -eq '--help') {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Context-menu bundle" `
    -Action "Configure" `
    -Source "$scriptDir (dispatches scripts 10/31/52/53/56)" `
    -Temp   ($env:TEMP + "\scripts-fixer\ctx-bundle") `
    -Target ("HKCR registry hives (multiple verbs)")
Initialize-Logging -ScriptName $logMessages.scriptName

if (-not $config.enabled) {
    Write-Log $logMessages.messages.scriptDisabled -Level 'warn'
    return
}

# ---- Resolve mode -----------------------------------------------------------
$normalized = if ($Command -eq 'all') { 'install' } else { $Command }
$isDryRun   = $normalized -eq 'dry-run'
$isStatus   = $normalized -eq 'status'
$isUninstall= $normalized -eq 'uninstall'

# ---- Admin check (skip for status / dry-run) --------------------------------
$needsAdmin = -not ($isStatus -or $isDryRun)
if ($needsAdmin) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log $logMessages.messages.notAdmin -Level 'error'
        return
    }
}

# ---- Status / dry-run preview ----------------------------------------------
if ($isStatus -or $isDryRun) {
    Write-Log $logMessages.messages.dryRunHeader -Level 'info'
    foreach ($c in $config.components) {
        Write-Host ""
        Write-Host ("  [{0}] {1}" -f $c.scriptId, $c.title) -ForegroundColor Cyan
        Write-Host ("    {0}" -f $c.description) -ForegroundColor DarkGray
        Write-Host "    Registry targets:" -ForegroundColor DarkGray
        foreach ($t in $c.registryTargets) {
            Write-Host ("      - {0}" -f $t) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    return
}

# ---- Helper: prompt yes/no --------------------------------------------------
function Confirm-Component {
    param([string]$Title)
    if ($Yes) { return $true }
    $prompt = ($logMessages.messages.promptComponent -f $Title)
    $answer = Read-Host -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $true }
    return ($answer -match '^(y|yes)$')
}

# ---- Run components ---------------------------------------------------------
$results = @()

foreach ($c in $config.components) {
    $compPath = Join-Path $rootDir $c.folder
    $runPath  = Join-Path $compPath 'run.ps1'

    # --skip filter (matches by id or short name)
    $isExcluded = $false
    if ($Skip) {
        foreach ($s in $Skip) {
            if ($c.id -like "*$s*" -or $s -eq $c.scriptId) { $isExcluded = $true }
        }
    }
    if ($isExcluded) {
        Write-Log ($logMessages.messages.skipFlag -f $c.title) -Level 'warn'
        $results += [pscustomobject]@{ Title = $c.title; Status = 'skipped'; Detail = 'excluded via -Skip' }
        continue
    }

    if (-not (Confirm-Component -Title $c.title)) {
        Write-Log ($logMessages.messages.skipComponent -f $c.title) -Level 'warn'
        $results += [pscustomobject]@{ Title = $c.title; Status = 'skipped'; Detail = 'declined at prompt' }
        continue
    }

    if (-not (Test-Path -LiteralPath $runPath)) {
        # CODE RED: file/path errors must include exact path + reason
        $msg = ($logMessages.messages.componentMissing -f $runPath)
        Write-Log $msg -Level 'error'
        $results += [pscustomobject]@{ Title = $c.title; Status = 'error'; Detail = "missing: $runPath" }
        continue
    }

    $args = if ($isUninstall) { $c.uninstallArgs } else { $c.installArgs }
    Write-Log ($logMessages.messages.runComponent -f $c.title) -Level 'info'

    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runPath @args
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $code = 1
        Write-Log ("Exception while running {0}: {1}" -f $runPath, $_.Exception.Message) -Level 'error'
    }

    if ($code -eq 0) {
        Write-Log ($logMessages.messages.componentOk -f $c.title) -Level 'success'
        $action = if ($isUninstall) { 'removed' } else { 'installed' }
        $results += [pscustomobject]@{
            Title  = $c.title
            Status = $action
            Detail = ($c.registryTargets -join '; ')
        }
    } else {
        Write-Log ($logMessages.messages.componentFail -f $c.title, $code) -Level 'error'
        $results += [pscustomobject]@{
            Title  = $c.title
            Status = 'failed'
            Detail = "exit=$code (path: $runPath)"
        }
    }
}

# ---- Summary ----------------------------------------------------------------
Write-Host ""
Write-Log $logMessages.messages.summaryHeader -Level 'info'
foreach ($r in $results) {
    $line = ($logMessages.messages.summaryRow -f $r.Title, $r.Status.ToUpper())
    $color = switch ($r.Status) {
        'installed' { 'Green' }
        'removed'   { 'Green' }
        'skipped'   { 'Yellow' }
        default     { 'Red' }
    }
    Write-Host $line -ForegroundColor $color
    if ($r.Detail) {
        Write-Host ("      -> {0}" -f $r.Detail) -ForegroundColor DarkGray
    }
}
Write-Log $logMessages.messages.summaryFooter -Level 'info'

$failed = @($results | Where-Object { $_.Status -eq 'failed' -or $_.Status -eq 'error' })
if ($failed.Count -gt 0) { exit 1 }
