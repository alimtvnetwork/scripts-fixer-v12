<#
.SYNOPSIS
    Repairs the Windows folder context menu entries for Visual Studio Code.

.DESCRIPTION
    Creates a timestamped .reg backup and companion manifest before changing
    registry keys, then restores or repairs the VS Code folder right-click entries:

      - Right-click ON a folder:      HKCR\Directory\shell\VSCode
      - Right-click inside a folder: HKCR\Directory\Background\shell\VSCode

    Restore with either an explicit backup or the newest automatic backup:
      .\repair-vscode-folder-context-menu.ps1 -RestoreFromFile "C:\path\backup.reg"
      .\repair-vscode-folder-context-menu.ps1 -RestoreLatest

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-vscode-folder-context-menu.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-vscode-folder-context-menu.ps1 -WhatIf

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-vscode-folder-context-menu.ps1 -RestoreFromFile "$env:USERPROFILE\Desktop\vscode-context-menu-backups\vscode-context-menu-before-20260428-120000.reg"

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-vscode-folder-context-menu.ps1 -RestoreLatest
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Stable', 'Insiders')]
    [string]$Edition = 'Stable',

    [ValidateSet('Folder', 'Background', 'Both')]
    [string]$Target = 'Both',

    [string]$CodeExePath,

    [string]$BackupDir = (Join-Path $env:USERPROFILE 'Desktop\vscode-context-menu-backups'),

    [string]$RestoreFromFile,

    [switch]$RestoreLatest,

    [switch]$NoExplorerRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Message) Write-Host "[ INFO ] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[  OK  ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[ WARN ] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[ FAIL ] $Message" -ForegroundColor Red }

function Write-FileError {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string]$Reason
    )
    Write-Err "[CODE RED] File/path error: $FilePath -- Reason: $Reason"
}

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Assert-Elevated {
    if (Test-IsElevated) { return }
    Write-FileError -FilePath $PSCommandPath -Reason 'Registry writes under HKEY_CLASSES_ROOT require an elevated PowerShell session.'
    Write-Host ''
    Write-Host 'Retry from an Administrator PowerShell:' -ForegroundColor Yellow
    Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor White
    exit 87
}

function Resolve-CodeExe {
    param([string]$EditionName, [string]$OverridePath)

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        if (Test-Path -LiteralPath $OverridePath) { return (Resolve-Path -LiteralPath $OverridePath).Path }
        Write-FileError -FilePath $OverridePath -Reason 'Override Code.exe path does not exist.'
        exit 2
    }

    $exeName = if ($EditionName -eq 'Insiders') { 'Code - Insiders.exe' } else { 'Code.exe' }
    $folder = if ($EditionName -eq 'Insiders') { 'Microsoft VS Code Insiders' } else { 'Microsoft VS Code' }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\$folder\$exeName"),
        (Join-Path $env:ProgramFiles "$folder\$exeName"),
        (Join-Path ${env:ProgramFiles(x86)} "$folder\$exeName")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    Write-FileError -FilePath ($candidates -join ' | ') -Reason "Could not find $exeName. Install VS Code or pass -CodeExePath."
    exit 2
}

function Get-RegistryTargets {
    param([string]$EditionName, [string]$TargetName)

    $leaf = if ($EditionName -eq 'Insiders') { 'VSCodeInsiders' } else { 'VSCode' }
    $label = if ($EditionName -eq 'Insiders') { 'Open with Code - Insiders' } else { 'Open with Code' }
    $items = @()
    if ($TargetName -in @('Folder', 'Both')) {
        $items += [pscustomobject]@{ Name = 'Folder'; RegPath = "HKEY_CLASSES_ROOT\Directory\shell\$leaf"; PsPath = "Registry::HKEY_CLASSES_ROOT\Directory\shell\$leaf"; Label = $label; CommandArg = '%V' }
    }
    if ($TargetName -in @('Background', 'Both')) {
        $items += [pscustomobject]@{ Name = 'Background'; RegPath = "HKEY_CLASSES_ROOT\Directory\Background\shell\$leaf"; PsPath = "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\$leaf"; Label = $label; CommandArg = '%V' }
    }
    return $items
}

