# --------------------------------------------------------------------------
#  Jenkins helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}


function Test-JavaPrerequisite {
    param(
        $Config,
        $LogMessages
    )

    $isJavaCheckDisabled = -not $Config.java.ensureInstalled
    if ($isJavaCheckDisabled) { return $true }

    $minVersion = [int]$Config.java.minVersion
    Write-Log ($LogMessages.messages.javaChecking -replace '\{minVersion\}', "$minVersion") -Level "info"

    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    $isJavaMissing = -not $javaCmd
    if ($isJavaMissing) {
        Write-Log ($LogMessages.messages.javaMissing -replace '\{minVersion\}', "$minVersion") -Level "error"
        return $false
    }

    $javaOutput = try { & java -version 2>&1 | Out-String } catch { "" }
    Write-Log ($LogMessages.messages.javaFound -replace '\{version\}', ($javaOutput.Trim() -replace "`r`n", " ")) -Level "info"

    # Parse major version: "openjdk version \"17.0.x\"" or "java version \"21.0.x\""
    $majorVersion = 0
    if ($javaOutput -match 'version\s+"(\d+)\.') {
        $majorVersion = [int]$matches[1]
    } elseif ($javaOutput -match 'version\s+"(\d+)"') {
        $majorVersion = [int]$matches[1]
    }

    $isVersionTooOld = $majorVersion -gt 0 -and $majorVersion -lt $minVersion
    if ($isVersionTooOld) {
        $msg = $LogMessages.messages.javaTooOld -replace '\{version\}', "$majorVersion" -replace '\{minVersion\}', "$minVersion"
        Write-Log $msg -Level "error"
        return $false
    }

    return $true
}

function Get-JenkinsVersion {
    # Try common install locations to read jenkins.war version
    $candidates = @(
        "${env:ProgramFiles}\Jenkins\jenkins.war",
        "${env:ProgramFiles(x86)}\Jenkins\jenkins.war"
    )
    foreach ($warPath in $candidates) {
        if (Test-Path $warPath) {
            $fileInfo = Get-Item $warPath
            return "Jenkins (war: $($fileInfo.LastWriteTime.ToString('yyyy-MM-dd')))"
        }
    }
    return $null
}

function Install-Jenkins {
    param(
        $Config,
        $LogMessages
    )

    $packageName = $Config.chocoPackageName
    $existingVersion = Get-JenkinsVersion
    $hasExisting = -not [string]::IsNullOrWhiteSpace($existingVersion)

    if ($hasExisting) {
        $isAlreadyTracked = Test-AlreadyInstalled -Name "jenkins" -CurrentVersion $existingVersion
        if ($isAlreadyTracked) {
            Write-Log ($LogMessages.messages.jenkinsAlreadyInstalled -replace '\{version\}', $existingVersion) -Level "info"
            return
        }

        Write-Log ($LogMessages.messages.jenkinsAlreadyInstalled -replace '\{version\}', $existingVersion) -Level "info"

        if ($Config.alwaysUpgradeToLatest) {
            try {
                Upgrade-ChocoPackage -PackageName $packageName
                $newVersion = Get-JenkinsVersion
                $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
                if ($isVersionEmpty) { $newVersion = "(version pending)" }
                Write-Log ($LogMessages.messages.jenkinsUpgradeSuccess -replace '\{version\}', $newVersion) -Level "success"
                Save-InstalledRecord -Name "jenkins" -Version "$newVersion".Trim()
            } catch {
                Write-Log "Jenkins upgrade failed: $_" -Level "error"
                Save-InstalledError -Name "jenkins" -ErrorMessage "$_"
            }
        }
    }
    else {
        Write-Log $LogMessages.messages.jenkinsNotFound -Level "info"
        try {
            Install-ChocoPackage -PackageName $packageName

            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            $installedVersion = Get-JenkinsVersion
            $isVersionEmpty = [string]::IsNullOrWhiteSpace($installedVersion)
            if ($isVersionEmpty) { $installedVersion = "(install pending)" }
            Write-Log ($LogMessages.messages.jenkinsInstallSuccess -replace '\{version\}', $installedVersion) -Level "success"
            Save-InstalledRecord -Name "jenkins" -Version $installedVersion
        } catch {
            Write-Log "Jenkins install failed: $_" -Level "error"
            Save-InstalledError -Name "jenkins" -ErrorMessage "$_"
        }
    }
}

