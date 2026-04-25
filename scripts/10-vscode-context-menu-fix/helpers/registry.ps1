<#
.SYNOPSIS
    Registry and VS Code resolution helpers for the context-menu-fix script.

.NOTES
    Uses reg.exe for all registry writes to avoid PowerShell provider issues
    with wildcard characters (HKCR:\*) and -LiteralPath incompatibility
    on Windows PowerShell 5.1.
#>

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}


function Assert-Admin {
    $logMsgs = Import-JsonConfig (Join-Path $script:ScriptDir "log-messages.json")
    Write-Log $logMsgs.messages.checkingAdmin -Level "info"
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $hasAdminRights = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ($logMsgs.messages.currentUser -replace '\{name\}', $identity.Name) -Level "info"
    Write-Log ($logMsgs.messages.isAdministrator -replace '\{value\}', $hasAdminRights) -Level $(if ($hasAdminRights) { "success" } else { "error" })
    return $hasAdminRights
}

function Resolve-VsCodePath {
    param(
        [PSCustomObject]$PathConfig,
        [string]$PreferredType,
        [string]$ScriptDir,
        [string]$EditionName
    )

    $logMsgs = Import-JsonConfig (Join-Path $ScriptDir "log-messages.json")

    # Check .resolved/ cache first
    if ($ScriptDir -and $EditionName) {
        $resolvedDir  = Get-ResolvedDir -ScriptDir $ScriptDir
        $resolvedFile = Join-Path $resolvedDir "resolved.json"
        $hasCacheFile = Test-Path $resolvedFile
        if ($hasCacheFile) {
            try {
                $cached = Get-Content $resolvedFile -Raw | ConvertFrom-Json
                $cachedExe = $cached.$EditionName.resolvedExe
                $isCachedPathValid = $cachedExe -and (Test-Path $cachedExe)
                if ($isCachedPathValid) {
                    Write-Log ($logMsgs.messages.usingCachedPath -replace '\{path\}', $cachedExe) -Level "success"
                    return $cachedExe
                } elseif ($cachedExe) {
                    Write-Log ($logMsgs.messages.cachedPathInvalid -replace '\{path\}', $cachedExe) -Level "warn"
                }
            } catch {
                Write-Log $logMsgs.messages.cacheReadFailed -Level "warn"
            }
        }
    }

    Write-Log ($logMsgs.messages.preferredInstallType -replace '\{type\}', $PreferredType) -Level "info"

    # Try preferred path
    $rawPath = $PathConfig.$PreferredType
    Write-Log (($logMsgs.messages.rawConfigValue -replace '\{type\}', $PreferredType) -replace '\{path\}', $rawPath) -Level "info"
    $exePath = [System.Environment]::ExpandEnvironmentVariables($rawPath)
    Write-Log ($logMsgs.messages.expandedPath -replace '\{path\}', $exePath) -Level "info"

    $isPreferredFound = Test-Path $exePath
    Write-Log ((($logMsgs.messages.fileExistsAtPath -replace '\{path\}', $exePath) -replace '\{result\}', $isPreferredFound)) -Level $(if ($isPreferredFound) { "success" } else { "error" })

    if ($isPreferredFound) { return $exePath }

    # Fallback to other config type (user <-> system)
    $fallbackType = if ($PreferredType -eq "user") { "system" } else { "user" }
    Write-Log ($logMsgs.messages.tryingFallback -replace '\{type\}', $fallbackType) -Level "warn"

    $fallbackRaw = $PathConfig.$fallbackType
    Write-Log (($logMsgs.messages.rawConfigValue -replace '\{type\}', $fallbackType) -replace '\{path\}', $fallbackRaw) -Level "info"
    $fallbackExe = [System.Environment]::ExpandEnvironmentVariables($fallbackRaw)
    Write-Log ($logMsgs.messages.expandedPath -replace '\{path\}', $fallbackExe) -Level "info"

    $isFallbackFound = Test-Path $fallbackExe
    Write-Log ((($logMsgs.messages.fileExistsAtPath -replace '\{path\}', $fallbackExe) -replace '\{result\}', $isFallbackFound)) -Level $(if ($isFallbackFound) { "success" } else { "error" })

    if ($isFallbackFound) { return $fallbackExe }

    # Fallback: Chocolatey shim path (choco installs often end up here)
    Write-Log "Config paths not found -- trying Chocolatey shim detection..." -Level "info"
    $chocoExeName = if ($EditionName -eq "insiders") { "Code - Insiders.exe" } else { "Code.exe" }
    $chocoShimDir = Join-Path $env:ProgramData "chocolatey\bin"
    $chocoShimExe = Join-Path $chocoShimDir $chocoExeName
    $isChocoShimFound = Test-Path $chocoShimExe
    if ($isChocoShimFound) {
        Write-Log "Found Chocolatey shim: $chocoShimExe" -Level "success"
        return $chocoShimExe
    }
    Write-Log "Chocolatey shim not found: $chocoShimExe" -Level "warn"

    # Fallback: search common Chocolatey install directories
    $chocoLibBase = Join-Path $env:ProgramData "chocolatey\lib"
    $chocoPackage = if ($EditionName -eq "insiders") { "vscode-insiders" } else { "vscode" }
    $chocoLibDir  = Join-Path $chocoLibBase $chocoPackage
    if (Test-Path $chocoLibDir) {
        $foundExe = Get-ChildItem -Path $chocoLibDir -Filter $chocoExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $isChocoLibFound = $null -ne $foundExe
        if ($isChocoLibFound) {
            Write-Log "Found in Chocolatey lib: $($foundExe.FullName)" -Level "success"
            return $foundExe.FullName
        }
        Write-Log "Chocolatey lib dir exists but no $chocoExeName found in: $chocoLibDir" -Level "warn"
    } else {
        Write-Log "Chocolatey lib dir not found: $chocoLibDir" -Level "warn"
    }

    # Fallback: Get-Command (PATH-based discovery)
    Write-Log "Chocolatey paths not found -- trying PATH discovery via Get-Command..." -Level "info"
    $cmdName = if ($EditionName -eq "insiders") { "Code - Insiders" } else { "code" }
    $cmdResult = Get-Command $cmdName -ErrorAction SilentlyContinue
    $isCmdFound = $null -ne $cmdResult
    if ($isCmdFound) {
        $discoveredPath = $cmdResult.Source
        Write-Log "Found via Get-Command: $discoveredPath" -Level "success"
        return $discoveredPath
    }
    Write-Log "Get-Command could not find '$cmdName' in PATH" -Level "warn"

    # Fallback: where.exe (broader search than Get-Command)
    Write-Log "Trying where.exe for $chocoExeName..." -Level "info"
    try {
        $wherePath = (where.exe $chocoExeName 2>$null | Select-Object -First 1)
        $isWhereFound = $wherePath -and (Test-Path $wherePath)
        if ($isWhereFound) {
            Write-Log "Found via where.exe: $wherePath" -Level "success"
            return $wherePath
        }
        Write-Log "where.exe could not find $chocoExeName" -Level "warn"
    } catch {
        Write-Log "where.exe failed: $_" -Level "warn"
    }

    Write-Log $logMsgs.messages.noExeFound -Level "error"
    return $null
}

