<#
.SYNOPSIS
    os edit-user -- Modify a local Windows user.

.DESCRIPTION
    Usage:
      .\run.ps1 os edit-user <name> [flags]
      .\run.ps1 os edit-user --ask

    Flags:
      --rename <newName>            Rename the local account
      --reset-password <newPass>    Reset the password (plain CLI -- accepted risk)
      --promote                     Add to local 'Administrators'
      --demote                      Remove from 'Administrators' (keeps 'Users')
      --add-group <name>            Add to a local group (repeatable via comma list)
      --remove-group <name>         Remove from a local group (repeatable via comma list)
      --enable | --disable          Enable / disable the account
      --comment <text>              Set the account comment (we use this for email)
      --ask                         Prompt interactively
      --dry-run                     Print actions, change nothing
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv = @())

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

$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages
Initialize-Logging -ScriptName "Edit User"

# ---- Parse ----
$Name = $null; $newName = $null; $newPass = $null; $comment = $null
$promote = $false; $demote = $false
$enable = $false; $disable = $false
$addGroups = @(); $removeGroups = @()
$hasAsk = $false; $hasDryRun = $false
$positional = @()

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--rename$'         { $i++; if ($i -lt $Argv.Count) { $newName = $Argv[$i] } }
        '^--reset-password$' { $i++; if ($i -lt $Argv.Count) { $newPass = $Argv[$i] } }
        '^--promote$'        { $promote = $true }
        '^--demote$'         { $demote = $true }
        '^--enable$'         { $enable = $true }
        '^--disable$'        { $disable = $true }
        '^--comment$'        { $i++; if ($i -lt $Argv.Count) { $comment = $Argv[$i] } }
        '^--add-group$'      { $i++; if ($i -lt $Argv.Count) { $addGroups += ($Argv[$i] -split ',') } }
        '^--remove-group$'   { $i++; if ($i -lt $Argv.Count) { $removeGroups += ($Argv[$i] -split ',') } }
        '^--ask$'            { $hasAsk = $true }
        '^--dry-run$'        { $hasDryRun = $true }
        '^--' {
            Write-Log "Unknown flag: '$a'" -Level "fail"
            Save-LogFile -Status "fail"; exit 64
        }
        default { $positional += $a }
    }
    $i++
}
if ($positional.Count -ge 1) { $Name = $positional[0] }

if ($hasAsk -and (Get-Command Read-PromptString -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-PromptString -Prompt "Username to edit" -Required }
    $newName = Read-PromptString -Prompt "Rename to (blank = keep)"
    $resetAns = Confirm-Prompt -Prompt "Reset password?"
    if ($resetAns) { $newPass = Read-PromptSecret -Prompt "New password" -Required }
    $roleAns = Read-PromptString -Prompt "Role change [promote/demote/none]"
    if ($roleAns -match '^(?i)promote') { $promote = $true }
    if ($roleAns -match '^(?i)demote')  { $demote  = $true }
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Log "Missing <name>. Usage: .\run.ps1 os edit-user <name> [flags]" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}
if ($promote -and $demote) {
    Write-Log "Both --promote and --demote given; aborting." -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}
if ($enable -and $disable) {
    Write-Log "Both --enable and --disable given; aborting." -Level "fail"
    Save-LogFile -Status "fail"; exit 64
}

# ---- Plan summary ----
$planLines = @()
if ($newName)              { $planLines += "rename '$Name' -> '$newName'" }
if ($newPass)              { $planLines += "reset password (masked: $('*' * [Math]::Min($newPass.Length,8)))" }
if ($promote)              { $planLines += "add to Administrators" }
if ($demote)               { $planLines += "remove from Administrators" }
if ($enable)               { $planLines += "enable account" }
if ($disable)              { $planLines += "disable account" }
if ($addGroups.Count)      { $planLines += "add groups: $($addGroups -join ', ')" }
if ($removeGroups.Count)   { $planLines += "remove groups: $($removeGroups -join ', ')" }
if ($null -ne $comment)    { $planLines += "set comment: '$comment'" }
if (-not $planLines.Count) {
    Write-Log "No changes requested. Use --help for flags." -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}

if ($hasDryRun) {
    Write-Host ""
    Write-Host "  DRY-RUN -- would edit '$Name':" -ForegroundColor Cyan
    foreach ($p in $planLines) { Write-Host "    - $p" }
    Write-Host ""
    Save-LogFile -Status "ok"; exit 0
}

$forwardArgs = @($Name) + ($Argv | Where-Object { $_ -ne "--ask" })
$isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }

# ---- Verify user exists ----
$user = $null
try { $user = Get-LocalUser -Name $Name -ErrorAction Stop } catch {
    Write-Log "User '$Name' not found. Failure: $($_.Exception.Message). Path: HKLM:\SAM (local users)" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

# ---- Apply (delegates to shared Invoke-UserModify in _common.ps1) ----
# Order matters: rename is LAST so all prior ops still reference the
# original $Name. This mirrors edit-user-from-json.sh on the Unix side.
$failed = 0
if ($newPass)            { if (-not (Invoke-UserModify -Name $Name -Op 'password' -Value $newPass)) { $failed++ } }
if ($enable)             { if (-not (Invoke-UserModify -Name $Name -Op 'enable'))                   { $failed++ } }
if ($disable)            { if (-not (Invoke-UserModify -Name $Name -Op 'disable'))                  { $failed++ } }
if ($null -ne $comment)  { if (-not (Invoke-UserModify -Name $Name -Op 'comment'  -Value $comment)) { $failed++ } }

if ($promote) { $addGroups += "Administrators" }
if ($demote)  { $removeGroups += "Administrators" }

foreach ($g in ($addGroups | Where-Object { $_ })) {
    if (-not (Invoke-UserModify -Name $Name -Op 'add-group' -Value $g)) { $failed++ }
}
foreach ($g in ($removeGroups | Where-Object { $_ })) {
    if (-not (Invoke-UserModify -Name $Name -Op 'rm-group' -Value $g)) { $failed++ }
}

if ($newName) {
    if (-not (Invoke-UserModify -Name $Name -Op 'rename' -Value $newName)) { $failed++ }
}

if ($failed -gt 0) { Save-LogFile -Status "fail"; exit 1 }
Save-LogFile -Status "ok"
exit 0
