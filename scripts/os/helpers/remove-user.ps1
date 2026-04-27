<#
.SYNOPSIS
    os remove-user -- Delete a local Windows user.

.DESCRIPTION
    Usage:
      .\run.ps1 os remove-user <name> [flags]
      .\run.ps1 os remove-user --ask

    Flags:
      --purge-profile   Also delete C:\Users\<name> (DESTRUCTIVE)
      --yes             Skip the confirmation prompt
      --ask             Prompt interactively
      --dry-run         Print what would be removed
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
Initialize-Logging -ScriptName "Remove User"

$Name = $null; $purge = $false; $autoYes = $false
$hasAsk = $false; $hasDryRun = $false
$positional = @()
$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    switch -Regex ($a) {
        '^--purge-profile$' { $purge = $true }
        '^--yes$|^-y$'      { $autoYes = $true }
        '^--ask$'           { $hasAsk = $true }
        '^--dry-run$'       { $hasDryRun = $true }
        '^--' {
            Write-Log "Unknown flag: '$a'" -Level "fail"; Save-LogFile -Status "fail"; exit 64
        }
        default { $positional += $a }
    }
    $i++
}
if ($positional.Count -ge 1) { $Name = $positional[0] }

if ($hasAsk -and (Get-Command Read-PromptString -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-PromptString -Prompt "Username to remove" -Required }
    $purge = Confirm-Prompt -Prompt "Also delete C:\Users\$Name profile folder?"
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Log "Missing <name>. Usage: .\run.ps1 os remove-user <name> [flags]" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

if ($hasDryRun) {
    Write-Host ""
    Write-Host "  DRY-RUN -- would remove:" -ForegroundColor Cyan
    Write-Host "    User    : $Name"
    if ($purge) { Write-Host "    Profile : C:\Users\$Name  (DESTRUCTIVE)" -ForegroundColor Yellow }
    Write-Host ""
    Save-LogFile -Status "ok"; exit 0
}

if (-not $autoYes) {
    $confirm = Confirm-Action -Prompt "Delete local user '$Name'? [y/N]: "
    if (-not $confirm) {
        Write-Log "Cancelled by user." -Level "warn"
        Save-LogFile -Status "ok"; exit 0
    }
}

$forwardArgs = @($Name) + ($Argv | Where-Object { $_ -ne "--ask" })
if (-not ($forwardArgs -contains "--yes")) { $forwardArgs += "--yes" }
$isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }

$user = $null
try { $user = Get-LocalUser -Name $Name -ErrorAction Stop } catch {
    Write-Log "User '$Name' not found. Failure: $($_.Exception.Message). Path: HKLM:\SAM (local users)" -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}
$sid = $user.SID.Value

try {
    Remove-LocalUser -Name $Name -ErrorAction Stop
    Write-Log "Removed local user '$Name' (SID $sid)." -Level "success"
} catch {
    Write-Log "Failed to remove '$Name': $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"; exit 1
}

if ($purge) {
    $profilePath = "C:\Users\$Name"
    try {
        $regKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path $regKey) {
            $pp = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).ProfileImagePath
            if ($pp) { $profilePath = $pp }
            Remove-Item -Path $regKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    if (Test-Path $profilePath) {
        try {
            Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop
            Write-Log "Deleted profile folder '$profilePath'." -Level "success"
        } catch {
            Write-Log "Failed to delete profile folder. Path: $profilePath. Reason: $($_.Exception.Message)" -Level "fail"
            Save-LogFile -Status "fail"; exit 1
        }
    } else {
        Write-Log "Profile folder not present at '$profilePath' -- nothing to purge." -Level "info"
    }
}

Save-LogFile -Status "ok"
exit 0