function Save-ResolvedPath {
    param(
        [string]$ScriptDir,
        [string]$EditionName,
        [string]$ResolvedExe
    )

    Save-ResolvedData -ScriptFolder "10-vscode-context-menu-fix" -Data @{
        $EditionName = @{
            resolvedExe  = $ResolvedExe
            resolvedAt   = (Get-Date -Format "o")
            resolvedBy   = $env:USERNAME
        }
    }
}

# -- Registry helpers using reg.exe -------------------------------------------

function ConvertTo-RegPath {
    <#
    .SYNOPSIS
        Converts a PowerShell Registry:: path to a native reg.exe path.
        e.g. Registry::HKEY_CLASSES_ROOT\*\shell\VSCode -> HKCR\*\shell\VSCode
    #>
    param([string]$PsPath)

    $p = $PsPath -replace '^Registry::', ''
    $p = $p -replace '^HKEY_CLASSES_ROOT', 'HKCR'
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return $p
}

function Register-ContextMenu {
    param(
        [string]$StepLabel,
        [string]$RegistryPath,
        [string]$Label,
        [string]$IconValue,
        [string]$CommandArg,
        [PSObject]$LogMsgs
    )

    Write-Log ($LogMsgs.messages.registerStep -replace '\{step\}', $StepLabel) -Level "info"
    Write-Log ($LogMsgs.messages.regPathDetail -replace '\{path\}', $RegistryPath) -Level "info"
    Write-Log ($LogMsgs.messages.regLabelDetail -replace '\{label\}', $Label) -Level "info"
    Write-Log ($LogMsgs.messages.regIconDetail -replace '\{icon\}', $IconValue) -Level "info"
    Write-Log ($LogMsgs.messages.regCommandDetail -replace '\{command\}', $CommandArg) -Level "info"

    $regPath = ConvertTo-RegPath $RegistryPath

    try {
        # Extract HKCR subkey path from the full registry path
        $subKeyPath = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

        # Set (Default) value = label
        Write-Log ("  " + ($LogMsgs.messages.settingRegistryDefault -replace '\{label\}', $Label)) -Level "info"
        $key = $hkcr.CreateSubKey($subKeyPath)
        $key.SetValue("", $Label)
        $key.Close()
        Write-Log ("  " + $LogMsgs.messages.registryDefaultSet) -Level "success"

        # Set Icon
        Write-Log ("  " + ($LogMsgs.messages.settingIcon -replace '\{icon\}', $IconValue)) -Level "info"
        $key = $hkcr.OpenSubKey($subKeyPath, $true)
        $key.SetValue("Icon", $IconValue)
        $key.Close()
        Write-Log ("  " + $LogMsgs.messages.iconSet) -Level "success"

        # Create command subkey with (Default) = command
        Write-Log ("  " + ($LogMsgs.messages.settingCommand -replace '\{command\}', $CommandArg)) -Level "info"
        $cmdKey = $hkcr.CreateSubKey("$subKeyPath\command")
        $cmdKey.SetValue("", $CommandArg)
        $cmdKey.Close()
        Write-Log ("  " + $LogMsgs.messages.commandSet) -Level "success"

        return $true
    } catch {
        Write-Log ("  " + ($LogMsgs.messages.registryFailed -replace '\{error\}', $_)) -Level "error"
        Write-Log ("  " + ($LogMsgs.messages.registryStack -replace '\{stack\}', $_.ScriptStackTrace)) -Level "error"
        return $false
    }
}

