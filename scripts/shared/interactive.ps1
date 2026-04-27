<#
.SYNOPSIS
    Cross-script "prompt with default" helpers (PowerShell side).

.DESCRIPTION
    Mirrors scripts-linux/_shared/interactive.sh. Gives 16/18 (and any future
    Windows script) a uniform interactive UX:

        MySQL port [3306]:    <-- Enter accepts the default

    Public API:
      Test-InteractiveFlag    -Argv $args                 -> [bool]
      Remove-InteractiveFlag  -Argv $args                 -> [string[]]
      Read-PromptWithDefault  -Label .. -Default .. [-Validator { param($v) ... }]
      Test-PortValue          -Value 3306                 -> [bool]
      Test-PhpVersion         -Value 'latest'|'8.3'       -> [bool]
      Test-PathWritable       -Value 'C:\xampp\mysql'     -> [bool]

    Read-PromptWithDefault reads from the host (Read-Host); when stdin is not
    interactive it returns the default and writes a one-line warning so CI
    does not block. Validator is a scriptblock returning $true to accept.
#>

Set-StrictMode -Version Latest

function Test-InteractiveFlag {
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        if ($a -eq '-i' -or $a -eq '--interactive' -or $a -eq '-Interactive') { return $true }
    }
    return $false
}

function Remove-InteractiveFlag {
    param([string[]]$Argv)
    $out = @()
    if ($null -eq $Argv) { return $out }
    foreach ($a in $Argv) {
        $isFlag = ($a -eq '-i' -or $a -eq '--interactive' -or $a -eq '-Interactive')
        if (-not $isFlag) { $out += $a }
    }
    return $out
}

function Read-PromptWithDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter()]          [string] $Default = '',
        [Parameter()]          [scriptblock] $Validator = $null
    )
    $isInteractive = [Environment]::UserInteractive -and $Host.UI -and $Host.Name -ne 'Default Host'
    if (-not $isInteractive) {
        Write-Host ("  [non-interactive] {0} -> using default '{1}'" -f $Label, $Default) -ForegroundColor DarkYellow
        return $Default
    }
    while ($true) {
        $shown = if ($Default) { "{0} [{1}]" -f $Label, $Default } else { $Label }
        $reply = Read-Host -Prompt ("  " + $shown)
        if ([string]::IsNullOrWhiteSpace($reply)) { $reply = $Default }
        if ($null -eq $Validator) { return $reply }
        $isOk = $false
        try { $isOk = [bool](& $Validator $reply) } catch { $isOk = $false }
        if ($isOk) { return $reply }
        Write-Host "  -> invalid value, please try again." -ForegroundColor Yellow
    }
}

function Test-PortValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $n = 0
    if (-not [int]::TryParse($Value, [ref]$n)) { return $false }
    return ($n -ge 1 -and $n -le 65535)
}

function Test-PhpVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -ieq 'latest') { return $true }
    return ($Value -match '^[5-9]\.[0-9]+(\.[0-9]+)?$')
}

function Test-PathWritable {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if (Test-Path -LiteralPath $Value -PathType Container) { return $true }
    $parent = Split-Path -Parent -Path $Value
    if ([string]::IsNullOrWhiteSpace($parent)) { return $false }
    return (Test-Path -LiteralPath $parent -PathType Container)
}
