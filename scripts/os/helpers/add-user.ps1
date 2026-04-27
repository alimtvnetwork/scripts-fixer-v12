<#
.SYNOPSIS
    os add-user -- Create a local Windows user (admin or standard), with
    optional Microsoft/Outlook account hint and optional --ask prompt.

.DESCRIPTION
    Usage:
      .\run.ps1 os add-user <name> <pass> [pin] [email] [flags]
      .\run.ps1 os add-user --ask

    Flags (all optional):
      --admin                       Add to local 'Administrators' group
      --standard                    Add to local 'Users' group (default)
      --microsoft-account <email>   Note an Outlook/Live email; cannot be linked
                                    non-interactively on Windows -- a hint file
                                    is written and a [NOTICE] is logged.
      --ms-account-on-logon         (Opt-in) Schedule a one-shot RunOnce that
                                    opens 'ms-settings:emailandaccounts' for the
                                    user on first interactive logon.
      --ask                         Prompt interactively for missing fields.
      --dry-run                     Print actions, change nothing.

    Per locked decision: password is passed as a plain CLI arg
    (visible in shell history -- accepted risk). PIN cannot be set
    non-interactively on modern Windows; a hint file is written.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Argv = @()
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $helpersDir "_common.ps1")
$promptHelper = Join-Path $helpersDir "_prompt.ps1"
if (Test-Path $promptHelper) { . $promptHelper }

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages

Initialize-Logging -ScriptName "Add User"

# ---- Parse mixed positional + flag args ----
$Name = $null; $Pass = $null; $Pin = $null; $Email = $null
$isAdmin = $false; $isStandard = $false; $msAccount = $null
$hasAsk = $false; $hasDryRun = $false; $hasOnLogon = $false
$positional = @()

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--admin$'                  { $isAdmin = $true }
        '^--standard$'               { $isStandard = $true }
        '^--ask$'                    { $hasAsk = $true }
        '^--dry-run$'                { $hasDryRun = $true }
        '^--ms-account-on-logon$'    { $hasOnLogon = $true }
        '^--microsoft-account$'      { $i++; if ($i -lt $Argv.Count) { $msAccount = $Argv[$i] } }
        '^--microsoft-account=(.+)$' { $msAccount = $Matches[1] }
        '^--'                        {
            Write-Log ("Unknown flag: '$a'") -Level "fail"
            Save-LogFile -Status "fail"
            exit 64
        }
        default { $positional += $a }
    }
    $i++
}
if ($positional.Count -ge 1) { $Name  = $positional[0] }
if ($positional.Count -ge 2) { $Pass  = $positional[1] }
if ($positional.Count -ge 3) { $Pin   = $positional[2] }
if ($positional.Count -ge 4) { $Email = $positional[3] }

# ---- --ask: interactive prompt for missing required fields ----
if ($hasAsk) {
    if (Get-Command Read-PromptString -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($Name))  { $Name  = Read-PromptString -Prompt "Username" -Required }
        if ([string]::IsNullOrWhiteSpace($Pass))  { $Pass  = Read-PromptSecret -Prompt "Password" -Required }
        if ([string]::IsNullOrWhiteSpace($Email)) { $Email = Read-PromptString -Prompt "Email (optional, blank to skip)" }
        if (-not $isAdmin -and -not $isStandard) {
            $role = Read-PromptString -Prompt "Role [admin/standard] (default: standard)"
            if ($role -match '^(?i)admin') { $isAdmin = $true } else { $isStandard = $true }
        }
        if (-not [string]::IsNullOrWhiteSpace($Email) -and [string]::IsNullOrWhiteSpace($msAccount)) {
            $linkAns = Read-PromptString -Prompt "Treat email as Microsoft/Outlook account? [y/N]"
            if ($linkAns -match '^(?i)y') { $msAccount = $Email }
        }
    } else {
        Write-Log "--ask requested but _prompt.ps1 helper not found." -Level "fail"
        Save-LogFile -Status "fail"
        exit 1
    }
}

# Mutual-exclusion: admin wins if both passed
if ($isAdmin -and $isStandard) {
    Write-Log "Both --admin and --standard given; using --admin." -Level "warn"
    $isStandard = $false
}
$targetGroup = if ($isAdmin) { "Administrators" } else { $config.addUser.defaultGroup }