function Test-RegistryEntry {
    param(
        [string]$RegistryPath,
        [string]$Label,
        [PSObject]$LogMsgs
    )

    $regPath = ConvertTo-RegPath $RegistryPath
    Write-Log ("  " + ($LogMsgs.messages.verifyingEntry -replace '\{path\}', $regPath)) -Level "info"

    $out = reg.exe query $regPath 2>&1
    $isEntryFound = $LASTEXITCODE -eq 0
    if ($isEntryFound) {
        Write-Log ("  " + (($LogMsgs.messages.verifyPass -replace '\{label\}', $Label) -replace '\{path\}', $regPath)) -Level "success"
        return $true
    } else {
        Write-Log ("  " + (($LogMsgs.messages.verifyMiss -replace '\{label\}', $Label) -replace '\{path\}', $regPath)) -Level "error"
        return $false
    }
}

function Invoke-Edition {
    param(
        [PSCustomObject]$Edition,
        [string]$EditionName,
        [string]$InstallType,
        $Steps,
        [string]$ScriptDir
    )

    $logMsgs = Import-JsonConfig (Join-Path $ScriptDir "log-messages.json")

    Write-Host ""
    Write-Host $logMsgs.messages.editionBorderLine -ForegroundColor DarkCyan
    Write-Host ($logMsgs.messages.editionLabel -replace '\{label\}', $Edition.contextMenuLabel) -ForegroundColor Cyan
    Write-Host $logMsgs.messages.editionBorderLine -ForegroundColor DarkCyan

    # Resolve exe
    Write-Log $Steps.detectInstall -Level "info"
    $VsCodeExe = Resolve-VsCodePath -PathConfig $Edition.vscodePath -PreferredType $InstallType -ScriptDir $ScriptDir -EditionName $EditionName

    $isExeMissing = -not $VsCodeExe
    if ($isExeMissing) {
        Write-Log ($logMsgs.messages.exeNotFound -replace '\{label\}', $Edition.contextMenuLabel) -Level "warn"
        return $false
    }
    Write-Log ($logMsgs.messages.usingExe -replace '\{path\}', $VsCodeExe) -Level "success"

    # Persist resolved path to .resolved/ (not config.json)
    if ($ScriptDir) {
        Save-ResolvedPath -ScriptDir $ScriptDir -EditionName $EditionName -ResolvedExe $VsCodeExe
    }

    $Label   = $Edition.contextMenuLabel
    $IconVal = "`"$VsCodeExe`""

    # Define entries
    $entries = @(
        @{ Step = $Steps.regFile; Path = $Edition.registryPaths.file;       CmdArg = "`"$VsCodeExe`" `"%1`"" },
        @{ Step = $Steps.regDir;  Path = $Edition.registryPaths.directory;  CmdArg = "`"$VsCodeExe`" `"%V`"" },
        @{ Step = $Steps.regBg;   Path = $Edition.registryPaths.background; CmdArg = "`"$VsCodeExe`" `"%V`"" }
    )

    $isAllOk = $true

    # Register
    foreach ($entry in $entries) {
        $result = Register-ContextMenu `
            -StepLabel  $entry.Step `
            -RegistryPath $entry.Path `
            -Label      $Label `
            -IconValue  $IconVal `
            -CommandArg $entry.CmdArg `
            -LogMsgs    $logMsgs
        $hasFailed = -not $result
        if ($hasFailed) { $isAllOk = $false }
    }

    # Verify
    Write-Log $Steps.verify -Level "info"
    foreach ($entry in $entries) {
        $result = Test-RegistryEntry -RegistryPath $entry.Path -Label $entry.Step -LogMsgs $logMsgs
        $hasFailed = -not $result
        if ($hasFailed) { $isAllOk = $false }
    }

    return $isAllOk
}

