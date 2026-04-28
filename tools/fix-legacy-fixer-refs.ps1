# --------------------------------------------------------------------------
#  fix-legacy-fixer-refs.ps1
#  One-command auto-fix: rewrites scripts-fixer-v12/v9/v10 -> scripts-fixer-v12
#  across every text file in the repo (including lockfiles).
#
#  Usage:
#    .\tools\fix-legacy-fixer-refs.ps1                  # apply changes
#    .\tools\fix-legacy-fixer-refs.ps1 -DryRun          # preview only
#    .\tools\fix-legacy-fixer-refs.ps1 -Target v11      # custom target
#    .\tools\fix-legacy-fixer-refs.ps1 -Versions 8,9,10 # custom legacy set
#    .\tools\fix-legacy-fixer-refs.ps1 -Paths tools,src # restrict to folders
#
#  Path filter:
#    -Paths   : repo-relative folders or files. When omitted/empty the entire
#               repo is rewritten (current behaviour). Each entry must exist or
#               the script aborts with a CODE RED file error.
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]   $RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [int[]]    $Versions    = @(8, 9, 10),
    [string]   $Target      = 'v11',
    [switch]   $DryRun,
    # JSON summary report. Pass an empty string to suppress, or a path
    # (relative paths resolve against -RepoRoot).
    [string]   $ReportFile  = 'legacy-fix-report.json',
    # Timestamped backups: when -Backup is set each rewritten file is copied
    # to <BackupRoot>\<BackupStamp>\<repo-relative-path> BEFORE being
    # overwritten. The chosen backup directory is also written to the JSON
    # report under "backupDir" so orchestrators can restore from it later.
    [switch]   $Backup,
    [string]   $BackupRoot  = '.legacy-fix-backups',
    [string]   $BackupStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'),
    [string[]] $Paths       = @()
)

$ErrorActionPreference = 'Stop'

function Write-Info ($m)    { Write-Host "[info ] $m" -ForegroundColor Cyan }
function Write-OkMsg ($m)   { Write-Host "[ ok  ] $m" -ForegroundColor Green }
function Write-WarnMsg($m)  { Write-Host "[warn ] $m" -ForegroundColor Yellow }
function Write-FailMsg($m)  { Write-Host "[fail ] $m" -ForegroundColor Red }
function Write-FileError($path, $reason) {
    Write-Host "[fail ] file=$path reason=$reason" -ForegroundColor Red
}

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Write-FileError $RepoRoot 'repo root does not exist'
    exit 2
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

# ---- Resolve & validate -Paths filter --------------------------------------
$pathFilters = @()
if ($Paths -and $Paths.Count -gt 0) {
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $clean = $p.Trim().TrimStart('.','\','/').TrimEnd('\','/')
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $clean = $clean -replace '/', '\'
        $abs   = Join-Path $RepoRoot $clean
        if (-not (Test-Path -LiteralPath $abs)) {
            Write-FileError $abs "path filter target does not exist (from -Paths '$p')"
            exit 2
        }
        $pathFilters += $clean.ToLower()
    }
}

$skipDirs = @('.git', 'node_modules', 'dist', 'build', '.next', '.turbo',
              '.cache', 'coverage', '.lovable', '.legacy-fix-backups')
$skipExts = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf',
              '.zip', '.gz', '.tgz', '.7z', '.rar', '.exe', '.dll',
              '.bin', '.lockb', '.woff', '.woff2', '.ttf', '.otf',
              '.mp3', '.mp4', '.mov', '.wav')
$selfNames = @('fix-legacy-fixer-refs.ps1', 'fix-legacy-fixer-refs.sh',
               'scan-legacy-fixer-refs.ps1', 'scan-legacy-fixer-refs.sh',
               'fix-and-verify-legacy-refs.ps1', 'fix-and-verify-legacy-refs.sh')
# Documentation files we never rewrite (they intentionally describe the migration).
$skipRelDocs = @('tools\readme.md', 'tools/readme.md')

$patterns = $Versions | ForEach-Object { "scripts-fixer-v$_" }

Write-Info "repo:     $RepoRoot"
Write-Info "rewrite:  $($patterns -join ', ') -> scripts-fixer-$Target"
if ($pathFilters.Count -gt 0) {
    Write-Info "paths:    $($pathFilters -join ', ')"
} else {
    Write-Info "paths:    (entire repo)"
}
Write-Info "mode:     $([string]::Format('{0}', $(if ($DryRun) {'dry-run'} else {'apply'})))"

# Resolve backup directory (only used when -Backup AND not -DryRun)
$backupDir    = $null
$backupActive = $false
if ($Backup -and -not $DryRun) {
    $backupBase = if ([System.IO.Path]::IsPathRooted($BackupRoot)) { $BackupRoot } else { Join-Path $RepoRoot $BackupRoot }
    $backupDir  = Join-Path $backupBase $BackupStamp
    try {
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $backupActive = $true
        Write-Info "backup:   $backupDir"
    } catch {
        Write-FileError $backupDir "cannot create backup directory: $($_.Exception.Message) -- aborting"
        exit 2
    }
}