function New-ContextMenuBackup {
    param([object[]]$TargetsToBackup, [string]$OutputDir)

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        try { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
        catch { Write-FileError -FilePath $OutputDir -Reason "Could not create backup directory: $($_.Exception.Message)"; exit 3 }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $OutputDir "vscode-context-menu-before-$stamp.reg"
    $manifestPath = Join-Path $OutputDir "vscode-context-menu-before-$stamp.json"
    $rows = @()
    Set-Content -LiteralPath $backupPath -Value @(
        'Windows Registry Editor Version 5.00',
        '',
        "; VS Code context menu backup created $(Get-Date -Format o)",
        "; Restore with: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -RestoreFromFile `"$backupPath`"",
        ''
    ) -Encoding ASCII

    foreach ($item in $TargetsToBackup) {
        $tempFile = [IO.Path]::GetTempFileName()
        try {
            $null = reg.exe query $item.RegPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                Add-Content -LiteralPath $backupPath -Value "; $($item.RegPath) was absent before repair`r`n" -Encoding ASCII
                $rows += [pscustomobject]@{ Name = $item.Name; Path = $item.RegPath; Present = $false; Exported = $false; Reason = 'Key was absent before repair.' }
                continue
            }
            $null = reg.exe export $item.RegPath $tempFile /y 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-FileError -FilePath $item.RegPath -Reason "reg.exe export failed while writing backup $backupPath."
                $rows += [pscustomobject]@{ Name = $item.Name; Path = $item.RegPath; Present = $true; Exported = $false; Reason = "reg.exe export failed with exit code $LASTEXITCODE." }
                continue
            }
            Get-Content -LiteralPath $tempFile | Select-Object -Skip 1 | Add-Content -LiteralPath $backupPath -Encoding ASCII
            Add-Content -LiteralPath $backupPath -Value '' -Encoding ASCII
            $rows += [pscustomobject]@{ Name = $item.Name; Path = $item.RegPath; Present = $true; Exported = $true; Reason = 'Exported successfully.' }
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        [pscustomobject]@{
            CreatedAt = (Get-Date -Format o)
            BackupFile = $backupPath
            RestoreCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -RestoreFromFile `"$backupPath`""
            Keys = $rows
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    } catch {
        Write-FileError -FilePath $manifestPath -Reason "Could not write backup manifest: $($_.Exception.Message)"
    }

    Write-Ok "Backup written: $backupPath"
    Write-Ok "Backup manifest written: $manifestPath"
    return $backupPath
}

function Resolve-LatestContextMenuBackup {
    param([string]$OutputDir)
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        Write-FileError -FilePath $OutputDir -Reason 'Backup directory does not exist; run a repair first or pass -RestoreFromFile.'
        exit 4
    }
    $latest = Get-ChildItem -LiteralPath $OutputDir -Filter 'vscode-context-menu-before-*.reg' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        Write-FileError -FilePath (Join-Path $OutputDir 'vscode-context-menu-before-*.reg') -Reason 'No automatic context-menu backup was found.'
        exit 4
    }
    Write-Ok "Latest backup selected: $($latest.FullName)"
    return $latest.FullName
}

function Restore-ContextMenuBackup {
    param([string]$BackupPath, [object[]]$TargetsToRestore)
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Write-FileError -FilePath $BackupPath -Reason 'Restore file does not exist.'
        exit 4
    }
    Write-Info "Restoring registry backup: $BackupPath"
    if ($PSCmdlet.ShouldProcess($BackupPath, 'reg import')) {
        foreach ($item in $TargetsToRestore) {
            if (Test-Path -LiteralPath $item.PsPath) {
                try { Remove-Item -LiteralPath $item.PsPath -Recurse -Force }
                catch { Write-FileError -FilePath $item.RegPath -Reason "Could not clear current key before restore: $($_.Exception.Message)"; exit 4 }
            }
        }
        $output = reg.exe import $BackupPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-FileError -FilePath $BackupPath -Reason "reg import failed: $output"
            exit 4
        }
    }
    Write-Ok 'Restore completed.'
}

function Set-VsCodeContextMenuEntry {
    param([object]$Item, [string]$ExePath)

    $commandPath = Join-Path $Item.PsPath 'command'
    $iconValue = '"{0}"' -f $ExePath
    $commandValue = '"{0}" "{1}"' -f $ExePath, $Item.CommandArg

    Write-Info "Repairing $($Item.Name): $($Item.RegPath)"
    if ($PSCmdlet.ShouldProcess($Item.RegPath, 'create/update VS Code context menu entry')) {
        try {
            New-Item -Path $Item.PsPath -Force | Out-Null
            New-ItemProperty -Path $Item.PsPath -Name '(default)' -Value $Item.Label -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $Item.PsPath -Name 'Icon' -Value $iconValue -PropertyType String -Force | Out-Null
            New-Item -Path $commandPath -Force | Out-Null
            New-ItemProperty -Path $commandPath -Name '(default)' -Value $commandValue -PropertyType String -Force | Out-Null
            Write-Ok "$($Item.Name) context menu repaired."
        } catch {
            Write-FileError -FilePath $Item.RegPath -Reason "Registry write failed: $($_.Exception.Message)"
            exit 5
        }
    }
}

function Restart-ExplorerShell {
    if ($NoExplorerRestart) {
        Write-Warn 'Explorer restart skipped. Sign out/in or restart Explorer to refresh the menu.'
        return
    }
    Write-Info 'Restarting Explorer to refresh context menus...'
    try {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 900
        Start-Process explorer.exe | Out-Null
        Write-Ok 'Explorer restarted.'
    } catch {
        Write-Warn "Explorer restart failed: $($_.Exception.Message). Sign out/in to refresh manually."
    }
}

Assert-Elevated
$targets = Get-RegistryTargets -EditionName $Edition -TargetName $Target

if ($RestoreLatest -and -not [string]::IsNullOrWhiteSpace($RestoreFromFile)) {
    Write-FileError -FilePath $RestoreFromFile -Reason 'Use either -RestoreLatest or -RestoreFromFile, not both.'
    exit 4
}

if ($RestoreLatest -or -not [string]::IsNullOrWhiteSpace($RestoreFromFile)) {
    $restorePath = $RestoreFromFile
    if ($RestoreLatest) { $restorePath = Resolve-LatestContextMenuBackup -OutputDir $BackupDir }
    Restore-ContextMenuBackup -BackupPath $restorePath -TargetsToRestore $targets
    Restart-ExplorerShell
    return
}

$codeExe = Resolve-CodeExe -EditionName $Edition -OverridePath $CodeExePath
Write-Ok "VS Code executable: $codeExe"
$backup = New-ContextMenuBackup -TargetsToBackup $targets -OutputDir $BackupDir

foreach ($targetItem in $targets) {
    Set-VsCodeContextMenuEntry -Item $targetItem -ExePath $codeExe
}

Restart-ExplorerShell

Write-Host ''
Write-Ok 'VS Code folder context menu repair completed.'
Write-Host "Restore command:" -ForegroundColor Yellow
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -RestoreFromFile `"$backup`"" -ForegroundColor White