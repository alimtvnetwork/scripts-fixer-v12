# --------------------------------------------------------------------------
#  scripts/shared/admin-check.ps1
#
#  Reusable Windows admin-elevation helpers. Designed to be dot-sourced by
#  scripts that write to HKCR / HKLM and therefore must be run elevated.
#
#  Public API:
#    Test-IsElevated
#        Returns [bool]. True when the current process is in the local
#        Administrators role. Cross-platform safe: returns $true on
#        non-Windows hosts so dev shells on macOS/Linux do not block.
#
#    Assert-Elevated -ScriptPath <string> [-ScriptArgs <string>]
#                    [-Reason <string>] [-ExitCode <int>]
#        Fail-fast gate. If not elevated, prints a CODE RED style banner
#        with the exact path that failed elevation, the reason, and a
#        copy-paste retry command, then exits with -ExitCode (default 87
#        -- ERROR_INVALID_PARAMETER analogue for "wrong privilege").
#
#  Convention: keep behaviour fail-fast and non-interactive. Auto-elevation
#  (UAC re-launch) is intentionally NOT performed here -- callers that want
#  it should opt in explicitly with their own --elevate flag.
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

function Test-IsElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Non-Windows hosts: treat as elevated so cross-platform dev shells
    # (macOS / Linux) don't trip the gate when sourcing these scripts.
    $isWindowsHost = $true
    if ($PSVersionTable.PSObject.Properties.Name -contains 'Platform') {
        $isWindowsHost = ($PSVersionTable.Platform -eq 'Win32NT' -or $null -eq $PSVersionTable.Platform)
    }
    if (-not $isWindowsHost) { return $true }

    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        # If we can't even ask, assume not elevated -- fail safe.
        return $false
    }
}

function Assert-Elevated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string]$ScriptArgs = '',

        [string]$Reason = 'This script writes to HKEY_CLASSES_ROOT and requires Administrator privileges.',

        [int]$ExitCode = 87
    )

    if (Test-IsElevated) { return }

    # CODE RED: every file/path error MUST log exact path + reason.
    # Prefer the project's Write-FileError helper if it has been dot-sourced
    # (logging.ps1), otherwise fall back to a plain colored banner so this
    # helper has no hard dependency on logging.ps1.
    $hasWriteFileError = $null -ne (Get-Command -Name 'Write-FileError' -ErrorAction SilentlyContinue)
    if ($hasWriteFileError) {
        Write-FileError -Path $ScriptPath -Reason $Reason
    } else {
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Red
        Write-Host '  ELEVATION REQUIRED' -ForegroundColor Red
        Write-Host '============================================================' -ForegroundColor Red
        Write-Host ("  Script : {0}" -f $ScriptPath) -ForegroundColor Yellow
        Write-Host ("  Reason : {0}" -f $Reason)     -ForegroundColor Yellow
        Write-Host '============================================================' -ForegroundColor Red
    }

    # Build a copy-paste retry command for both Windows PowerShell 5.1 and
    # PowerShell 7+. Quote the script path so spaces are handled.
    $quotedPath = '"' + $ScriptPath + '"'
    $argsTail   = ''
    if (-not [string]::IsNullOrWhiteSpace($ScriptArgs)) {
        $argsTail = ' ' + $ScriptArgs.Trim()
    }
    $innerCmd = "& $quotedPath$argsTail"

    Write-Host ''
    Write-Host '  To retry elevated, run ONE of these from an Administrator shell:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    # Windows PowerShell 5.1' -ForegroundColor DarkGray
    Write-Host ("    powershell -NoProfile -ExecutionPolicy Bypass -Command `"{0}`"" -f $innerCmd) -ForegroundColor White
    Write-Host ''
    Write-Host '    # PowerShell 7+' -ForegroundColor DarkGray
    Write-Host ("    pwsh -NoProfile -ExecutionPolicy Bypass -Command `"{0}`"" -f $innerCmd) -ForegroundColor White
    Write-Host ''
    Write-Host '  Or, from any shell, launch an elevated prompt with:' -ForegroundColor Cyan
    Write-Host ("    Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',`"{0}`"" -f $innerCmd) -ForegroundColor White
    Write-Host ''

    exit $ExitCode
}
