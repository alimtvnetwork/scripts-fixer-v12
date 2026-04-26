<#
.SYNOPSIS
    os startup-remove <name> [--method ...]
    Remove a managed startup entry. If --method is omitted, search every
    method and remove the first match (warns if multiple methods hold it).

.EXAMPLES
    .\run.ps1 os startup-remove sync
    .\run.ps1 os startup-remove sync --method hkcu-run
    .\run.ps1 os startup-remove sync --yes
#>
param(
    [Parameter(Position = 0)]
    [string]$Name,

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

Initialize-Logging -ScriptName "startup-remove"

$Method  = ""
$AutoYes = $false
$i = 0
while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    switch -regex ($a) {
        '^--method$'   { $Method = $Rest[$i+1]; $i += 2; continue }
        '^--yes$|^-y$' { $AutoYes = $true; $i += 1; continue }
        default        { $i += 1 }
    }
}

$isNameMissing = [string]::IsNullOrWhiteSpace($Name)
if ($isNameMissing) {
    Write-Log "Missing <name>. Usage: .\run.ps1 os startup-remove <name> [--method ...]" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

$tagged = Get-TaggedName -Name $Name

# ---------- per-method removers ----------
function Remove-FromStartupFolder {
    param([string]$Tagged)
    $found = $false
    foreach ($scope in @('user','common')) {
        $folder = Resolve-StartupPath -StartupCfg $startupCfg -Scope $scope
        $lnk = Join-Path $folder "$Tagged.lnk"
        if (Test-Path $lnk) {
            try {
                Remove-Item -LiteralPath $lnk -Force -ErrorAction Stop
                Write-Log (($logMessages.startup.removeOk -replace '\{name\}', $Tagged -replace '\{method\}', "startup-folder ($scope)")) -Level "ok"
                $found = $true
            } catch {
                $err = ($logMessages.startup.removeFailed `
                    -replace '\{name\}', $Tagged `
                    -replace '\{method\}', "startup-folder ($scope)" `
                    -replace '\{error\}', "path=$lnk reason=$($_.Exception.Message)")
                Write-Log $err -Level "fail"
            }
        }
    }
    return $found
}

function Remove-FromRegistryRun {
    param([string]$Tagged, [string]$Hive)
    $regPath = if ($Hive -eq 'HKLM') { $startupCfg.registry.runMachine } else { $startupCfg.registry.runUser }
    if (-not (Test-Path $regPath)) { return $false }
    $exists = $null
    try { $exists = Get-ItemProperty -Path $regPath -Name $Tagged -ErrorAction Stop } catch { return $false }
    if ($null -eq $exists) { return $false }
    try {
        Remove-ItemProperty -Path $regPath -Name $Tagged -Force -ErrorAction Stop
        Write-Log (($logMessages.startup.removeOk -replace '\{name\}', $Tagged -replace '\{method\}', "$($Hive.ToLower())-run")) -Level "ok"
        return $true
    } catch {
        $err = ($logMessages.startup.removeFailed `
            -replace '\{name\}', $Tagged `
            -replace '\{method\}', "$($Hive.ToLower())-run" `
            -replace '\{error\}', "path=$regPath\$Tagged reason=$($_.Exception.Message)")
        Write-Log $err -Level "fail"
        return $false
    }
}

function Remove-FromTaskScheduler {
    param([string]$Tagged)
    $taskName = "$($startupCfg.task.folder)\$Tagged"
    try {
        $proc = Start-Process -FilePath "schtasks.exe" -ArgumentList @('/Delete','/F','/TN', $taskName) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardError "$env:TEMP\schtasks-rm-err.txt" -RedirectStandardOutput "$env:TEMP\schtasks-rm-out.txt"
        $code = $proc.ExitCode
        if ($code -eq 0) {
            Write-Log (($logMessages.startup.removeOk -replace '\{name\}', $Tagged -replace '\{method\}', "task")) -Level "ok"
            return $true
        } else {
            return $false
        }
    } catch { return $false }
}

# ---------- dispatch ----------
$removed = $false
if ([string]::IsNullOrWhiteSpace($Method)) {
    # search-all
    $r1 = Remove-FromStartupFolder -Tagged $tagged
    $r2 = Remove-FromRegistryRun  -Tagged $tagged -Hive 'HKCU'
    $r3 = $false
    if (Test-IsAdministrator) { $r3 = Remove-FromRegistryRun -Tagged $tagged -Hive 'HKLM' }
    $r4 = Remove-FromTaskScheduler -Tagged $tagged
    $removed = ($r1 -or $r2 -or $r3 -or $r4)
} else {
    if (-not (Test-AppMethod $Method)) {
        Write-Log "Unknown --method '$Method'. Valid: $($script:STARTUP_APP_METHODS -join ', ')" -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
    switch ($Method) {
        'startup-folder' { $removed = Remove-FromStartupFolder -Tagged $tagged }
        'hkcu-run'       { $removed = Remove-FromRegistryRun  -Tagged $tagged -Hive 'HKCU' }
        'hklm-run'       { $removed = Remove-FromRegistryRun  -Tagged $tagged -Hive 'HKLM' }
        'task'           { $removed = Remove-FromTaskScheduler -Tagged $tagged }
    }
}

if (-not $removed) {
    $msg = ($logMessages.startup.removeNotFound -replace '\{name\}', $Name)
    Write-Log $msg -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}
Save-LogFile -Status "ok"; exit 0
