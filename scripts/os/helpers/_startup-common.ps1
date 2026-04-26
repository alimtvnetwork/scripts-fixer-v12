<#
.SYNOPSIS
    Shared helpers for the cross-OS startup-add feature (Windows side).

.DESCRIPTION
    Imported by startup-add.ps1, startup-list.ps1, startup-remove.ps1.
    Provides:
      - Method enums + validation (app methods, env methods)
      - Name derivation (basename without extension, sanitized)
      - Tag prefix helpers so list/remove can safely filter "ours"
      - Path/registry resolvers from config.json
      - Interactive method picker (TTY)
      - WM_SETTINGCHANGE broadcaster (env var refresh without logoff)
      - Admin requirement check per method
#>

# ---------- enums (sourced from config but defaulted defensively) ----------
$script:STARTUP_APP_METHODS = @('startup-folder', 'hkcu-run', 'hklm-run', 'task')
$script:STARTUP_ENV_METHODS = @('registry', 'setx')
$script:STARTUP_TAG_PREFIX  = 'lovable-startup'

function Get-StartupConfig {
    param([Parameter(Mandatory)][string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Config file not found: $ConfigPath" -Level "fail"
        throw "missing config: $ConfigPath"
    }
    $cfg = Import-JsonConfig $ConfigPath
    $hasStartup = $null -ne $cfg.startup
    if (-not $hasStartup) {
        Write-Log "Config '$ConfigPath' has no 'startup' block" -Level "fail"
        throw "config missing startup block"
    }
    return $cfg.startup
}

# ---------- method validation ----------
function Test-AppMethod {
    param([string]$Method)
    return $script:STARTUP_APP_METHODS -contains $Method
}

function Test-EnvMethod {
    param([string]$Method)
    return $script:STARTUP_ENV_METHODS -contains $Method
}

function Get-AppMethodDescription {
    param([string]$Method)
    switch ($Method) {
        'startup-folder' { return 'Shortcut in user Startup folder (no admin, easiest to undo)' }
        'hkcu-run'       { return 'HKCU Run registry key (no admin, current user only)' }
        'hklm-run'       { return 'HKLM Run registry key (REQUIRES ADMIN, all users)' }
        'task'           { return 'Task Scheduler ONLOGON trigger (supports delay + elevation)' }
        default          { return '(unknown method)' }
    }
}

function Test-MethodNeedsAdmin {
    param([string]$Method)
    return ($Method -eq 'hklm-run' -or $Method -eq 'task')
}

# ---------- naming ----------
function Get-DerivedName {
    param([Parameter(Mandatory)][string]$Path)
    $isMissing = [string]::IsNullOrWhiteSpace($Path)
    if ($isMissing) { return "entry" }
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = "entry" }
    # sanitize for filenames + registry value names
    $clean = ($leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = "entry" }
    return $clean.ToLower()
}

function Get-TaggedName {
    param([Parameter(Mandatory)][string]$Name)
    $hasPrefix = $Name.StartsWith("$script:STARTUP_TAG_PREFIX-")
    if ($hasPrefix) { return $Name }
    return "$script:STARTUP_TAG_PREFIX-$Name"
}

function Test-IsTaggedName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name.StartsWith("$script:STARTUP_TAG_PREFIX-")
}

function Get-UntaggedName {
    param([string]$Name)
    if (-not (Test-IsTaggedName $Name)) { return $Name }
    return $Name.Substring("$script:STARTUP_TAG_PREFIX-".Length)
}

