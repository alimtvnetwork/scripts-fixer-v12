# --------------------------------------------------------------------------
#  Tool-version parser registry
#
#  Different CLIs print versions in wildly different shapes:
#
#    git           -> "git version 2.43.0.windows.1"
#    node          -> "v20.11.0"
#    python        -> "Python 3.12.1"
#    go            -> "go version go1.22.0 windows/amd64"
#    java          -> writes to STDERR with "openjdk version \"21.0.2\" 2024-..."
#    dotnet        -> "8.0.101"
#    rustc         -> "rustc 1.76.0 (07dca489a 2024-02-04)"
#
#  Without a per-tool parser, Ensure-Tool stores the raw line, so the
#  .installed/<name>.json record drifts from what users (and `run.ps1 status`)
#  expect. Centralising parsers here means every caller of Ensure-Tool gets
#  the right answer for free, and a tool can be added in one place.
#
#  Public surface:
#    Get-ToolVersionParser -Name <tool>     -> [scriptblock] or $null
#    Invoke-ToolVersionParser -Name <tool> -Raw <string> -> string
#    Register-ToolVersionParser -Name <tool> -Parser <scriptblock>
#
#  Each parser receives the raw output (string or string[]) and must return
#  a single trimmed version string, or $null if it cannot parse.
# --------------------------------------------------------------------------

if (-not (Get-Variable -Name __ToolVersionParsers -Scope Script -ErrorAction SilentlyContinue)) {
    $script:__ToolVersionParsers = @{}
}

function ConvertTo-RawVersionText {
    param($Raw)
    if ($null -eq $Raw) { return "" }
    if ($Raw -is [array]) { return ($Raw -join "`n") }
    return [string]$Raw
}

function Get-FirstSemverMatch {
    # Pull the first dotted version-looking token out of free-form text.
    # Handles "1.2", "1.2.3", "1.2.3.4", "1.2.3-rc.1", "1.2.3+build.5".
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $rx = [regex]'\b(\d+\.\d+(?:\.\d+){0,2})(?:[-+][0-9A-Za-z\.\-]+)?\b'
    $m  = $rx.Match($Text)
    if ($m.Success) { return $m.Value }
    return $null
}

# -- Built-in parsers ------------------------------------------------------

$script:__ToolVersionParsers["git"] = {
    param($raw)
    $text = ConvertTo-RawVersionText $raw
    # "git version 2.43.0.windows.1" -> "2.43.0.windows.1"
    if ($text -match 'git version\s+([^\s]+)') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["node"] = {
    param($raw)
    $text = (ConvertTo-RawVersionText $raw).Trim()
    # node prints "v20.11.0"
    if ($text -match '^v?(\d+\.\d+\.\d+)') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["nodejs"] = $script:__ToolVersionParsers["node"]

$script:__ToolVersionParsers["python"] = {
    param($raw)
    $text = ConvertTo-RawVersionText $raw
    # "Python 3.12.1"
    if ($text -match 'Python\s+([\d\.]+)') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["go"] = {
    param($raw)
    $text = ConvertTo-RawVersionText $raw
    # "go version go1.22.0 windows/amd64"
    if ($text -match 'go version\s+go([\d\.]+)') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["java"] = {
    param($raw)
    $text = ConvertTo-RawVersionText $raw
    # 'openjdk version "21.0.2" 2024-01-16' or '"1.8.0_392"'
    if ($text -match 'version\s+"([^"]+)"') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["dotnet"] = {
    param($raw)
    # `dotnet --version` already returns just "8.0.101"
    $text = (ConvertTo-RawVersionText $raw).Trim()
    if ($text -match '^[\d\.]+$') { return $text }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["rustc"] = {
    param($raw)
    $text = ConvertTo-RawVersionText $raw
    # "rustc 1.76.0 (07dca489a 2024-02-04)"
    if ($text -match 'rustc\s+([\d\.]+)') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

$script:__ToolVersionParsers["pnpm"] = {
    param($raw)
    (ConvertTo-RawVersionText $raw).Trim() | ForEach-Object { Get-FirstSemverMatch $_ }
}

$script:__ToolVersionParsers["choco"] = {
    param($raw)
    # "Chocolatey v2.2.2"
    $text = ConvertTo-RawVersionText $raw
    if ($text -match 'Chocolatey\s+v?([\d\.]+)') { return $Matches[1] }
    return (Get-FirstSemverMatch $text)
}

# -- Public API ------------------------------------------------------------

function Get-ToolVersionParser {
    param([Parameter(Mandatory)][string]$Name)
    $key = $Name.ToLowerInvariant()
    if ($script:__ToolVersionParsers.ContainsKey($key)) {
        return $script:__ToolVersionParsers[$key]
    }
    return $null
}

function Invoke-ToolVersionParser {
    <#
    .SYNOPSIS
        Apply the registered parser for <Name>, falling back to a generic
        semver-extraction parser. Always returns a trimmed string (possibly
        the raw input if nothing matched).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        $Raw
    )
    $parser  = Get-ToolVersionParser -Name $Name
    $rawText = ConvertTo-RawVersionText $Raw

    if ($null -ne $parser) {
        try {
            $parsed = & $parser $Raw
            if (-not [string]::IsNullOrWhiteSpace($parsed)) {
                return ([string]$parsed).Trim()
            }
        } catch {
            # Parser blew up -> fall through to generic semver extraction.
        }
    }

    $generic = Get-FirstSemverMatch $rawText
    if (-not [string]::IsNullOrWhiteSpace($generic)) { return $generic }
    return $rawText.Trim()
}

function Register-ToolVersionParser {
    <#
    .SYNOPSIS
        Add or override a parser at runtime. Handy for one-off tools the
        registry doesn't ship with.

    .EXAMPLE
        Register-ToolVersionParser -Name "kubectl" -Parser {
            param($raw)
            if ("$raw" -match 'GitVersion:"v([\d\.]+)') { return $Matches[1] }
            return $null
        }
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Parser
    )
    $script:__ToolVersionParsers[$Name.ToLowerInvariant()] = $Parser
}
