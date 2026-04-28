# --------------------------------------------------------------------------
#  Ensure-Tool -- one-shot detect / install / upgrade / track helper
#
#  Used by orchestration profiles (e.g. "advanced") to make per-tool installs
#  idempotent across re-runs:
#
#    1. Detect the command in PATH (no prompts).
#    2. If found, read the version. If the version matches the existing
#       .installed/<name>.json record, skip everything.
#    3. If found and AlwaysUpgradeToLatest is on (or the tracked version is
#       different / stale), run the upgrade path (Chocolatey by default) and
#       refresh .installed/<name>.json with the new version.
#    4. If missing, run the install path and write a fresh record.
#
#  Every file/path failure is reported with the exact path + reason
#  (CODE RED rule).
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_etSharedDir = Split-Path -Parent $PSScriptRoot
$_etInstalled = Join-Path $_etSharedDir "shared\installed.ps1"
if (-not (Test-Path $_etInstalled)) {
    # When this file is sourced by something already inside scripts/shared/
    $_etInstalled = Join-Path $PSScriptRoot "installed.ps1"
}
if ((Test-Path $_etInstalled) -and -not (Get-Command Save-InstalledRecord -ErrorAction SilentlyContinue)) {
    . $_etInstalled
}

$_etChoco = Join-Path $PSScriptRoot "choco-utils.ps1"
if ((Test-Path $_etChoco) -and -not (Get-Command Install-ChocoPackage -ErrorAction SilentlyContinue)) {
    . $_etChoco
}

$_etToolVersion = Join-Path $PSScriptRoot "tool-version.ps1"
if ((Test-Path $_etToolVersion) -and -not (Get-Command Refresh-EnvPath -ErrorAction SilentlyContinue)) {
    . $_etToolVersion
}

# Per-tool version parsers (git, node, python, go, java, dotnet, rustc, ...).
# Loaded so Ensure-Tool can produce accurate stored versions without each
# caller hand-rolling a regex.
$_etParsers = Join-Path $PSScriptRoot "tool-version-parsers.ps1"
if ((Test-Path $_etParsers) -and -not (Get-Command Get-ToolVersionParser -ErrorAction SilentlyContinue)) {
    . $_etParsers
} elseif (-not (Test-Path $_etParsers)) {
    Write-Log "  [WARN] path: $_etParsers -- reason: parser registry missing, falling back to raw version output" -Level "warn"
}

# End-of-run summary collector. Auto-records every Ensure-Tool result so the
# caller can finish with a single Write-EnsureSummary at the end of the run.
$_etSummary = Join-Path $PSScriptRoot "ensure-summary.ps1"
if ((Test-Path $_etSummary) -and -not (Get-Command Add-EnsureSummary -ErrorAction SilentlyContinue)) {
    . $_etSummary
} elseif (-not (Test-Path $_etSummary)) {
    Write-Log "  [WARN] path: $_etSummary -- reason: summary collector missing, end-of-run table will be unavailable" -Level "warn"
}

function Write-EnsureFileError {
    # CODE RED: every file/path error must include exact path + reason.
    param([string]$Path, [string]$Reason)
    Write-Log "  [FAIL] path: $Path -- reason: $Reason" -Level "error"
}

function Get-EnsuredVersion {
    <#
    .SYNOPSIS
        Runs <Command> <VersionFlag>, optionally parses the output, and
        returns a trimmed string (or $null on failure).
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$VersionFlag = "--version",
        [scriptblock]$ParseScript = $null
    )

    $raw = $null
    try {
        $raw = & $Command $VersionFlag 2>$null
    } catch {
        return $null
    }

    $isRawEmpty = [string]::IsNullOrWhiteSpace("$raw")
    if ($isRawEmpty) { return $null }

    if ($null -ne $ParseScript) {
        try { $raw = & $ParseScript $raw } catch { }
    }

    return "$raw".Trim()
}

function Complete-EnsureToolResult {
    # Internal: feed every Ensure-Tool return value into the end-of-run summary
    # collector (when available) and pass the result back unchanged. Keeps the
    # main function readable -- one helper instead of seven Add-EnsureSummary
    # calls before each return.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$FriendlyName,
        $Result
    )
    if (Get-Command Add-EnsureSummary -ErrorAction SilentlyContinue) {
        try { Add-EnsureSummary -Name $Name -FriendlyName $FriendlyName -Result $Result } catch { }
    }
    return $Result
}

