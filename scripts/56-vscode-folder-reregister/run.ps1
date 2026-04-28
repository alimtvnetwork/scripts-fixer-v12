# ---------------------------------------------------------------------------
#  Script 56 -- VS Code Folder Context Menu Re-register (standalone)
#
#  Re-creates the "Open with Code" entries on the FOLDER and BACKGROUND
#  targets only (HKCR\Directory\shell\<Name> and
#  HKCR\Directory\Background\shell\<Name>). Never touches the per-file
#  HKCR\*\shell\<Name> key. Auto-removes the entries for any edition whose
#  Code.exe is no longer on disk (config: autoRemoveWhenMissing).
#
#  Verbs: reregister (default) | remove | check | help
# ---------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Verb = "reregister",

    [string]$Edition,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "install-paths.ps1")
. (Join-Path $scriptDir "helpers\registry.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Verb -eq "--help" -or $Verb -eq "-h") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "VS Code folder shell verbs" `
    -Action "Repair" `
    -Source "VS Code install dir Code.exe" `
    -Temp   ($env:TEMP + "\scripts-fixer\vscode-reregister") `
    -Target ("HKCR:\Directory\shell\VSCode\command")
Initialize-Logging -ScriptName $logMessages.scriptName

# Convenience: pull a message and substitute {placeholders}.
function _msg($key, [hashtable]$vars) {
    $template = $logMessages.messages.$key
    if (-not $template) { return $key }
    if ($null -ne $vars) {
        foreach ($k in $vars.Keys) {
            $template = $template -replace ('\{' + [regex]::Escape($k) + '\}'), [string]$vars[$k]
        }
    }
    return $template
}

# config.editions is parsed as a PSCustomObject by ConvertFrom-Json. Wrap
# the per-edition vscodePath / registryPaths in real hashtables so the
# helpers can index them with [string].
function _toHash($psObj) {
    $h = @{}
    if ($null -eq $psObj) { return $h }
    foreach ($p in $psObj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-EnabledEditions {
    param([string]$Filter)
    $names = @($config.enabledEditions)
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $names = @($names | Where-Object { $_ -eq $Filter })
        if ($names.Count -eq 0) {
            Write-Log ("Edition filter '" + $Filter + "' matched none of: " + (@($config.enabledEditions) -join ', ')) -Level "warn"
        }
    }
    $out = @()
    foreach ($n in $names) {
        $eDef = $config.editions.$n
        $isMissing = $null -eq $eDef
        if ($isMissing) {
            Write-Log (_msg 'unknownEdition' @{ name = $n }) -Level "warn"
            continue
        }
        $out += [pscustomobject]@{
            Name           = $n
            VscodePathMap  = (_toHash $eDef.vscodePath)
            RegistryPaths  = (_toHash $eDef.registryPaths)
            Label          = [string]$eDef.contextMenuLabel
        }
    }
    return ,$out
}

function Assert-AdminOrFail {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log $logMessages.messages.notAdmin -Level "error"
        return $false
    }
    return $true
}

function Invoke-Reregister {
    if (-not (Assert-AdminOrFail)) { return 1 }
    $hadError = $false
    foreach ($ed in (Get-EnabledEditions -Filter $Edition)) {
        Write-Log (_msg 'editionStart' @{ name = $ed.Name; path = ($ed.VscodePathMap.user) }) -Level "info"
        $exe = Resolve-VsCodeExe -VscodePathMap $ed.VscodePathMap -InstallType $config.installationType
        $isExeMissing = $null -eq $exe
        if ($isExeMissing) {
            if ($config.autoRemoveWhenMissing) {
                Write-Log (_msg 'exeMissingAutoRemove' @{ name = $ed.Name }) -Level "warn"
                foreach ($targetName in @('directory','background')) {
                    $regPath = $ed.RegistryPaths[$targetName]
                    if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
                    try {
                        $r = Remove-FolderContextMenuKey -RegPath $regPath
                        if ($r.Removed) { Write-Log (_msg 'removed'        @{ name = $ed.Name; path = $regPath }) -Level "success" }
                        else            { Write-Log (_msg 'alreadyAbsent'  @{ name = $ed.Name; path = $regPath }) -Level "info" }
                    } catch {
                        Write-Log ("Edition '" + $ed.Name + "': failed to remove '" + $regPath + "' (failure: " + $_.Exception.Message + ")") -Level "error"
                        $hadError = $true
                    }
                }
            } else {
                Write-Log (_msg 'exeMissingRegister' @{
                    name       = $ed.Name
                    userPath   = $ed.VscodePathMap.user
                    systemPath = $ed.VscodePathMap.system
                }) -Level "warn"
                $hadError = $true
            }
            continue
        }

        foreach ($targetName in @('directory','background')) {
            $regPath = $ed.RegistryPaths[$targetName]
            if ([string]::IsNullOrWhiteSpace($regPath)) {
                Write-Log ("Edition '" + $ed.Name + "': registryPaths." + $targetName + " is empty in config.json -- skipping") -Level "warn"
                continue
            }
            try {
                Set-FolderContextMenuKey -RegPath $regPath -Label $ed.Label -ExePath $exe.Path -Target $targetName | Out-Null
                Write-Log (_msg 'registered' @{ name = $ed.Name; label = $ed.Label; path = $regPath }) -Level "success"
            } catch {
                Write-Log ("Edition '" + $ed.Name + "': failed to register '" + $regPath + "' (failure: " + $_.Exception.Message + ")") -Level "error"
                $hadError = $true
            }
        }
    }
    Write-Log $logMessages.messages.doneRegister -Level "success"
    Save-ResolvedData -ScriptFolder "56-vscode-folder-reregister" -Data @{
        editions  = (@($config.enabledEditions) -join ',')
        timestamp = (Get-Date -Format "o")
    }
    if ($hadError) { return 1 } else { return 0 }
}

function Invoke-Remove {
    if (-not (Assert-AdminOrFail)) { return 1 }
    $hadError = $false
    foreach ($ed in (Get-EnabledEditions -Filter $Edition)) {
        foreach ($targetName in @('directory','background')) {
            $regPath = $ed.RegistryPaths[$targetName]
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            try {
                $r = Remove-FolderContextMenuKey -RegPath $regPath
                if ($r.Removed) { Write-Log (_msg 'removed'       @{ name = $ed.Name; path = $regPath }) -Level "success" }
                else            { Write-Log (_msg 'alreadyAbsent' @{ name = $ed.Name; path = $regPath }) -Level "info" }
            } catch {
                Write-Log ("Edition '" + $ed.Name + "': failed to remove '" + $regPath + "' (failure: " + $_.Exception.Message + ")") -Level "error"
                $hadError = $true
            }
        }
    }
    Write-Log $logMessages.messages.doneRemove -Level "success"
    if ($hadError) { return 1 } else { return 0 }
}

function Invoke-Check {
    # Read-only -- no admin needed.
    $pass = 0; $miss = 0
    foreach ($ed in (Get-EnabledEditions -Filter $Edition)) {
        $exe = Resolve-VsCodeExe -VscodePathMap $ed.VscodePathMap -InstallType $config.installationType
        foreach ($targetName in @('directory','background')) {
            $regPath = $ed.RegistryPaths[$targetName]
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $hasExe = $null -ne $exe
            $expectedExe = if ($hasExe) { $exe.Path } else { '<exe missing on disk>' }
            $r = Test-FolderContextMenuKey -RegPath $regPath -Label $ed.Label -ExePath $expectedExe
            if (-not $r.KeyExists) {
                Write-Log (_msg 'checkMissExe' @{ name = $ed.Name; target = $targetName; path = $regPath }) -Level "error"
                $miss++
                continue
            }
            if (-not $r.DefaultMatches) {
                Write-Log (_msg 'checkMissDefault' @{ name = $ed.Name; target = $targetName; path = $regPath; got = ($r.ActualDefault); want = $ed.Label }) -Level "error"
                $miss++
            }
            if ($hasExe -and -not $r.CommandMatches) {
                Write-Log (_msg 'checkMissCommand' @{ name = $ed.Name; target = $targetName; path = $regPath }) -Level "error"
                $miss++
            }
            if ($r.KeyExists -and $r.DefaultMatches -and ($hasExe -eq $false -or $r.CommandMatches)) {
                Write-Log (_msg 'checkPass' @{ name = $ed.Name; target = $targetName; exe = $expectedExe }) -Level "success"
                $pass++
            }
        }
    }
    Write-Log (_msg 'checkSummary' @{ pass = $pass; miss = $miss }) -Level $(if ($miss -eq 0) { 'success' } else { 'error' })
    if ($miss -eq 0) { return 0 } else { return 1 }
}

try {
    $isDisabled = -not $config.enabled
    if ($isDisabled) {
        Write-Log $logMessages.messages.scriptDisabled -Level "warn"
        $exitCode = 0
    } else {
        switch ($Verb.ToLower()) {
            'reregister'      { $exitCode = Invoke-Reregister }
            're-register'     { $exitCode = Invoke-Reregister }
            'install'         { $exitCode = Invoke-Reregister }
            'remove'          { $exitCode = Invoke-Remove }
            'uninstall'       { $exitCode = Invoke-Remove }
            'check'           { $exitCode = Invoke-Check }
            default {
                Write-Log (_msg 'unknownVerb' @{ verb = $Verb }) -Level "error"
                Show-ScriptHelp -LogMessages $logMessages
                $exitCode = 2
            }
        }
    }
} catch {
    Write-Log ("Unhandled error: " + $_) -Level "error"
    Write-Log ("Stack: " + $_.ScriptStackTrace) -Level "error"
    $exitCode = 1
} finally {
    $hasErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasErrors) { "fail" } else { "ok" })
}

exit $exitCode