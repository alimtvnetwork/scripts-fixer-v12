<#
.SYNOPSIS
    os startup-list -- enumerate managed startup entries across all 4 methods.

.EXAMPLES
    .\run.ps1 os startup-list
    .\run.ps1 os startup-list --scope user
    .\run.ps1 os startup-list --scope machine
    .\run.ps1 os startup-list --scope all
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$osDir       = Split-Path -Parent $scriptDir
$sharedDir   = Join-Path (Split-Path -Parent $osDir) "shared"
$configPath  = Join-Path $osDir "config.json"
$logMsgsPath = Join-Path $osDir "log-messages.json"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $scriptDir "_common.ps1")
. (Join-Path $scriptDir "_startup-common.ps1")

$logMessages = Import-JsonConfig $logMsgsPath
$startupCfg  = Get-StartupConfig -ConfigPath $configPath

$Scope = "all"
$i = 0
while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    switch -regex ($a) {
        '^--scope$' { $Scope = $Rest[$i+1]; $i += 2; continue }
        default     { $i += 1 }
    }
}
$Scope = $Scope.ToLower()
$isKnownScope = ($Scope -in @('user','machine','all'))
if (-not $isKnownScope) {
    Write-Log "Unknown --scope '$Scope'. Use 'user', 'machine', or 'all'." -Level "fail"
    exit 1
}

$tagPrefix = $script:STARTUP_TAG_PREFIX

$entries = New-Object System.Collections.ArrayList

# 1. Startup folder (.lnk)
$wantsUser    = ($Scope -eq 'user'    -or $Scope -eq 'all')
$wantsMachine = ($Scope -eq 'machine' -or $Scope -eq 'all')

if ($wantsUser) {
    $userFolder = Resolve-StartupPath -StartupCfg $startupCfg -Scope 'user'
    if (Test-Path $userFolder) {
        Get-ChildItem -Path $userFolder -Filter "$tagPrefix-*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$entries.Add([pscustomobject]@{
                Method = 'startup-folder'
                Scope  = 'user'
                Name   = Get-UntaggedName ([System.IO.Path]::GetFileNameWithoutExtension($_.Name))
                Target = $_.FullName
            })
        }
    }
}
if ($wantsMachine) {
    $commonFolder = Resolve-StartupPath -StartupCfg $startupCfg -Scope 'common'
    if (Test-Path $commonFolder) {
        Get-ChildItem -Path $commonFolder -Filter "$tagPrefix-*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$entries.Add([pscustomobject]@{
                Method = 'startup-folder'
                Scope  = 'machine'
                Name   = Get-UntaggedName ([System.IO.Path]::GetFileNameWithoutExtension($_.Name))
                Target = $_.FullName
            })
        }
    }
}

# 2. HKCU Run / HKLM Run
function Add-RunEntries {
    param([string]$RegPath, [string]$ScopeLabel, [string]$MethodLabel)
    if (-not (Test-Path $RegPath)) { return }
    $props = $null
    try { $props = Get-ItemProperty -Path $RegPath -ErrorAction Stop } catch { return }
    foreach ($p in $props.PSObject.Properties) {
        $isMeta = ($p.Name -like 'PS*')
        if ($isMeta) { continue }
        $isOurs = $p.Name.StartsWith("$tagPrefix-")
        if (-not $isOurs) { continue }
        [void]$entries.Add([pscustomobject]@{
            Method = $MethodLabel
            Scope  = $ScopeLabel
            Name   = Get-UntaggedName $p.Name
            Target = "$RegPath\$($p.Name) = $($p.Value)"
        })
    }
}
if ($wantsUser)    { Add-RunEntries -RegPath $startupCfg.registry.runUser    -ScopeLabel 'user'    -MethodLabel 'hkcu-run' }
if ($wantsMachine) { Add-RunEntries -RegPath $startupCfg.registry.runMachine -ScopeLabel 'machine' -MethodLabel 'hklm-run' }

# 3. Task Scheduler
try {
    $taskFolder = "\$($startupCfg.task.folder)\"
    $tasks = schtasks.exe /Query /FO CSV /V /TN $taskFolder 2>$null | ConvertFrom-Csv -ErrorAction SilentlyContinue
    if ($null -ne $tasks) {
        foreach ($t in $tasks) {
            $taskName = $t.TaskName
            $isOurs = $taskName -match "\\$tagPrefix-"
            if (-not $isOurs) { continue }
            $leaf = Split-Path -Leaf $taskName
            [void]$entries.Add([pscustomobject]@{
                Method = 'task'
                Scope  = if ($t.'Run As User' -match 'SYSTEM|Administrators') { 'machine' } else { 'user' }
                Name   = Get-UntaggedName $leaf
                Target = "$taskName  ->  $($t.'Task To Run')"
            })
        }
    }
} catch {
    Write-Log "schtasks query failed: $($_.Exception.Message)" -Level "warn"
}

# 4. Env vars (HKCU/HKLM Environment) -- only show ours by name match (no tagging possible on key names)
# Skipped from list to avoid listing user's own env vars; env entries are not tag-prefixed.

# ---------- output ----------
$header = ($logMessages.startup.listHeader -replace '\{tag\}', $tagPrefix)
Write-Host ""
Write-Host "  $header" -ForegroundColor Cyan
Write-Host "  $('=' * ($header.Length))" -ForegroundColor DarkGray

if ($entries.Count -eq 0) {
    Write-Host ""
    Write-Host "  $($logMessages.startup.listEmpty)" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

Write-Host ""
$entries | Sort-Object Method, Scope, Name | Format-Table -AutoSize Method, Scope, Name, Target
exit 0