function Ensure-Tool {
    <#
    .SYNOPSIS
        Detect / install / upgrade / track a single CLI tool.

    .DESCRIPTION
        Pre-flight check used by profile installers (e.g. the "advanced"
        profile in script 12). Behavior:

        - If the command is already in PATH and its version matches the
          tracked record in .installed/<Name>.json, returns immediately.
        - If the command exists but the version is unknown or differs,
          performs an upgrade (when -AlwaysUpgradeToLatest is set) and
          re-writes the tracking record.
        - If the command is missing, installs it (Chocolatey by default)
          and writes a fresh tracking record.

        On any failure the helper records the error in
        .installed/<Name>.json via Save-InstalledError so the next run
        sees a friendly retry message.

    .PARAMETER Name
        Tracking name -> .installed/<Name>.json (e.g. "git").

    .PARAMETER Command
        Command to probe (e.g. "git").

    .PARAMETER ChocoPackage
        Chocolatey package id (e.g. "git"). Required for the default
        install/upgrade scriptblocks.

    .PARAMETER VersionFlag
        Default "--version".

    .PARAMETER ParseScript
        Optional scriptblock that receives raw version output and returns a
        cleaned version string.

    .PARAMETER AlwaysUpgradeToLatest
        Run the upgrade path when the tool already exists.

    .PARAMETER InstallScript
        Custom installer (no args). Defaults to Install-ChocoPackage.

    .PARAMETER UpgradeScript
        Custom upgrader (no args). Defaults to Upgrade-ChocoPackage.

    .PARAMETER FriendlyName
        Pretty name used in log lines (defaults to $Name).

    .OUTPUTS
        Hashtable with: Action ("skipped" | "installed" | "upgraded" | "failed"),
        Version, Existed (bool), Tracked (bool), Error (string or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string]$ChocoPackage,
        [string]$VersionFlag = "--version",
        [scriptblock]$ParseScript = $null,
        [switch]$AlwaysUpgradeToLatest,
        [scriptblock]$InstallScript = $null,
        [scriptblock]$UpgradeScript = $null,
        [string]$FriendlyName = ""
    )

    if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $FriendlyName = $Name }

    # Fall back to the registered per-tool parser when the caller didn't
    # supply one. This keeps the stored version accurate (e.g. "2.43.0"
    # instead of "git version 2.43.0.windows.1") without forcing every
    # caller to repeat the same regex.
    if ($null -eq $ParseScript -and (Get-Command Get-ToolVersionParser -ErrorAction SilentlyContinue)) {
        $registered = Get-ToolVersionParser -Name $Name
        if ($null -ne $registered) { $ParseScript = $registered }
    }

    $result = @{
        Action  = "skipped"
        Version = $null
        Existed = $false
        Tracked = $false
        Error   = $null
    }

    # Default install/upgrade closures use Chocolatey.
    if ($null -eq $InstallScript) {
        if ([string]::IsNullOrWhiteSpace($ChocoPackage)) {
            $reason = "no -InstallScript and no -ChocoPackage provided for tool '$Name'"
            Write-EnsureFileError -Path ".installed/$Name.json" -Reason $reason
            Save-InstalledError -Name $Name -ErrorMessage $reason
            $result.Action = "failed"
            $result.Error  = $reason
            return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
        }
        $InstallScript = { Install-ChocoPackage -PackageName $using:ChocoPackage }.GetNewClosure()
    }
    if ($null -eq $UpgradeScript -and -not [string]::IsNullOrWhiteSpace($ChocoPackage)) {
        $UpgradeScript = { Upgrade-ChocoPackage -PackageName $using:ChocoPackage }.GetNewClosure()
    }

    # ---- Step 1: detect ------------------------------------------------------
    $cmdInfo = Get-Command $Command -ErrorAction SilentlyContinue
    $isCommandPresent = $null -ne $cmdInfo
    $result.Existed = $isCommandPresent

    if ($isCommandPresent) {
        $currentVersion = Get-EnsuredVersion -Command $Command -VersionFlag $VersionFlag -ParseScript $ParseScript
        $hasVersion = -not [string]::IsNullOrWhiteSpace($currentVersion)
        $result.Version = $currentVersion

        # ---- Step 2: tracked & matching version -> skip ----------------------
        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name $Name -CurrentVersion $currentVersion
            $result.Tracked = $isAlreadyTracked
            if ($isAlreadyTracked) {
                Write-Log "$FriendlyName already installed and tracked: $currentVersion -- skipping" -Level "info"
                $result.Action = "skipped"
                return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
            }
            Write-Log "$FriendlyName found in PATH: $currentVersion (not tracked or version drift)" -Level "info"
        } else {
            Write-Log "$FriendlyName found in PATH but version probe returned nothing" -Level "warn"
        }

        # ---- Step 3: upgrade path -------------------------------------------
        if ($AlwaysUpgradeToLatest -and $null -ne $UpgradeScript) {
            try {
                Write-Log "Upgrading $FriendlyName to latest..." -Level "info"
                & $UpgradeScript
                Refresh-EnvPath
                $newVersion = Get-EnsuredVersion -Command $Command -VersionFlag $VersionFlag -ParseScript $ParseScript
                if ([string]::IsNullOrWhiteSpace($newVersion)) { $newVersion = "$currentVersion (pending refresh)" }
                Save-InstalledRecord -Name $Name -Version $newVersion
                Write-Log "$FriendlyName upgraded successfully: $newVersion" -Level "success"
                $result.Action  = "upgraded"
                $result.Version = $newVersion
                return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
            } catch {
                $reason = "upgrade failed: $_"
                Write-EnsureFileError -Path ".installed/$Name.json" -Reason $reason
                Save-InstalledError -Name $Name -ErrorMessage "$_"
                $result.Action = "failed"
                $result.Error  = "$_"
                return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
            }
        }

        # No upgrade requested -- record current version so future runs are fast.
        if ($hasVersion) {
            Save-InstalledRecord -Name $Name -Version $currentVersion
            $result.Tracked = $true
        }
        return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
    }

    # ---- Step 4: missing -> install -----------------------------------------
    Write-Log "$FriendlyName not found, installing..." -Level "info"
    try {
        & $InstallScript
        Refresh-EnvPath
        $installedVersion = Get-EnsuredVersion -Command $Command -VersionFlag $VersionFlag -ParseScript $ParseScript
        if ([string]::IsNullOrWhiteSpace($installedVersion)) { $installedVersion = "unknown" }
        Save-InstalledRecord -Name $Name -Version $installedVersion
        Write-Log "$FriendlyName installed successfully: $installedVersion" -Level "success"
        $result.Action  = "installed"
        $result.Version = $installedVersion
        return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
    } catch {
        $reason = "install failed: $_"
        Write-EnsureFileError -Path ".installed/$Name.json" -Reason $reason
        Save-InstalledError -Name $Name -ErrorMessage "$_"
        $result.Action = "failed"
        $result.Error  = "$_"
        return (Complete-EnsureToolResult -Name $Name -FriendlyName $FriendlyName -Result $result)
    }
}
