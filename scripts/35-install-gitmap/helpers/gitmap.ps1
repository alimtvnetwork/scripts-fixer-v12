# --------------------------------------------------------------------------
#  Helper -- GitMap CLI installer
#  Uses the remote install.ps1 from GitHub to install gitmap.
#  Integrates with devDir resolution for folder-specific installs.
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_devDirPath = Join-Path $_sharedDir "dev-dir.ps1"
if ((Test-Path $_devDirPath) -and -not (Get-Command Resolve-DevDir -ErrorAction SilentlyContinue)) {
    . $_devDirPath
}

function Test-GitmapInstalled {
    $cmd = Get-Command "gitmap" -ErrorAction SilentlyContinue
    $isInPath = $null -ne $cmd
    if ($isInPath) { return $true }

    # Check default install location
    $defaultPaths = @(
        "$env:LOCALAPPDATA\gitmap\gitmap.exe",
        "C:\dev-tool\GitMap\gitmap.exe"
    )

    # Also check devDir-resolved path if DEV_DIR is set
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($env:DEV_DIR)
    if ($hasDevDir) {
        $devDirGitmap = Join-Path $env:DEV_DIR "GitMap\gitmap.exe"
        $defaultPaths += $devDirGitmap
    }

    foreach ($p in $defaultPaths) {
        $isPresent = Test-Path $p
        if ($isPresent) { return $true }
    }

    return $false
}

function Save-GitmapResolvedState {
    param(
        [string]$InstallDir = ""
    )
    Save-ResolvedData -ScriptFolder "35-install-gitmap" -Data @{
        resolvedAt  = (Get-Date -Format "o")
        resolvedBy  = $env:USERNAME
        installDir  = $InstallDir
    }
}

function Resolve-GitmapInstallDir {
    <#
    .SYNOPSIS
        Resolves the GitMap install directory using devDir config.
        Priority: gitmap.installDir override > devDir resolution > config default.
    #>
    param(
        [PSCustomObject]$GitmapConfig,
        [PSCustomObject]$DevDirConfig
    )

    # 1. Explicit installDir override in gitmap config
    $hasInstallDir = -not [string]::IsNullOrWhiteSpace($GitmapConfig.installDir)
    if ($hasInstallDir) {
        return $GitmapConfig.installDir
    }

    # 2. Resolve via devDir system (env var, smart detection, etc.)
    $devDir = Resolve-DevDir -DevDirConfig $DevDirConfig
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($devDir)
    if ($hasDevDir) {
        return Join-Path $devDir "GitMap"
    }

    # 3. Fallback to config default
    $hasDefault = -not [string]::IsNullOrWhiteSpace($DevDirConfig.default)
    if ($hasDefault) {
        return $DevDirConfig.default
    }

    return "C:\dev-tool\GitMap"
}

function Get-GitmapVersion {
    <#
    .SYNOPSIS
        Returns the installed gitmap version string, or $null if not found.
    #>
    try {
        $candidates = @("gitmap")
        $commonPaths = @(
            "$env:LOCALAPPDATA\gitmap\gitmap.exe",
            "C:\dev-tool\GitMap\gitmap.exe"
        )
        if (-not [string]::IsNullOrWhiteSpace($env:DEV_DIR)) {
            $commonPaths += (Join-Path $env:DEV_DIR "GitMap\gitmap.exe")
        }
        $candidates += @($commonPaths | Where-Object { Test-Path $_ })

        foreach ($candidate in $candidates) {
            foreach ($arg in @("version", "--version")) {
                $raw = & $candidate $arg 2>&1
                $isValid = -not [string]::IsNullOrWhiteSpace($raw)
                if ($isValid) { return (($raw | Out-String) -replace '^\s*gitmap\s*', '').Trim() }
            }
        }
    } catch { }
    return $null
}

