<#
.SYNOPSIS
    Quick read-only verification of VS Code context-menu registry entries.

.DESCRIPTION
    For every enabled edition in config.json, inspects the three target
    keys (file / directory / background) and reports:
      - key exists           ([Microsoft.Win32.Registry]::ClassesRoot)
      - (Default) label matches config label
      - Icon value present
      - \command (Default) is non-empty
      - the exe path embedded in the command resolves on disk

    Pure read-only -- never writes to the registry. Returns a structured
    result object so callers (run.ps1, CI) can react to PASS / MISS counts.

    Naming follows project convention: is/has booleans, no bare -not.
#>

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function Get-HkcrSubkeyPathLocal {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function Get-VsCodeMenuEntryStatus {
    <#
    .SYNOPSIS
        Inspect a single context-menu key and return a status hashtable.
    #>
    param(
        [Parameter(Mandatory)] [string] $TargetName,
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $ExpectedLabel
    )

    $status = [ordered]@{
        target          = $TargetName
        registryPath    = $RegistryPath
        keyExists       = $false
        labelOk         = $false
        actualLabel     = $null
        iconPresent     = $false
        commandPresent  = $false
        commandValue    = $null
        exeResolvable   = $false
        exePath         = $null
        verdict         = "MISS"
        reason          = $null
    }

    $sub  = Get-HkcrSubkeyPathLocal $RegistryPath
    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

    $key = $hkcr.OpenSubKey($sub)
    $isKeyMissing = $null -eq $key
    if ($isKeyMissing) {
        $status.reason = "registry key not found: $RegistryPath"
        return [pscustomobject]$status
    }
    $status.keyExists = $true
    try {
        $defaultVal = $key.GetValue("")
        $iconVal    = $key.GetValue("Icon")
        $status.actualLabel = [string]$defaultVal
        $status.iconPresent = -not [string]::IsNullOrWhiteSpace([string]$iconVal)
        $status.labelOk     = ($status.actualLabel -eq $ExpectedLabel)
    } finally {
        $key.Close()
    }

    $cmdKey = $hkcr.OpenSubKey("$sub\command")
    $isCmdMissing = $null -eq $cmdKey
    if ($isCmdMissing) {
        $status.reason = "missing \\command subkey under: $RegistryPath"
        return [pscustomobject]$status
    }
    try {
        $cmdLine = [string]$cmdKey.GetValue("")
        $status.commandValue   = $cmdLine
        $status.commandPresent = -not [string]::IsNullOrWhiteSpace($cmdLine)
    } finally {
        $cmdKey.Close()
    }

    # Extract the first quoted token = exe path
    $hasMatch = $status.commandValue -match '^\s*"([^"]+)"'
    if ($hasMatch) {
        $exe = $Matches[1]
        $expanded = [System.Environment]::ExpandEnvironmentVariables($exe)
        $status.exePath       = $expanded
        $status.exeResolvable = Test-Path -LiteralPath $expanded
    }

    # Verdict: every check must pass
    $isAllOk = $status.keyExists -and $status.labelOk -and $status.iconPresent `
        -and $status.commandPresent -and $status.exeResolvable
    if ($isAllOk) {
        $status.verdict = "PASS"
    } else {
        $reasons = @()
        if (-not $status.labelOk)        { $reasons += "label mismatch (got '$($status.actualLabel)', expected '$ExpectedLabel')" }
        if (-not $status.iconPresent)    { $reasons += "missing Icon value" }
        if (-not $status.commandPresent) { $reasons += "empty \\command (Default)" }
        if (-not $status.exeResolvable -and $status.exePath) {
            $reasons += "exe path not on disk: $($status.exePath)"
        } elseif (-not $status.exeResolvable) {
            $reasons += "could not parse exe path from command"
        }
        $status.reason = ($reasons -join "; ")
    }

    return [pscustomobject]$status
}

function Invoke-VsCodeMenuCheck {
    <#
    .SYNOPSIS
        Run quick verification across every enabled edition + target.
    .OUTPUTS
        PSCustomObject with .editions[], .totalPass, .totalMiss
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $LogMsgs,
        [string] $EditionFilter = ""
    )

    $editionResults = @()
    $totalPass = 0
    $totalMiss = 0

    $editions = @($Config.enabledEditions)
    $hasFilter = -not [string]::IsNullOrWhiteSpace($EditionFilter)
    if ($hasFilter) {
        $editions = $editions | Where-Object { $_ -ieq $EditionFilter }
    }

    foreach ($edName in $editions) {
        $hasEditionBlock = $Config.editions.PSObject.Properties.Name -contains $edName
        if (-not $hasEditionBlock) {
            Write-Log "Edition '$edName' has no editions.$edName block in config.json (failure: cannot verify unknown edition)" -Level "warn"
            continue
        }
        $ed = $Config.editions.$edName

        Write-Log "" -Level "info"
        Write-Log ("Checking edition '" + $edName + "' (" + $ed.label + ")") -Level "info"

        $perTarget = @()
        foreach ($targetName in @('file','directory','background')) {
            $hasTarget = $ed.registryPaths.PSObject.Properties.Name -contains $targetName
            if (-not $hasTarget) {
                Write-Log "  [skip] $targetName -- no registryPaths.$targetName entry in config" -Level "warn"
                continue
            }
            $regPath = $ed.registryPaths.$targetName
            $st = Get-VsCodeMenuEntryStatus -TargetName $targetName -RegistryPath $regPath -ExpectedLabel $ed.label
            $perTarget += $st

            $tag = if ($targetName -eq 'directory') { 'folder    ' }
                   elseif ($targetName -eq 'background') { 'background' }
                   else { 'file      ' }
            $line = "  [{0}] {1}  {2}" -f $st.verdict, $tag, $regPath
            $level = if ($st.verdict -eq 'PASS') { 'success' } else { 'error' }
            Write-Log $line -Level $level
            if ($st.verdict -ne 'PASS' -and $st.reason) {
                Write-Log ("           reason: " + $st.reason + " (failure path: " + $regPath + ")") -Level "error"
            }
            if ($st.verdict -eq 'PASS') { $totalPass++ } else { $totalMiss++ }
        }

        $folderResult = $perTarget | Where-Object { $_.target -eq 'directory'  } | Select-Object -First 1
        $bgResult     = $perTarget | Where-Object { $_.target -eq 'background' } | Select-Object -First 1
        $folderTag    = if ($folderResult) { $folderResult.verdict } else { "n/a" }
        $bgTag        = if ($bgResult)     { $bgResult.verdict     } else { "n/a" }
        Write-Log ("  summary: folder=" + $folderTag + ", background=" + $bgTag) -Level "info"

        $editionResults += [pscustomobject]@{
            edition   = $edName
            label     = $ed.label
            targets   = $perTarget
            folderOk  = ($folderTag -eq 'PASS')
            bgOk      = ($bgTag     -eq 'PASS')
        }
    }

    Write-Log "" -Level "info"
    Write-Log ("Verification totals: PASS=" + $totalPass + ", MISS=" + $totalMiss) -Level $(if ($totalMiss -eq 0) { 'success' } else { 'error' })

    return [pscustomobject]@{
        editions  = $editionResults
        totalPass = $totalPass
        totalMiss = $totalMiss
    }
}