function Uninstall-VsCodeContextMenu {
    <#
    .SYNOPSIS
        Removes VS Code context menu registry entries, purges tracking.
    #>
    param(
        $Config,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "VS Code Context Menu") -Level "info"

    # 1. Remove registry entries for each edition
    foreach ($editionName in $Config.enabledEditions) {
        $edition = $Config.editions.$editionName
        $isEditionValid = $null -ne $edition
        if ($isEditionValid) {
            foreach ($regKey in @($edition.registryPaths.file, $edition.registryPaths.directory, $edition.registryPaths.background)) {
                $hasKey = -not [string]::IsNullOrWhiteSpace($regKey)
                if ($hasKey) {
                    $isPresent = Test-Path $regKey -ErrorAction SilentlyContinue
                    if ($isPresent) {
                        Remove-Item -Path $regKey -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "Removed registry key: $regKey" -Level "success"
                        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
                            $null = Write-RegistryAuditEvent -Operation "remove" `
                                -Edition $editionName -Target "unknown" -RegPath $regKey `
                                -Reason "removed by uninstall"
                        }
                    } else {
                        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
                            $null = Write-RegistryAuditEvent -Operation "skip-absent" `
                                -Edition $editionName -Target "unknown" -RegPath $regKey `
                                -Reason "key already absent"
                        }
                    }
                }
            }
        }
    }

    # 2. Remove tracking records
    Remove-InstalledRecord -Name "vscode-context-menu"
    Remove-ResolvedData -ScriptFolder "10-vscode-context-menu-fix"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