$changedFiles = @()
$totalReplacements = 0
$errors = 0

$allFiles = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
        $relLower = $rel.ToLower()
        $parts = $rel -split '[\\/]'
        $passesSkip = (
            ($parts | Where-Object { $skipDirs -contains $_ }).Count -eq 0 -and
            ($skipExts -notcontains $_.Extension.ToLower()) -and
            ($selfNames -notcontains $_.Name) -and
            ($skipRelDocs -notcontains $relLower)
        )
        if (-not $passesSkip) { return $false }
        if ($pathFilters.Count -eq 0) { return $true }
        $relNorm = $relLower.Replace('/', '\')
        foreach ($pf in $pathFilters) {
            if ($relNorm -eq $pf -or $relNorm.StartsWith("$pf\")) { return $true }
        }
        return $false
    }

foreach ($file in $allFiles) {
    try {
        $original = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    } catch {
        Write-FileError $file.FullName "read failed: $($_.Exception.Message)"
        $errors++
        continue
    }
    if ([string]::IsNullOrEmpty($original)) { continue }
    if ($original -notmatch 'scripts-fixer-v(8|9|10)\b') { continue }

    $updated = $original
    $fileReplacements = 0
    foreach ($p in $patterns) {
        $regex = [regex]"\b$([regex]::Escape($p))\b"
        $matches = $regex.Matches($updated)
        if ($matches.Count -gt 0) {
            $fileReplacements += $matches.Count
            $updated = $regex.Replace($updated, "scripts-fixer-$Target")
        }
    }

    if ($fileReplacements -gt 0) {
        $rel = $file.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
        $changedFiles += [pscustomobject]@{ Path = $rel; Count = $fileReplacements }
        $totalReplacements += $fileReplacements

        if (-not $DryRun) {
            # Timestamped backup BEFORE we touch the file. Backup failure
            # is fatal for that file (we never want a half-baked rollback set).
            if ($backupActive) {
                $bdest = Join-Path $backupDir $rel
                $bdir  = Split-Path -Parent $bdest
                try {
                    if ($bdir -and -not (Test-Path -LiteralPath $bdir)) {
                        New-Item -ItemType Directory -Path $bdir -Force -ErrorAction Stop | Out-Null
                    }
                    Copy-Item -LiteralPath $file.FullName -Destination $bdest -Force -ErrorAction Stop
                } catch {
                    Write-FileError $bdest "backup copy failed (source: $($file.FullName)): $($_.Exception.Message)"
                    $errors++
                    continue
                }
            }
            try {
                # Preserve original encoding best-effort: write as UTF8 no BOM
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($file.FullName, $updated, $utf8NoBom)
            } catch {
                Write-FileError $file.FullName "write failed: $($_.Exception.Message)"
                $errors++
            }
        }
    }
}

Write-Host ''
Write-Host '========== summary ==========' -ForegroundColor Magenta
foreach ($c in $changedFiles) {
    Write-Host ("  {0,4}x  {1}" -f $c.Count, $c.Path)
}
Write-Host '-----------------------------'
Write-Host ("files changed:    {0}" -f $changedFiles.Count)
Write-Host ("total rewrites:   {0}" -f $totalReplacements)
Write-Host ("errors:           {0}" -f $errors)

# ---- JSON report ------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($ReportFile)) {
    $reportPath = if ([System.IO.Path]::IsPathRooted($ReportFile)) {
        $ReportFile
    } else {
        Join-Path $RepoRoot $ReportFile
    }
    try {
        $reportDir = Split-Path -Parent $reportPath
        if ($reportDir -and -not (Test-Path -LiteralPath $reportDir)) {
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        }
        $report = [ordered]@{
            tool           = 'fix-legacy-fixer-refs.ps1'
            generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            repoRoot       = $RepoRoot
            mode           = $(if ($DryRun) { 'dry-run' } else { 'apply' })
            target         = "scripts-fixer-$Target"
            legacyVersions = $Versions
            backupDir      = $backupDir   # $null when -Backup was not set
            totals         = [ordered]@{
                filesChanged      = $changedFiles.Count
                totalReplacements = $totalReplacements
                errors            = $errors
            }
            files          = @($changedFiles | ForEach-Object {
                [ordered]@{ path = $_.Path; count = $_.Count }
            })
        }
        $json = $report | ConvertTo-Json -Depth 6
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($reportPath, $json, $utf8NoBom)
        Write-Info "report:   $reportPath"
    } catch {
        Write-FileError $reportPath "report write failed: $($_.Exception.Message)"
    }
}

if ($DryRun) { Write-WarnMsg 'dry-run: no files were modified' }

if ($errors -gt 0) { exit 2 }
if ($changedFiles.Count -eq 0) {
    Write-OkMsg 'nothing to fix - repo already clean'
    exit 0
}
if ($DryRun) { exit 0 }
Write-OkMsg "rewrote $totalReplacements occurrence(s) across $($changedFiles.Count) file(s)"
exit 0