function Test-JenkinsService {
    param(
        $Config,
        $LogMessages
    )

    $isVerifyDisabled = -not $Config.postInstall.verifyService
    if ($isVerifyDisabled) { return }

    Write-Log $LogMessages.messages.serviceChecking -Level "info"

    $serviceName = $Config.service.serviceName
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $isServiceMissing = -not $service
    if ($isServiceMissing) {
        Write-Log $LogMessages.messages.serviceMissing -Level "warn"
        return
    }

    $isRunning = $service.Status -eq 'Running'
    if ($isRunning) {
        Write-Log ($LogMessages.messages.serviceRunning -replace '\{port\}', "$($Config.port.default)") -Level "success"
        return
    }

    $shouldEnsureRunning = $Config.service.ensureRunning
    if (-not $shouldEnsureRunning) { return }

    Write-Log $LogMessages.messages.serviceStopped -Level "info"
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
        Write-Log $LogMessages.messages.serviceStarted -Level "success"
    } catch {
        Write-Log $LogMessages.messages.serviceStartFailed -Level "error"
    }
}

function Show-JenkinsInitialPassword {
    param(
        $Config,
        $LogMessages
    )

    $shouldShow = $Config.postInstall.showInitialAdminPasswordPath
    if (-not $shouldShow) { return }

    $candidates = @(
        (Join-Path $env:ProgramData "Jenkins\.jenkins\secrets\initialAdminPassword"),
        (Join-Path "${env:ProgramFiles}\Jenkins" "secrets\initialAdminPassword"),
        (Join-Path $env:USERPROFILE ".jenkins\secrets\initialAdminPassword")
    )

    $passwordPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    $isPasswordFound = -not [string]::IsNullOrWhiteSpace($passwordPath)

    if ($isPasswordFound) {
        Write-Log ($LogMessages.messages.initialPasswordPath -replace '\{path\}', $passwordPath) -Level "info"
        try {
            $pw = Get-Content $passwordPath -ErrorAction Stop -Raw
            Write-Log ($LogMessages.messages.initialPasswordValue -replace '\{password\}', $pw.Trim()) -Level "success"
        } catch {
            Write-Log "Failed to read initial password file: $passwordPath -- $_" -Level "warn"
        }
    } else {
        $defaultPath = $candidates[0]
        Write-Log ($LogMessages.messages.initialPasswordMissing -replace '\{path\}', $defaultPath) -Level "warn"
    }

    Write-Log ($LogMessages.messages.openUrl -replace '\{port\}', "$($Config.port.default)") -Level "info"
}

function Update-JenkinsPath {
    param(
        $Config,
        $LogMessages
    )

    $isPathUpdateDisabled = -not $Config.path.updateUserPath
    if ($isPathUpdateDisabled) { return }

    $candidates = @(
        "${env:ProgramFiles}\Jenkins",
        "${env:ProgramFiles(x86)}\Jenkins"
    )
    $jenkinsDir = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    $isJenkinsMissing = [string]::IsNullOrWhiteSpace($jenkinsDir)
    if ($isJenkinsMissing) { return }

    $isAlreadyInPath = Test-InPath -Directory $jenkinsDir
    if ($isAlreadyInPath) {
        Write-Log ($LogMessages.messages.pathAlreadyContains -replace '\{path\}', $jenkinsDir) -Level "info"
    } else {
        Write-Log ($LogMessages.messages.addingToPath -replace '\{path\}', $jenkinsDir) -Level "info"
        Add-ToUserPath -Directory $jenkinsDir
    }
}

function Uninstall-Jenkins {
    param(
        $Config,
        $LogMessages
    )

    Write-Log $LogMessages.messages.uninstalling -Level "info"

    # Stop the service first to avoid file-locks during uninstall
    $serviceName = $Config.service.serviceName
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $isRunning = $service -and $service.Status -eq 'Running'
    if ($isRunning) {
        try { Stop-Service -Name $serviceName -Force -ErrorAction Stop } catch {
            Write-Log "Failed to stop Jenkins service before uninstall: $_" -Level "warn"
        }
    }

    $isUninstalled = Uninstall-ChocoPackage -PackageName $Config.chocoPackageName
    if ($isUninstalled) {
        Write-Log $LogMessages.messages.uninstallSuccess -Level "success"
    } else {
        Write-Log $LogMessages.messages.uninstallFailed -Level "error"
    }

    Remove-InstalledRecord -Name "jenkins"
    Remove-ResolvedData -ScriptFolder "55-install-jenkins"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}