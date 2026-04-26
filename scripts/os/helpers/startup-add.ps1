<#
.SYNOPSIS
    os startup-add <app|env> ...
    Cross-OS startup-add (Windows side). Adds an application or env-var to
    user/machine startup using one of 4 methods (app) or 2 methods (env).

.EXAMPLES
    .\run.ps1 os startup-add app "C:\Tools\sync.exe"
    .\run.ps1 os startup-add app "C:\Tools\sync.exe" --method hkcu-run --name sync
    .\run.ps1 os startup-add app "C:\Tools\sync.exe" --interactive
    .\run.ps1 os startup-add app "C:\Tools\sync.exe" --method task --elevated --args "--quiet"
    .\run.ps1 os startup-add env "FOO=bar"
    .\run.ps1 os startup-add env "FOO=bar" --scope machine
#>
param(
    [Parameter(Position = 0)]
    [string]$Kind,                 # app | env

    [Parameter(Position = 1)]
    [string]$Target,               # path (for app) or KEY=VALUE (for env)

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

Initialize-Logging -ScriptName "startup-add"

# ---------- arg parsing ----------
$Method        = ""
$Name          = ""
$AppArgs       = ""
$Scope         = ""        # env: user|machine
$IsInteractive = $false
$IsForce       = $false
$IsElevated    = $false

$i = 0
while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    switch -regex ($a) {
        '^--method$'       { $Method  = $Rest[$i+1]; $i += 2; continue }
        '^--name$'         { $Name    = $Rest[$i+1]; $i += 2; continue }
        '^--args$'         { $AppArgs = $Rest[$i+1]; $i += 2; continue }
        '^--scope$'        { $Scope   = $Rest[$i+1]; $i += 2; continue }
        '^--interactive$'  { $IsInteractive = $true; $i += 1; continue }
        '^-i$'             { $IsInteractive = $true; $i += 1; continue }
        '^--force-replace$'{ $IsForce = $true; $i += 1; continue }
        '^--elevated$'     { $IsElevated = $true; $i += 1; continue }
        default            { Write-Log "Unknown arg: $a" -Level "warn"; $i += 1 }
    }
}

# ---------- validate kind ----------
$isKindMissing = [string]::IsNullOrWhiteSpace($Kind)
if ($isKindMissing) {
    Write-Log $logMessages.startup.missingSubcommand -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}
