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

    $installed = choco list --local-only --exact $PackageName 2>&1
    $isAlreadyInstalled = $LASTEXITCODE -eq 0 -and $installed -match $PackageName
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

        $output = & choco.exe @args 2>&1
        $hasInstallFailed = $LASTEXITCODE -ne 0
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
        $output = & choco.exe upgrade $PackageName -y 2>&1
        $hasUpgradeFailed = $LASTEXITCODE -ne 0
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
        $output = & choco.exe uninstall $PackageName -y --remove-dependencies 2>&1
        $hasUninstallFailed = $LASTEXITCODE -ne 0
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