# ---- Validate ----
if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Log $logMessages.addUser.missingName -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}
if ([string]::IsNullOrWhiteSpace($Pass)) {
    Write-Log $logMessages.addUser.missingPass -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

# ---- Dry-run short-circuit ----
$passMasked = ('*' * [Math]::Min($Pass.Length, 8))
if ($hasDryRun) {
    Write-Host ""
    Write-Host "  DRY-RUN -- would create user:" -ForegroundColor Cyan
    Write-Host "    Name        : $Name"
    Write-Host "    Password    : $passMasked"
    Write-Host "    Group       : $targetGroup"
    if ($Pin)       { Write-Host "    PIN hint    : %TEMP%\$Name-pin-hint.txt" }
    if ($Email)     { Write-Host "    Email note  : $Email" }
    if ($msAccount) { Write-Host "    MS account  : $msAccount  (interactive link required)" }
    if ($hasOnLogon){ Write-Host "    RunOnce     : ms-settings:emailandaccounts on first logon" }
    Write-Host ""
    Save-LogFile -Status "ok"
    exit 0
}

# ---- Forward args for elevation re-launch ----
$forwardArgs = @($Name, $Pass)
if ($Pin)         { $forwardArgs += $Pin }
if ($Email)       { $forwardArgs += $Email }
if ($isAdmin)     { $forwardArgs += "--admin" }
if ($isStandard)  { $forwardArgs += "--standard" }
if ($msAccount)   { $forwardArgs += @("--microsoft-account", $msAccount) }
if ($hasOnLogon)  { $forwardArgs += "--ms-account-on-logon" }

$isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }

# 1. Create user (or skip if exists)
$existing = $null
try { $existing = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue } catch {}

if ($existing) {
    $msg = $logMessages.addUser.userExists -replace '\{name\}', $Name
    Write-Log $msg -Level "warn"
} else {
    try {
        $securePass = ConvertTo-SecureString $Pass -AsPlainText -Force
        $createParams = @{ Name = $Name; Password = $securePass; ErrorAction = 'Stop' }
        if ($config.addUser.passwordNeverExpires) { $createParams['PasswordNeverExpires'] = $true }
        if ($config.addUser.accountNeverExpires)  { $createParams['AccountNeverExpires']  = $true }
        New-LocalUser @createParams | Out-Null
        $msg = $logMessages.addUser.userCreated -replace '\{name\}', $Name
        Write-Log $msg -Level "success"
    } catch {
        $errMsg = $logMessages.addUser.userCreateFailed `
            -replace '\{name\}', $Name `
            -replace '\{error\}', $_.Exception.Message
        Write-Log $errMsg -Level "fail"
        Save-LogFile -Status "fail"; exit 1
    }
}

# 2. Add to target group (Administrators or Users)
try {
    $alreadyMember = $false
    try {
        $members = Get-LocalGroupMember -Group $targetGroup -ErrorAction SilentlyContinue
        foreach ($m in $members) {
            if ($m.Name -like "*\$Name" -or $m.Name -eq $Name) { $alreadyMember = $true; break }
        }
    } catch {}
    if (-not $alreadyMember) {
        Add-LocalGroupMember -Group $targetGroup -Member $Name -ErrorAction Stop
    }
    $msg = $logMessages.addUser.addedToGroup -replace '\{name\}', $Name -replace '\{group\}', $targetGroup
    Write-Log $msg -Level "success"
} catch {
    $errMsg = $logMessages.addUser.groupAddFailed `
        -replace '\{name\}', $Name `
        -replace '\{group\}', $targetGroup `
        -replace '\{error\}', $_.Exception.Message
    Write-Log $errMsg -Level "warn"
}

# 3. PIN hint
if (-not [string]::IsNullOrWhiteSpace($Pin)) {
    $pinMasked = ('*' * [Math]::Min($Pin.Length, 6))
    $hintFolder = [Environment]::ExpandEnvironmentVariables($config.addUser.pinHintFolder)
    if (-not (Test-Path $hintFolder)) { $hintFolder = $env:TEMP }
    $hintFile = Join-Path $hintFolder "$Name-pin-hint.txt"
    try {
        $hintBody = @(
            "PIN hint for Windows user '$Name'",
            "Provided PIN: $Pin",
            "",
            "Windows Hello PIN cannot be set non-interactively.",
            "Sign in as '$Name' and use:",
            "  Settings -> Accounts -> Sign-in options -> PIN (Windows Hello) -> Add",
            "",
            "DELETE THIS FILE after the PIN is set."
        ) -join "`r`n"
        Set-Content -Path $hintFile -Value $hintBody -Encoding UTF8 -ErrorAction Stop
        $msg = $logMessages.addUser.pinNotice `
            -replace '\{pinMasked\}', $pinMasked `
            -replace '\{hintFile\}', $hintFile `
            -replace '\{name\}', $Name
        Write-Log $msg -Level "info"
    } catch {
        $errMsg = $logMessages.addUser.pinHintWriteFailed `
            -replace '\{path\}', $hintFile `
            -replace '\{error\}', $_.Exception.Message
        Write-Log $errMsg -Level "fail"
    }
}