$Kind = $Kind.ToLower()
$isKnownKind = ($Kind -eq 'app' -or $Kind -eq 'env')
if (-not $isKnownKind) {
    Write-Log "Unknown kind '$Kind'. Use 'app' or 'env'." -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---------- env path is implemented in step 5 (stub here) ----------
if ($Kind -eq 'env') {
    Write-Log "env subcommand will be implemented in Step 5." -Level "info"
    Save-LogFile -Status "ok"; exit 0
}

# ===== APP path =====
$isAppPathMissing = [string]::IsNullOrWhiteSpace($Target)
if ($isAppPathMissing) {
    Write-Log $logMessages.startup.missingAppPath -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

$resolved = $null
try { $resolved = (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path } catch { $resolved = $null }
$isFound = ($null -ne $resolved -and (Test-Path $resolved))
if (-not $isFound) {
    $msg = ($logMessages.startup.appNotFound -replace '\{path\}', $Target)
    Write-Log $msg -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# derive name
$isNameMissing = [string]::IsNullOrWhiteSpace($Name)
if ($isNameMissing) { $Name = Get-DerivedName -Path $resolved }

# ---------- pick method ----------
if ($IsInteractive) {
    $pick = Select-StartupMethod -Kind 'app' -LogMessages $logMessages
    if ($null -eq $pick) { Write-Log $logMessages.messages.userCancelled -Level "warn"; Save-LogFile -Status "ok"; exit 0 }
    $Method = $pick
}
$isMethodMissing = [string]::IsNullOrWhiteSpace($Method) -or ($Method -eq 'auto')
if ($isMethodMissing) { $Method = $startupCfg.defaultAppMethod }

if (-not (Test-AppMethod $Method)) {
    $msg = ($logMessages.startup.methodInvalid `
        -replace '\{method\}', $Method `
        -replace '\{valid\}',  ($script:STARTUP_APP_METHODS -join ', '))
    Write-Log $msg -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# admin guard
$needsAdmin = Test-MethodNeedsAdmin $Method
if ($needsAdmin -and -not (Test-IsAdministrator)) {
    $msg = ($logMessages.startup.adminRequiredForMethod -replace '\{method\}', $Method)
    Write-Log $msg -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

$msg = ($logMessages.startup.methodChosen -replace '\{method\}', $Method -replace '\{name\}', $Name)
Write-Log $msg -Level "info"

$tagged = Get-TaggedName -Name $Name

# ---------- method implementations ----------
function Add-ViaStartupFolder {
    param([string]$AppPath, [string]$AppArgs, [string]$Tagged, [string]$Scope = 'user')
    $folder = Resolve-StartupPath -StartupCfg $startupCfg -Scope $Scope
    if (-not (Test-Path $folder)) {
        try { New-Item -Path $folder -ItemType Directory -Force | Out-Null } catch {
            Write-Log "Failed to create startup folder '$folder': $($_.Exception.Message)" -Level "fail"
            return $false
        }
    }
    $lnkPath = Join-Path $folder "$Tagged.lnk"
    $exists = Test-Path $lnkPath
    if ($exists -and -not $IsForce) {
        $m = ($logMessages.startup.alreadyExistsSameMethod `
            -replace '\{name\}', $Tagged -replace '\{method\}', 'startup-folder')
        Write-Log $m -Level "info"
    }
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = $AppPath
        $sc.Arguments  = $AppArgs
        $sc.WorkingDirectory = (Split-Path -Parent $AppPath)
        $sc.Description = "Managed by lovable-startup"
        $sc.Save()
        $okMsg = ($logMessages.startup.shortcutCreated -replace '\{path\}', $lnkPath)
        Write-Log $okMsg -Level "ok"
        $msg = ($logMessages.startup.addOk `
            -replace '\{name\}', $Tagged `
            -replace '\{method\}', 'startup-folder' `
            -replace '\{target\}', $lnkPath)
        Write-Log $msg -Level "ok"
        return $true
    } catch {
        $err = ($logMessages.startup.shortcutFailed `
            -replace '\{path\}', $lnkPath `
            -replace '\{error\}', $_.Exception.Message)
        Write-Log $err -Level "fail"
        return $false
    }
}

function Add-ViaRegistryRun {
    param([string]$AppPath, [string]$AppArgs, [string]$Tagged, [string]$Hive)  # Hive = HKCU | HKLM
    $regPath = if ($Hive -eq 'HKLM') { $startupCfg.registry.runMachine } else { $startupCfg.registry.runUser }
    $valueData = if ([string]::IsNullOrWhiteSpace($AppArgs)) { "`"$AppPath`"" } else { "`"$AppPath`" $AppArgs" }
    try {
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        $existing = Get-ItemProperty -Path $regPath -Name $Tagged -ErrorAction SilentlyContinue
        $hasExisting = $null -ne $existing
        if ($hasExisting -and -not $IsForce) {
            $m = ($logMessages.startup.alreadyExistsSameMethod `
                -replace '\{name\}', $Tagged -replace '\{method\}', "$Hive Run")
            Write-Log $m -Level "info"
        }
        Set-ItemProperty -Path $regPath -Name $Tagged -Value $valueData -Type String -Force
        $okMsg = ($logMessages.startup.registryWritten `
            -replace '\{hive\}', $Hive `
            -replace '\{value\}', $Tagged `
            -replace '\{data\}', $valueData)
        Write-Log $okMsg -Level "ok"
        $msg = ($logMessages.startup.addOk `
            -replace '\{name\}', $Tagged `
            -replace '\{method\}', "$($Hive.ToLower())-run" `
            -replace '\{target\}', "$regPath\$Tagged")
        Write-Log $msg -Level "ok"
        return $true
    } catch {
        $err = ($logMessages.startup.registryWriteFailed `
            -replace '\{hive\}', $Hive `
            -replace '\{value\}', $Tagged `
            -replace '\{error\}', $_.Exception.Message)
        Write-Log $err -Level "fail"
        return $false
    }
}

function Add-ViaTaskScheduler {
    param([string]$AppPath, [string]$AppArgs, [string]$Tagged, [bool]$IsElevated)
    $folder = $startupCfg.task.folder
    $taskName = "$folder\$Tagged"
    $runLevel = if ($IsElevated) { $startupCfg.task.elevatedRunLevel } else { $startupCfg.task.runLevel }
    $tr = if ([string]::IsNullOrWhiteSpace($AppArgs)) { "`"$AppPath`"" } else { "`"$AppPath`" $AppArgs" }
    $args = @("/Create","/F","/TN", $taskName, "/SC", $startupCfg.task.scheduleType, "/RL", $runLevel, "/TR", $tr)
    try {
        $proc = Start-Process -FilePath "schtasks.exe" -ArgumentList $args -NoNewWindow -Wait -PassThru `
            -RedirectStandardError "$env:TEMP\schtasks-err.txt" -RedirectStandardOutput "$env:TEMP\schtasks-out.txt"
        $code = $proc.ExitCode
        $isOk = ($code -eq 0)
        if (-not $isOk) {
            $stderr = ""
            try { $stderr = Get-Content "$env:TEMP\schtasks-err.txt" -Raw -ErrorAction SilentlyContinue } catch {}
            $err = ($logMessages.startup.taskCreateFailed `
                -replace '\{taskName\}', $taskName `
                -replace '\{code\}', "$code" `
                -replace '\{stderr\}', ($stderr -replace '[\r\n]+', ' '))
            Write-Log $err -Level "fail"
            return $false
        }
        $okMsg = ($logMessages.startup.taskCreated `
            -replace '\{taskName\}', $taskName `
            -replace '\{runLevel\}', $runLevel)
        Write-Log $okMsg -Level "ok"
        $msg = ($logMessages.startup.addOk `
            -replace '\{name\}', $Tagged `
            -replace '\{method\}', 'task' `
            -replace '\{target\}', $taskName)
        Write-Log $msg -Level "ok"
        return $true
    } catch {
        $err = ($logMessages.startup.addFailed `
            -replace '\{name\}', $Tagged `
            -replace '\{method\}', 'task' `
            -replace '\{error\}', $_.Exception.Message)
        Write-Log $err -Level "fail"
        return $false
    }
}

# ---------- dispatch ----------
$ok = $false
switch ($Method) {
    'startup-folder' { $ok = Add-ViaStartupFolder -AppPath $resolved -AppArgs $AppArgs -Tagged $tagged -Scope 'user' }
    'hkcu-run'       { $ok = Add-ViaRegistryRun  -AppPath $resolved -AppArgs $AppArgs -Tagged $tagged -Hive 'HKCU' }
    'hklm-run'       { $ok = Add-ViaRegistryRun  -AppPath $resolved -AppArgs $AppArgs -Tagged $tagged -Hive 'HKLM' }
    'task'           { $ok = Add-ViaTaskScheduler -AppPath $resolved -AppArgs $AppArgs -Tagged $tagged -IsElevated:$IsElevated }
}

if ($ok) {
    Save-LogFile -Status "ok"; exit 0
} else {
    Save-LogFile -Status "fail"; exit 1
}
