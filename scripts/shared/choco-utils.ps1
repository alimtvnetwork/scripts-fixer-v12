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

function Get-ChocoDiagnosticsDirectory {
    $logsRoot = $script:_LogsDir
    $hasLogsRoot = -not [string]::IsNullOrWhiteSpace($logsRoot)
    if (-not $hasLogsRoot) {
        $scriptsRoot = Split-Path -Parent $PSScriptRoot
        $projectRoot = Split-Path -Parent $scriptsRoot
        $logsRoot = Join-Path $projectRoot ".logs"
    }

    $diagnosticsDir = Join-Path $logsRoot "installers"
    if (-not (Test-Path -LiteralPath $diagnosticsDir)) {
        try {
            New-Item -Path $diagnosticsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-FileError -FilePath $diagnosticsDir -Operation "write" -Reason "Could not create installer diagnostics directory: $_" -Module "Get-ChocoDiagnosticsDirectory"
        }
    }

    return $diagnosticsDir
}

function Save-ChocoDiagnosticLog {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [int]$ExitCode,

        [bool]$TimedOut,

        [int]$TimeoutSeconds,

        [string]$Stdout,

        [string]$Stderr
    )

    $diagnosticsDir = Get-ChocoDiagnosticsDirectory
    $safeLabel = ($Label.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $diagnosticPath = Join-Path $diagnosticsDir "${stamp}-${safeLabel}.log"
    $commandLine = "choco.exe " + (($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $packageHint = ($ArgumentList | Where-Object { $_ -and $_ -notmatch '^-' } | Select-Object -Skip 1 -First 1)
    if ([string]::IsNullOrWhiteSpace($packageHint)) { $packageHint = "<package>" }
    $failureKind = if ($TimedOut) { "Timed out" } else { "Failed" }

    $content = @"
Chocolatey installer diagnostic log
===================================

Status: $failureKind
Label: $Label
Command: $commandLine
Exit code: $ExitCode
Timed out: $TimedOut
Timeout seconds: $TimeoutSeconds
Timestamp: $(Get-Date -Format "o")

Actionable troubleshooting steps
--------------------------------
1. Re-run the command manually in an elevated PowerShell window:
   $commandLine
2. If it pauses for input, re-run with a longer timeout:
   `$env:CHOCO_TIMEOUT_SECONDS=3600
3. Check whether another installer is open or Windows Installer is locked:
   Get-Process msiexec,choco -ErrorAction SilentlyContinue
4. Clear a stale Chocolatey lock if no Chocolatey process is running:
   Remove-Item "$env:ProgramData\chocolatey\lib-bad" -Recurse -Force -ErrorAction SilentlyContinue
5. Check Chocolatey's own logs:
   "$env:ProgramData\chocolatey\logs\chocolatey.log"
6. Verify network/package access:
   choco search $packageHint --exact --verbose

STDOUT
------
$Stdout

STDERR
------
$Stderr
"@

    try {
        Set-Content -Path $diagnosticPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop
        return $diagnosticPath
    } catch {
        Write-FileError -FilePath $diagnosticPath -Operation "write" -Reason "Could not write Chocolatey diagnostic log: $_" -Module "Save-ChocoDiagnosticLog"
        return $null
    }
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

            $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
            $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
            $diagnosticPath = Save-ChocoDiagnosticLog -Label $Label -ArgumentList $ArgumentList -ExitCode -1 -TimedOut $true -TimeoutSeconds $TimeoutSeconds -Stdout $stdout -Stderr $stderr

            Write-Log "[$Label] TIMED OUT after ${TimeoutSeconds}s -- Chocolatey process tree killed" -Level "error"
            if (-not [string]::IsNullOrWhiteSpace($diagnosticPath)) {
                Write-Log "[$Label] Detailed installer log: $diagnosticPath" -Level "error"
                Write-Log "[$Label] Next: open that log, then retry the printed command in elevated PowerShell or raise CHOCO_TIMEOUT_SECONDS" -Level "info"
            }
            return @{ Success = $false; TimedOut = $true; ExitCode = -1; Output = "Timed out after ${TimeoutSeconds}s. Detailed installer log: $diagnosticPath"; DiagnosticPath = $diagnosticPath }
        }

        $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $outputParts = @($stdout, $stderr)
        $output = (($outputParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
        $isSuccess = $process.ExitCode -eq 0
        $diagnosticPath = $null
        if (-not $isSuccess) {
            $diagnosticPath = Save-ChocoDiagnosticLog -Label $Label -ArgumentList $ArgumentList -ExitCode $process.ExitCode -TimedOut $false -TimeoutSeconds $TimeoutSeconds -Stdout $stdout -Stderr $stderr
            if (-not [string]::IsNullOrWhiteSpace($diagnosticPath)) {
                Write-Log "[$Label] Detailed installer log: $diagnosticPath" -Level "error"
                Write-Log "[$Label] Next: open that log, then retry the printed command in elevated PowerShell" -Level "info"
            }
        }

        return @{ Success = $isSuccess; TimedOut = $false; ExitCode = $process.ExitCode; Output = $output; Stdout = $stdout; Stderr = $stderr; DiagnosticPath = $diagnosticPath }
    } catch {
        Write-FileError -FilePath "choco.exe" -Operation "resolve" -Reason "Failed to start Chocolatey command '$Label': $_" -Module "Invoke-ChocoProcess"
        return @{ Success = $false; TimedOut = $false; ExitCode = -1; Output = $_.Exception.Message; DiagnosticPath = $null }
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
