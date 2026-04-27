# --------------------------------------------------------------------------
#  fix-legacy-fixer-refs.ps1
#  One-command auto-fix: rewrites scripts-fixer-v8/v9/v10 -> scripts-fixer-v11
#  across every text file in the repo (including lockfiles).
#
#  Usage:
#    .\tools\fix-legacy-fixer-refs.ps1                  # apply changes
#    .\tools\fix-legacy-fixer-refs.ps1 -DryRun          # preview only
#    .\tools\fix-legacy-fixer-refs.ps1 -Target v11      # custom target
#    .\tools\fix-legacy-fixer-refs.ps1 -Versions 8,9,10 # custom legacy set
# --------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]   $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [int[]]    $Versions = @(8, 9, 10),
    [string]   $Target   = 'v11',
    [switch]   $DryRun
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

$skipDirs = @('.git', 'node_modules', 'dist', 'build', '.next', '.turbo',
              '.cache', 'coverage', '.lovable')
$skipExts = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf',
              '.zip', '.gz', '.tgz', '.7z', '.rar', '.exe', '.dll',
              '.bin', '.lockb', '.woff', '.woff2', '.ttf', '.otf',
              '.mp3', '.mp4', '.mov', '.wav')
$selfNames = @('fix-legacy-fixer-refs.ps1', 'fix-legacy-fixer-refs.sh',
               'scan-legacy-fixer-refs.ps1', 'scan-legacy-fixer-refs.sh')

$patterns = $Versions | ForEach-Object { "scripts-fixer-v$_" }

Write-Info "repo:     $RepoRoot"
Write-Info "rewrite:  $($patterns -join ', ') -> scripts-fixer-$Target"
Write-Info "mode:     $([string]::Format('{0}', $(if ($DryRun) {'dry-run'} else {'apply'})))"

$changedFiles = @()
$totalReplacements = 0
$errors = 0

$allFiles = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
        $parts = $rel -split '[\\/]'
        ($parts | Where-Object { $skipDirs -contains $_ }).Count -eq 0 -and
        ($skipExts -notcontains $_.Extension.ToLower()) -and
        ($selfNames -notcontains $_.Name)
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
if ($DryRun) { Write-WarnMsg 'dry-run: no files were modified' }

if ($errors -gt 0) { exit 2 }
if ($changedFiles.Count -eq 0) {
    Write-OkMsg 'nothing to fix - repo already clean'
    exit 0
}
if ($DryRun) { exit 0 }
Write-OkMsg "rewrote $totalReplacements occurrence(s) across $($changedFiles.Count) file(s)"
exit 0
