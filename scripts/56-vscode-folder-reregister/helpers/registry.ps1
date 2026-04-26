# ---------------------------------------------------------------------------
# Script 56 -- helpers/registry.ps1
# Tiny, self-contained registry helpers for the folder + background
# context-menu entries. Intentionally NOT shared with Script 10 so this
# script can be lifted out of the toolkit standalone.
# ---------------------------------------------------------------------------

function Resolve-VsCodeExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $VscodePathMap,
        [Parameter(Mandatory)] [string]    $InstallType   # "user" | "system"
    )
    # Try the preferred install type first, then fall back to the other.
    $order = @($InstallType)
    if ($InstallType -eq 'user')   { $order += 'system' } else { $order += 'user' }
    foreach ($kind in $order) {
        $raw = $VscodePathMap[$kind]
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($raw)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            return [pscustomobject]@{ Path = $expanded; Kind = $kind }
        }
    }
    return $null
}

function Set-FolderContextMenuKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RegPath,    # "Registry::HKEY_CLASSES_ROOT\Directory\shell\VSCode"
        [Parameter(Mandatory)] [string] $Label,      # "Open with Code"
        [Parameter(Mandatory)] [string] $ExePath,    # full path to Code.exe
        [Parameter(Mandatory)] [ValidateSet('directory','background')] [string] $Target
    )
    # Both directory and background pass the clicked path via "%V". The two
    # are otherwise identical; we keep the parameter so future divergence
    # (e.g. "%1" for one of them) stays a one-line change.
    $arg = '"%V"'

    # Ensure parent + leaf keys exist. New-Item is idempotent only when the
    # key is missing; -Force makes it work for both cases.
    $cmdPath = Join-Path $RegPath 'command'
    if (-not (Test-Path -LiteralPath $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $cmdPath)) { New-Item -Path $cmdPath -Force | Out-Null }

    # Set (Default) label, Icon, and command. Set-ItemProperty on a freshly
    # created key sometimes throws PSChildName errors; New-ItemProperty -Force
    # is the documented, idempotent path.
    New-ItemProperty -Path $RegPath -Name '(Default)' -Value $Label   -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name 'Icon'      -Value ('"' + $ExePath + '"') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $cmdPath -Name '(Default)' -Value (('"' + $ExePath + '" ') + $arg) -PropertyType String -Force | Out-Null
    return $true
}

function Remove-FolderContextMenuKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RegPath
    )
    if (-not (Test-Path -LiteralPath $RegPath)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'absent' }
    }
    Remove-Item -LiteralPath $RegPath -Recurse -Force -ErrorAction Stop
    return [pscustomobject]@{ Removed = $true; Reason = 'deleted' }
}

function Test-FolderContextMenuKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RegPath,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $ExePath
    )
    $result = [pscustomobject]@{
        KeyExists       = $false
        DefaultMatches  = $false
        CommandMatches  = $false
        ActualDefault   = $null
        ActualCommand   = $null
    }
    if (-not (Test-Path -LiteralPath $RegPath)) { return $result }
    $result.KeyExists = $true
    try {
        $defProp = Get-ItemProperty -LiteralPath $RegPath -Name '(Default)' -ErrorAction Stop
        $result.ActualDefault = $defProp.'(default)'
        if (-not $result.ActualDefault) { $result.ActualDefault = $defProp.'(Default)' }
        $result.DefaultMatches = ($result.ActualDefault -eq $Label)
    } catch { }
    try {
        $cmdProp = Get-ItemProperty -LiteralPath (Join-Path $RegPath 'command') -Name '(Default)' -ErrorAction Stop
        $result.ActualCommand = $cmdProp.'(default)'
        if (-not $result.ActualCommand) { $result.ActualCommand = $cmdProp.'(Default)' }
        $result.CommandMatches = ($result.ActualCommand -like ('*"' + $ExePath + '"*'))
    } catch { }
    return $result
}