# ---------- path resolvers ----------
function Resolve-StartupPath {
    param(
        [Parameter(Mandatory)]$StartupCfg,
        [ValidateSet('user', 'common')][string]$Scope = 'user'
    )
    $rawPath = ""
    if ($Scope -eq 'user') {
        $rawPath = $StartupCfg.paths.startupFolderUser
    } else {
        $rawPath = $StartupCfg.paths.startupFolderCommon
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($rawPath)
    return $expanded
}

# ---------- interactive picker ----------
function Select-StartupMethod {
    param(
        [Parameter(Mandatory)][ValidateSet('app', 'env')][string]$Kind,
        [PSObject]$LogMessages
    )
    $methods = if ($Kind -eq 'app') { $script:STARTUP_APP_METHODS } else { $script:STARTUP_ENV_METHODS }
    Write-Host ""
    Write-Host "  Pick startup method:" -ForegroundColor Cyan
    $i = 0
    foreach ($m in $methods) {
        $i++
        $desc = if ($Kind -eq 'app') { Get-AppMethodDescription $m } else { "env-var via $m" }
        $needsAdmin = Test-MethodNeedsAdmin $m
        $adminTag = ""
        if ($needsAdmin) { $adminTag = " [ADMIN]" }
        Write-Host ("    [{0}] {1}{2}  --  {3}" -f $i, $m, $adminTag, $desc) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host ("  Choose [1-{0}] or 'q' to quit: " -f $methods.Count) -ForegroundColor Cyan -NoNewline
    $reply = Read-Host
    $isQuit = ($reply -match '^(q|quit|exit)$')
    if ($isQuit) { return $null }
    $isNum = [int]::TryParse($reply, [ref]$null)
    if (-not $isNum) { return $null }
    $idx = [int]$reply
    $isInRange = ($idx -ge 1 -and $idx -le $methods.Count)
    if (-not $isInRange) { return $null }
    return $methods[$idx - 1]
}

# ---------- WM_SETTINGCHANGE broadcaster ----------
function Send-EnvironmentSettingChange {
    <#
    Broadcasts WM_SETTINGCHANGE so already-running Explorer / shells refresh
    their environment block without requiring logoff.
    #>
    param([PSObject]$LogMessages)
    try {
        $sig = @"
using System;
using System.Runtime.InteropServices;
public static class StartupNative {
    public const int HWND_BROADCAST = 0xffff;
    public const int WM_SETTINGCHANGE = 0x1A;
    public const int SMTO_ABORTIFHUNG = 0x2;
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, int Msg, IntPtr wParam, string lParam,
        int fuFlags, int uTimeout, out IntPtr lpdwResult);
}
"@
        $hasType = ([System.Management.Automation.PSTypeName]'StartupNative').Type
        if (-not $hasType) {
            Add-Type -TypeDefinition $sig -ErrorAction Stop | Out-Null
        }
        $result = [IntPtr]::Zero
        [void][StartupNative]::SendMessageTimeout(
            [IntPtr][StartupNative]::HWND_BROADCAST,
            [StartupNative]::WM_SETTINGCHANGE,
            [IntPtr]::Zero,
            "Environment",
            [StartupNative]::SMTO_ABORTIFHUNG,
            5000,
            [ref]$result
        )
        return $true
    } catch {
        $msg = "WM_SETTINGCHANGE broadcast failed: $($_.Exception.Message)"
        Write-Log $msg -Level "warn"
        return $false
    }
}

# ---------- value masking (for env logging) ----------
function Get-MaskedValue {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    $len = $Value.Length
    if ($len -le 4) { return ('*' * $len) }
    $head = $Value.Substring(0, 2)
    $tail = $Value.Substring($len - 2, 2)
    return "$head$('*' * ($len - 4))$tail"
}

# ---------- KEY=VALUE parser ----------
function Split-EnvPair {
    param([Parameter(Mandatory)][string]$Pair)
    $eq = $Pair.IndexOf('=')
    $hasEquals = ($eq -gt 0)
    if (-not $hasEquals) {
        return @{ ok = $false; key = $null; value = $null }
    }
    $k = $Pair.Substring(0, $eq).Trim()
    $v = $Pair.Substring($eq + 1)
    $isKeyValid = ($k -match '^[A-Za-z_][A-Za-z0-9_]*$')
    if (-not $isKeyValid) {
        return @{ ok = $false; key = $k; value = $v }
    }
    return @{ ok = $true; key = $k; value = $v }
}
