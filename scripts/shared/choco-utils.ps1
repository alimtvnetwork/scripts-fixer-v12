<#
.SYNOPSIS
    Shared Chocolatey helpers: ensure installed, install/upgrade packages.
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

function Get-ChocoTimeoutSeconds {
    $defaultTimeout = 1800
    $rawTimeout = $env:CHOCO_TIMEOUT_SECONDS
    $hasOverride = -not [string]::IsNullOrWhiteSpace($rawTimeout)
    if ($hasOverride) {
        $parsedTimeout = 0
        $isValidOverride = [int]::TryParse($rawTimeout, [ref]$parsedTimeout) -and $parsedTimeout -gt 0
        if ($isValidOverride) {
            return $parsedTimeout
        }
    }

    return $defaultTimeout
}

function Invoke-ChocoProcess {
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$Label,

        [int]$TimeoutSeconds = (Get-ChocoTimeoutSeconds)
    )

    $tempRoot = [System.IO.Path]::GetTempPath()
    $runId = [System.Guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $tempRoot "choco-$runId.out.log"
    $stderrPath = Join-Path $tempRoot "choco-$runId.err.log"

    try {
        Write-Log "[$Label] Timeout guard: ${TimeoutSeconds}s" -Level "info"
        $process = Start-Process -FilePath "choco.exe" -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        $hasExited = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $hasExited) {
            try {
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            } catch {
                try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
            }

            Write-Log "[$Label] TIMED OUT after ${TimeoutSeconds}s -- Chocolatey process tree killed" -Level "error"
            return @{ Success = $false; TimedOut = $true; ExitCode = -1; Output = "Timed out after ${TimeoutSeconds}s" }
        }

        $outputParts = @()
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path $path) {
                $outputParts += (Get-Content -Path $path -Raw -ErrorAction SilentlyContinue)
            }
        }

        $output = (($outputParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
        return @{ Success = ($process.ExitCode -eq 0); TimedOut = $false; ExitCode = $process.ExitCode; Output = $output }
    } catch {
        Write-FileError -FilePath "choco.exe" -Operation "resolve" -Reason "Failed to start Chocolatey command '$Label': $_" -Module "Invoke-ChocoProcess"
        return @{ Success = $false; TimedOut = $false; ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path $path) {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Assert-Choco {
    <#
    .SYNOPSIS
        Ensures Chocolatey is installed. Installs it if missing.
        Returns $true if available after the check.
    #>

    $slm = $script:SharedLogMessages

    Write-Log $slm.messages.chocoChecking -Level "info"
    $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue

    if ($chocoCmd) {
        $version = & choco.exe --version 2>&1
        Write-Log ($slm.messages.chocoFound -replace '\{version\}', $version) -Level "success"
        return $true
    }

    Write-Log $slm.messages.chocoNotFound -Level "warn"
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

        # Refresh PATH for current session
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

        $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
        $isChocoAvailable = $null -ne $chocoCmd
        if ($isChocoAvailable) {
            Write-Log $slm.messages.chocoInstalled -Level "success"
            return $true
        }

        Write-Log $slm.messages.chocoNotInPath -Level "error"
        return $false
    } catch {
        Write-Log ($slm.messages.chocoInstallFailed -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Install-ChocoPackage {
    <#
    .SYNOPSIS
        Installs a Chocolatey package if not already installed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageName,

        [string]$Version,

        [string[]]$ExtraArgs = @()
    )

    $slm = $script:SharedLogMessages

    $isChocoReady = Assert-Choco
    $hasNoChoco = -not $isChocoReady
    if ($hasNoChoco) {
        return $false
    }

    Write-Log ($slm.messages.chocoCheckingPackage -replace '\{package\}', $PackageName) -Level "info"

    $installedResult = Invoke-ChocoProcess -ArgumentList @("list", "--local-only", "--exact", $PackageName) -Label "choco list $PackageName" -TimeoutSeconds 120
    $installed = $installedResult.Output
    $isAlreadyInstalled = $installedResult.Success -and $installed -match $PackageName
    if ($isAlreadyInstalled) {
        Write-Log ($slm.messages.chocoPackageInstalled -replace '\{package\}', $PackageName) -Level "success"
        return $true
    }

    Write-Log ($slm.messages.chocoInstallingPackage -replace '\{package\}', $PackageName) -Level "info"
    try {
        $args = @("install", $PackageName, "-y")
        $hasVersion = -not [string]::IsNullOrWhiteSpace($Version)
        if ($hasVersion) {
            $args += @("--version", $Version)
        }

        $hasExtraArgs = $null -ne $ExtraArgs -and $ExtraArgs.Count -gt 0
        if ($hasExtraArgs) {
            $args += $ExtraArgs
        }

        $result = Invoke-ChocoProcess -ArgumentList $args -Label "choco install $PackageName"
        $output = $result.Output
        $hasInstallFailed = -not $result.Success
        if ($hasInstallFailed) {
            Write-Log ($slm.messages.chocoPackageInstallFailed -replace '\{package\}', $PackageName -replace '\{output\}', $output) -Level "error"
            return $false
        }

        Write-Log ($slm.messages.chocoPackageInstallSuccess -replace '\{package\}', $PackageName) -Level "success"
        return $true
    } catch {
        Write-Log ($slm.messages.chocoPackageInstallError -replace '\{package\}', $PackageName -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Upgrade-ChocoPackage {
    <#
    .SYNOPSIS
        Upgrades a Chocolatey package to the latest version.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageName
    )

    $slm = $script:SharedLogMessages

    $isChocoReady = Assert-Choco
    $hasNoChoco = -not $isChocoReady
    if ($hasNoChoco) {
        return $false
    }

    Write-Log ($slm.messages.chocoUpgradingPackage -replace '\{package\}', $PackageName) -Level "info"
    try {
        $result = Invoke-ChocoProcess -ArgumentList @("upgrade", $PackageName, "-y") -Label "choco upgrade $PackageName"
        $output = $result.Output
        $hasUpgradeFailed = -not $result.Success
        if ($hasUpgradeFailed) {
            Write-Log ($slm.messages.chocoUpgradeFailed -replace '\{package\}', $PackageName -replace '\{output\}', $output) -Level "warn"
            return $false
        }

        Write-Log ($slm.messages.chocoUpgradeSuccess -replace '\{package\}', $PackageName) -Level "success"
        return $true
    } catch {
        Write-Log ($slm.messages.chocoUpgradeError -replace '\{package\}', $PackageName -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Uninstall-ChocoPackage {
    <#
    .SYNOPSIS
        Uninstalls a Chocolatey package.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageName
    )

    $slm = $script:SharedLogMessages

    $isChocoReady = Assert-Choco
    $hasNoChoco = -not $isChocoReady
    if ($hasNoChoco) {
        return $false
    }

    Write-Log "Uninstalling Chocolatey package: $PackageName" -Level "info"
    try {
        $result = Invoke-ChocoProcess -ArgumentList @("uninstall", $PackageName, "-y", "--remove-dependencies") -Label "choco uninstall $PackageName"
        $output = $result.Output
        $hasUninstallFailed = -not $result.Success
        if ($hasUninstallFailed) {
            Write-Log "Chocolatey uninstall failed for $PackageName : $output" -Level "error"
            return $false
        }

        Write-Log "Chocolatey package uninstalled: $PackageName" -Level "success"
        return $true
    } catch {
        Write-Log "Chocolatey uninstall error for $PackageName : $_" -Level "error"
        return $false
    }
}
