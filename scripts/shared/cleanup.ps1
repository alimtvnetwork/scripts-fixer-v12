<#
.SYNOPSIS
    Clears the .resolved/ folder for a fresh start.

.DESCRIPTION
    Removes all contents of <repo-root>/.resolved/ so that the next script
    run re-detects everything from scratch. The folder itself is preserved.

.PARAMETER ScriptDir
    Any script directory -- used to locate the repo root.

.PARAMETER EditionName
    Optional. If provided, only clears that edition's key from the
    script's resolved.json instead of wiping the whole folder.
#>

# -- Bootstrap shared helpers --------------------------------------------------
$loggingPath = Join-Path $PSScriptRoot "logging.ps1"
if ((Test-Path $loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $loggingPath
}

if (-not (Get-Variable -Name SharedLogMessages -Scope Script -ErrorAction SilentlyContinue)) {
    $sharedLogPath = Join-Path $PSScriptRoot "log-messages.json"
    if (Test-Path $sharedLogPath) {
        $script:SharedLogMessages = Get-Content $sharedLogPath -Raw | ConvertFrom-Json
    }
}

function Clear-ResolvedData {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptDir,

        [string]$EditionName
    )

    $slm = $script:SharedLogMessages

    $repoRoot    = Split-Path -Parent (Split-Path -Parent $ScriptDir)
    $resolvedDir = Join-Path $repoRoot ".resolved"

    $isDirMissing = -not (Test-Path $resolvedDir)
    if ($isDirMissing) {
        Write-Log $slm.messages.cleanupNothingToClean -Level "info"
        return
    }

    if ($EditionName) {
        # Clear only a specific edition key from this script's resolved.json
        $scriptName   = Split-Path -Leaf $ScriptDir
        $resolvedFile = Join-Path (Join-Path $resolvedDir $scriptName) "resolved.json"

        $hasNoResolvedFile = -not (Test-Path $resolvedFile)
        if ($hasNoResolvedFile) {
            Write-Log ($slm.messages.cleanupNoResolvedJson -replace '\{script\}', $scriptName) -Level "info"
            return
        }

        try {
            $raw  = Get-Content $resolvedFile -Raw | ConvertFrom-Json
            $ht   = @{}
            foreach ($prop in $raw.PSObject.Properties) {
                if ($prop.Name -ne $EditionName) {
                    $ht[$prop.Name] = $prop.Value
                }
            }

            if ($ht.Count -eq 0) {
                Remove-Item -Path $resolvedFile -Force
                Write-Log ($slm.messages.cleanupRemovedFile -replace '\{script\}', $scriptName -replace '\{edition\}', $EditionName) -Level "success"
            } else {
                $json = $ht | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($resolvedFile, $json)
                Write-Log ($slm.messages.cleanupClearedEdition -replace '\{edition\}', $EditionName -replace '\{script\}', $scriptName) -Level "success"
            }
        } catch {
            Write-FileError -FilePath $resolvedFile -Operation "write" -Reason "Failed to clear edition '$EditionName': $_" -Module "Clear-ResolvedData"
            Write-Log ($slm.messages.cleanupEditionFailed -replace '\{edition\}', $EditionName -replace '\{error\}', $_) -Level "warn"
        }
        return
    }

    # Clear everything
    Write-Log $slm.messages.cleanupClearingAll -Level "info"
    try {
        Get-ChildItem -Path $resolvedDir -Recurse -Force | Remove-Item -Recurse -Force
        Write-Log $slm.messages.cleanupAllRemoved -Level "success"
    } catch {
        Write-FileError -FilePath $resolvedDir -Operation "write" -Reason "Failed to clear .resolved/ directory: $_" -Module "Clear-ResolvedData"
        Write-Log ($slm.messages.cleanupFailed -replace '\{error\}', $_) -Level "warn"
    }
}