function ConvertTo-GitmapVersionKey {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $match = [regex]::Match($Version, 'v?(\d+(?:\.\d+){0,3})')
    if (-not $match.Success) { return $null }

    $parts = @($match.Groups[1].Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Compare-GitmapVersions {
    param(
        [string]$InstalledVersion,
        [string]$RemoteVersion
    )

    $installedKey = ConvertTo-GitmapVersionKey -Version $InstalledVersion
    $remoteKey = ConvertTo-GitmapVersionKey -Version $RemoteVersion
    if ($null -eq $installedKey -or $null -eq $remoteKey) { return $null }

    return $installedKey.CompareTo($remoteKey)
}

function Get-GitmapRemoteVersion {
    param([PSCustomObject]$GitmapConfig)

    $repo = $GitmapConfig.repo
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    try {
        Write-Log "Checking latest GitMap release: $apiUrl" -Level "info"
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -Headers @{ "User-Agent" = "scripts-fixer-gitmap" } -TimeoutSec 20
        if (-not [string]::IsNullOrWhiteSpace($release.tag_name)) { return $release.tag_name }
    } catch {
        Write-FileError -FilePath $apiUrl -Operation "read" -Reason "Could not resolve latest GitMap release: $_" -Module "Get-GitmapRemoteVersion"
    }

    $tagUrl = "https://api.github.com/repos/$repo/tags"
    try {
        Write-Log "Latest release unavailable -- checking GitMap tags: $tagUrl" -Level "warn"
        $tags = Invoke-RestMethod -Uri $tagUrl -UseBasicParsing -Headers @{ "User-Agent" = "scripts-fixer-gitmap" } -TimeoutSec 20
        $versions = @($tags | Where-Object { $_.name } | ForEach-Object {
            $key = ConvertTo-GitmapVersionKey -Version $_.name
            if ($null -ne $key) { [PSCustomObject]@{ Name = $_.name; Key = $key } }
        })
        if ($versions.Count -gt 0) {
            return ($versions | Sort-Object Key -Descending | Select-Object -First 1).Name
        }
    } catch {
        Write-FileError -FilePath $tagUrl -Operation "read" -Reason "Could not resolve latest GitMap tag: $_" -Module "Get-GitmapRemoteVersion"
    }

    return $null
}

function Install-GitmapViaZip {
    <#
    .SYNOPSIS
        Fallback installer: downloads a tagged release ZIP from GitHub,
        extracts the binary to the install directory, and adds it to PATH.
        Returns $true on success, $false on failure.
    #>
    param(
        [string]$InstallDir,
        [PSCustomObject]$GitmapConfig,
        $LogMessages
    )

    # Build ZIP URL from config template
    $tag = $GitmapConfig.fallbackTag
    $hasTag = -not [string]::IsNullOrWhiteSpace($tag)
    if (-not $hasTag) { $tag = "latest" }

    $zipUrlTemplate = $GitmapConfig.releaseZipUrl
    $hasTemplate = -not [string]::IsNullOrWhiteSpace($zipUrlTemplate)
    if (-not $hasTemplate) {
        $zipUrlTemplate = "https://github.com/$($GitmapConfig.repo)/releases/download/{tag}/gitmap-windows-amd64.zip"
    }

    # For "latest", resolve the redirect to get the actual tag
    $isLatest = $tag -eq "latest"
    if ($isLatest) {
        $apiUrl = "https://api.github.com/repos/$($GitmapConfig.repo)/releases/latest"
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -Headers @{ "User-Agent" = "gitmap-installer" }
            $tag = $release.tag_name
        } catch {
            # If API fails, try direct download URL pattern
            $zipUrl = "https://github.com/$($GitmapConfig.repo)/releases/latest/download/gitmap-windows-amd64.zip"
            Write-Log "Could not resolve latest tag, trying direct URL: $zipUrl" -Level "warn"
        }
    }

    # Build final URL if not already set by latest-fallback
    $hasZipUrl = -not [string]::IsNullOrWhiteSpace($zipUrl)
    if (-not $hasZipUrl) {
        $zipUrl = $zipUrlTemplate -replace '\{tag\}', $tag
    }

    Write-Log ($LogMessages.messages.downloadingZip -replace '\{url\}', $zipUrl) -Level "info"

    $tempZip  = Join-Path $env:TEMP "gitmap-release.zip"
    $tempDir  = Join-Path $env:TEMP "gitmap-extract"

    try {
        # Download ZIP
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing

        # Clean previous extract
        $hasTempDir = Test-Path $tempDir
        if ($hasTempDir) { Remove-Item $tempDir -Recurse -Force }

        # Extract
        Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
        Write-Log ($LogMessages.messages.zipExtracted -replace '\{path\}', $tempDir) -Level "info"

        # Ensure install directory exists
        $hasInstallDir = Test-Path $InstallDir
        if (-not $hasInstallDir) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        # Copy binary -- handle nested folder structure
        $exeFiles = Get-ChildItem -Path $tempDir -Recurse -Filter "gitmap.exe"
        $hasExe = $exeFiles.Count -gt 0
        if ($hasExe) {
            Copy-Item -Path $exeFiles[0].FullName -Destination (Join-Path $InstallDir "gitmap.exe") -Force
        } else {
            # Copy everything if no specific exe found
            Copy-Item -Path "$tempDir\*" -Destination $InstallDir -Recurse -Force
        }

        # Add to user PATH if not already there
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $isInPath = $userPath -split ";" | Where-Object { $_ -eq $InstallDir }
        $isAlreadyInPath = $null -ne $isInPath -and @($isInPath).Count -gt 0
        if (-not $isAlreadyInPath) {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        }

        return $true

    } catch {
        $errMsg   = $_.Exception.Message
        $errStack = $_.ScriptStackTrace
        Write-FileError -FilePath $zipUrl -Operation "zip-fallback" -Reason "ZIP download/extract failed: $errMsg" -Module "Install-GitmapViaZip"
        Write-Log ($LogMessages.messages.zipFallbackFailed -replace '\{error\}', $errMsg) -Level "error"
        Write-Log "Stack trace: $errStack" -Level "error"
        return $false
    } finally {
        # Cleanup temp files
        $hasTempZip = Test-Path $tempZip
        if ($hasTempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        $hasTempDir = Test-Path $tempDir
        if ($hasTempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Gitmap {
    <#
    .SYNOPSIS
        Installs gitmap CLI via the remote install.ps1 from GitHub.
        Uses devDir resolution for the install directory.
        Returns $true on success, $false on failure.
    #>
    param(
        [PSCustomObject]$GitmapConfig,
        [PSCustomObject]$DevDirConfig,
        $LogMessages
    )

    $isDisabled = -not $GitmapConfig.enabled
    if ($isDisabled) {
        Write-Log $LogMessages.messages.disabled -Level "info"
        return $true
    }

    Write-Log $LogMessages.messages.checking -Level "info"

    # Resolve install directory FIRST -- log it prominently before anything else
    $installDir = Resolve-GitmapInstallDir -GitmapConfig $GitmapConfig -DevDirConfig $DevDirConfig
    Write-Host ""
    Write-Log ($LogMessages.messages.installDir -replace '\{path\}', $installDir) -Level "success"
    Write-Host ""

    $isGitmapReady = Test-GitmapInstalled
    $remoteVersion = Get-GitmapRemoteVersion -GitmapConfig $GitmapConfig
    if ($isGitmapReady) {
        $ver = Get-GitmapVersion
        $hasVersion = -not [string]::IsNullOrWhiteSpace($ver)
        if ($hasVersion) {
            Write-Log ($LogMessages.messages.foundVersion -replace '\{version\}', $ver) -Level "success"
        } else {
            Write-Log $LogMessages.messages.found -Level "success"
        }

        if (-not [string]::IsNullOrWhiteSpace($remoteVersion)) {
            Write-Log "Latest remote GitMap version: $remoteVersion" -Level "info"
            $comparison = Compare-GitmapVersions -InstalledVersion $ver -RemoteVersion $remoteVersion
            if ($null -ne $comparison -and $comparison -ge 0) {
                Write-Log "GitMap is up to date (installed: $ver, remote: $remoteVersion) -- installer skipped" -Level "success"
                Save-GitmapResolvedState -InstallDir $installDir
                return $true
            }
            if ($null -ne $comparison -and $comparison -lt 0) {
                Write-Log "GitMap update available (installed: $ver, remote: $remoteVersion) -- running installer" -Level "info"
            } else {
                Write-Log "Could not compare GitMap versions (installed: $ver, remote: $remoteVersion) -- running installer to be safe" -Level "warn"
            }
        } else {
            Write-Log "Could not resolve remote GitMap version -- installed GitMap kept, installer skipped" -Level "warn"
            Save-GitmapResolvedState -InstallDir $installDir
            return $true
        }
    } else {
        Write-Log $LogMessages.messages.notFound -Level "info"
        if (-not [string]::IsNullOrWhiteSpace($remoteVersion)) {
            Write-Log "Latest remote GitMap version: $remoteVersion" -Level "info"
        }
    }

    Write-Log $LogMessages.messages.downloadingInstaller -Level "info"

    $isRemoteSuccess = $true
    try {
        Write-Log $LogMessages.messages.runningInstaller -Level "info"

        # Canonical one-liner: irm <install.ps1> | iex
        # We invoke the same way the README documents it so behaviour matches
        # what users see when they run the bare one-liner. install.ps1
        # honours $env:GITMAP_INSTALL_DIR for non-default targets.
        Write-Log "Invoking: irm $($GitmapConfig.installUrl) | iex" -Level "info"
        $env:GITMAP_INSTALL_DIR = $installDir
        $installerScript = Invoke-RestMethod -Uri $GitmapConfig.installUrl -UseBasicParsing
        Invoke-Expression $installerScript

    } catch {
        $errMsg   = $_.Exception.Message
        $errStack = $_.ScriptStackTrace
        Write-FileError -FilePath $GitmapConfig.installUrl -Operation "remote-install" -Reason "Remote installer failed: $errMsg" -Module "Install-Gitmap"
        Write-Log ($LogMessages.messages.installFailed -replace '\{error\}', $errMsg) -Level "error"
        Write-Log "Stack trace: $errStack" -Level "error"
        $isRemoteSuccess = $false
    }

    # If remote installer failed or gitmap still not found, try ZIP fallback
    if (-not $isRemoteSuccess) {
        Write-Log $LogMessages.messages.remoteInstallerFailed -Level "warn"
        $isZipSuccess = Install-GitmapViaZip -InstallDir $installDir -GitmapConfig $GitmapConfig -LogMessages $LogMessages
        if (-not $isZipSuccess) {
            return $false
        }
    }

    # Refresh PATH
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

    $isGitmapReady = Test-GitmapInstalled
    if ($isGitmapReady) {
        $ver = Get-GitmapVersion
        $hasVersion = -not [string]::IsNullOrWhiteSpace($ver)
        if ($hasVersion) {
            Write-Log ($LogMessages.messages.installSuccessVersion -replace '\{version\}', $ver) -Level "success"
        } else {
            Write-Log $LogMessages.messages.installSuccess -Level "success"
        }
        Save-GitmapResolvedState -InstallDir $installDir
    } else {
        Write-Log $LogMessages.messages.notInPath -Level "warn"
        Save-GitmapResolvedState -InstallDir $installDir
    }

    return $true
}

function Uninstall-Gitmap {
    <#
    .SYNOPSIS
        Full GitMap uninstall: remove install directory, purge tracking.
    #>
    param(
        $GitmapConfig,
        $DevDirConfig,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "GitMap") -Level "info"

    # 1. Remove from PATH and delete install directory
    $installDir = $GitmapConfig.installDir
    $hasInstallDir = -not [string]::IsNullOrWhiteSpace($installDir)
    if ($hasInstallDir -and (Test-Path $installDir)) {
        Remove-FromUserPath -Directory $installDir
        Write-Log "Removing install directory: $installDir" -Level "info"
        Remove-Item -Path $installDir -Recurse -Force
        Write-Log "Install directory removed: $installDir" -Level "success"
    }

    # 2. Remove tracking records
    Remove-InstalledRecord -Name "gitmap"
    Remove-ResolvedData -ScriptFolder "35-install-gitmap"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