# 4. Email comment
if (-not [string]::IsNullOrWhiteSpace($Email)) {
    try { & net.exe user $Name /comment:"$Email" 2>&1 | Out-Null } catch {}
    $msg = $logMessages.addUser.emailNotice -replace '\{email\}', $Email -replace '\{name\}', $Name
    Write-Log $msg -Level "info"
}

# 5. Microsoft/Outlook account link hint
if (-not [string]::IsNullOrWhiteSpace($msAccount)) {
    $msg = $logMessages.addUser.msAccountNotice -replace '\{email\}', $msAccount -replace '\{name\}', $Name
    Write-Log $msg -Level "info"
    if ($hasOnLogon) {
        # Per-user RunOnce -- writes into the new user's NTUSER.DAT via reg load
        try {
            $sid = (Get-LocalUser -Name $Name).SID.Value
            $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
            $ntuser = Join-Path $profilePath "NTUSER.DAT"
            if (Test-Path $ntuser) {
                & reg.exe load "HKU\TempLink_$Name" "$ntuser" 2>&1 | Out-Null
                $runOnceKey = "HKU\TempLink_$Name\Software\Microsoft\Windows\CurrentVersion\RunOnce"
                & reg.exe add $runOnceKey /v "LovableLinkMS" /t REG_SZ /d "explorer.exe ms-settings:emailandaccounts" /f 2>&1 | Out-Null
                & reg.exe unload "HKU\TempLink_$Name" 2>&1 | Out-Null
                $msg = $logMessages.addUser.msAccountRunOnceSet -replace '\{name\}', $Name
                Write-Log $msg -Level "success"
            } else {
                $msg = $logMessages.addUser.msAccountRunOnceNoProfile `
                    -replace '\{path\}', $ntuser -replace '\{name\}', $Name
                Write-Log $msg -Level "warn"
            }
        } catch {
            $errMsg = $logMessages.addUser.msAccountRunOnceFailed `
                -replace '\{name\}', $Name -replace '\{error\}', $_.Exception.Message
            Write-Log $errMsg -Level "warn"
        }
    }
}

# 6. Console summary
Write-Host ""
Write-Host "  $($logMessages.addUser.summaryHeader)" -ForegroundColor Cyan
Write-Host "  ===============================" -ForegroundColor DarkGray
Write-Host "    User created : $Name"
Write-Host "    Password     : $passMasked  " -NoNewline
Write-Host "(passed via CLI -- visible in shell history!)" -ForegroundColor Yellow
Write-Host "    Role / group : $targetGroup"
if ($Pin)        { Write-Host "    PIN (manual) : <hint saved to %TEMP%\$Name-pin-hint.txt>" -ForegroundColor DarkYellow }
if ($Email)      { Write-Host "    Email note   : $Email" -ForegroundColor DarkYellow }
if ($msAccount)  { Write-Host "    MS account   : $msAccount  (interactive link required)" -ForegroundColor DarkYellow }
if ($hasOnLogon) { Write-Host "    RunOnce      : ms-settings:emailandaccounts queued for first logon" -ForegroundColor DarkYellow }
Write-Host ""

Save-LogFile -Status "ok"
exit 0
