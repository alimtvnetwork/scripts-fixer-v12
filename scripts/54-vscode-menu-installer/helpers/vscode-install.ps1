<#
.SYNOPSIS
    Install logic for the VS Code menu installer (script 54).

.DESCRIPTION
    Writes the three context menu registry keys per edition (file, folder,
    folder background). Does NOT enumerate or touch any other registry
    location. Caller passes the resolved VS Code executable path.
#>

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Audit logger -- side-by-side helper. Loaded once; safe to dot-source again.
$_auditPath = Join-Path $PSScriptRoot "audit-log.ps1"
if ((Test-Path $_auditPath) -and -not (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue)) {
    . $_auditPath
}

function Get-HkcrSubkeyPath {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function ConvertTo-RegExePath {
    param([string]$PsPath)
    $p = $PsPath -replace '^Registry::', ''
    return ($p -replace '^HKEY_CLASSES_ROOT', 'HKCR')
}

function Resolve-ConfirmShellExe {
    <#
    .SYNOPSIS
        Best-effort lookup of pwsh.exe (preferred) then powershell.exe.
        Mirrors script 53's resolver but kept self-contained so script 54
        does not depend on script 53's helpers.
    #>
    param(
        [string]$Preferred = "pwsh",
        [string]$LegacyPath = "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    )
    if ($Preferred -eq "pwsh") {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        foreach ($p in @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "$env:ProgramFiles\PowerShell\6\pwsh.exe",
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
        )) {
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    $legacy = [System.Environment]::ExpandEnvironmentVariables($LegacyPath)
    if (Test-Path -LiteralPath $legacy) { return $legacy }
    return $null
}

function Register-VsCodeMenuEntry {
    <#
    .SYNOPSIS
        Writes a single context menu entry: parent key with (Default)+Icon,
        and a \command subkey with the command line.

    .PARAMETER ConfirmCfg
        Optional config.confirmBeforeLaunch block. When .enabled is true the
        raw command line is wrapped in a pwsh call to Invoke-ConfirmedLaunch
        (the same helper used by script 53). When omitted or disabled, the
        direct command line from the template is written unchanged.
    #>
    param(
        [string]$TargetName,         # "file" | "directory" | "background"
        [string]$RegistryPath,       # full Registry:: path from config
        [string]$Label,              # menu label
        [string]$VsCodeExe,          # resolved exe path
        [string]$CommandTemplate,    # template with {exe}
        [string]$RepoRoot,           # repo root for confirm-launch wrapper
        $ConfirmCfg,                 # optional confirmBeforeLaunch block
        $LogMsgs,
        [string]$EditionName = ""    # for audit log scoping; optional
    )

    $rawCmd = $CommandTemplate -replace '\{exe\}', $VsCodeExe
    $cmdLine = $rawCmd

    $isConfirmEnabled = ($null -ne $ConfirmCfg) -and ($ConfirmCfg.PSObject.Properties.Name -contains 'enabled') -and $ConfirmCfg.enabled
    if ($isConfirmEnabled) {
        $shellExe = Resolve-ConfirmShellExe -Preferred $ConfirmCfg.shellPreferred -LegacyPath $ConfirmCfg.shellLegacyPath
        $isShellMissing = -not $shellExe
        if ($isShellMissing) {
            Write-Log ("confirmBeforeLaunch enabled but no PowerShell exe resolved -- falling back to direct launch for: " + $RegistryPath) -Level "warn"
        } else {
            $leafLabel = "$Label ($TargetName)"
            # Escape single quotes for safe embedding inside a PS single-quoted string literal
            $innerEscaped = $rawCmd.Replace("'", "''")
            $wrapped = $ConfirmCfg.wrapperTemplate
            $wrapped = $wrapped.Replace('{shellExe}',     $shellExe)
            $wrapped = $wrapped.Replace('{repoRoot}',     $RepoRoot)
            $wrapped = $wrapped.Replace('{leafLabel}',    $leafLabel)
            $wrapped = $wrapped.Replace('{countdown}',    [string]$ConfirmCfg.countdownSeconds)
            $wrapped = $wrapped.Replace('{innerCommand}', $innerEscaped)
            $cmdLine = $wrapped
        }
    }

    Write-Log (($LogMsgs.messages.writingTarget -replace '\{target\}', $TargetName) -replace '\{path\}', $RegistryPath) -Level "info"
    Write-Log ($LogMsgs.messages.writingCommand -replace '\{command\}', $cmdLine) -Level "info"

    try {
        $sub  = Get-HkcrSubkeyPath $RegistryPath
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

        $key = $hkcr.CreateSubKey($sub)
        $key.SetValue("",     $Label)
        $key.SetValue("Icon", "`"$VsCodeExe`"")
        $key.Close()

        $cmdKey = $hkcr.CreateSubKey("$sub\command")
        $cmdKey.SetValue("", $cmdLine)
        $cmdKey.Close()

        Write-Log ($LogMsgs.messages.writeOk -replace '\{path\}', $RegistryPath) -Level "success"

        # Audit: record the exact key + values that were just written.
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "add" `
                -Edition $EditionName -Target $TargetName -RegPath $RegistryPath `
                -Values @{ "(Default)" = $Label; "Icon" = "`"$VsCodeExe`""; "command" = $cmdLine }
        }

        return $true
    } catch {
        $msg = ($LogMsgs.messages.writeFailed -replace '\{path\}', $RegistryPath) -replace '\{error\}', $_
        Write-Log $msg -Level "error"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "fail" `
                -Edition $EditionName -Target $TargetName -RegPath $RegistryPath `
                -Reason ("write failed: " + $_.Exception.Message)
        }
        return $false
    }
}

function Test-VsCodeMenuEntry {
    param(
        [string]$TargetName,
        [string]$RegistryPath,
        $LogMsgs
    )

    $regPath = ConvertTo-RegExePath $RegistryPath
    $null = reg.exe query $regPath 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)
    if ($isPresent) {
        Write-Log ((($LogMsgs.messages.verifyPass -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "success"
        return $true
    }
    Write-Log ((($LogMsgs.messages.verifyMiss -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "error"
    return $false
}

function Resolve-VsCodeExecutable {
    <#
    .SYNOPSIS
        Resolves the VS Code exe for an edition.
        Override > config path expansion.
    #>
    param(
        [string]$EditionName,
        [string]$ConfigPath,
        [string]$Override,
        $LogMsgs
    )

    Write-Log ($LogMsgs.messages.resolvingExe -replace '\{name\}', $EditionName) -Level "info"

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        Write-Log ($LogMsgs.messages.exeOverride -replace '\{path\}', $Override) -Level "info"
        $isOverridePresent = Test-Path -LiteralPath $Override
        if ($isOverridePresent) {
            Write-Log ($LogMsgs.messages.exeOk -replace '\{path\}', $Override) -Level "success"
            return $Override
        }
        $msg = ($LogMsgs.messages.exeMissing -replace '\{path\}', $Override) -replace '\{name\}', $EditionName
        Write-Log $msg -Level "error"
        return $null
    }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($ConfigPath)
    Write-Log ($LogMsgs.messages.exeFromConfig -replace '\{path\}', $expanded) -Level "info"
    $isPresent = Test-Path -LiteralPath $expanded
    if (-not $isPresent) {
        $msg = ($LogMsgs.messages.exeMissing -replace '\{path\}', $expanded) -replace '\{name\}', $EditionName
        Write-Log $msg -Level "error"
        return $null
    }
    Write-Log ($LogMsgs.messages.exeOk -replace '\{path\}', $expanded) -Level "success"
    return $expanded
}
