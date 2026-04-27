# --------------------------------------------------------------------------
#  scan-legacy-fixer-refs.ps1
#  Scans the repo for any leftover references to legacy scripts-fixer
#  generations (v8, v9, v10) that should have been migrated to v11.
#
#  Usage:
#    .\tools\scan-legacy-fixer-refs.ps1
#    .\tools\scan-legacy-fixer-refs.ps1 -Versions 8,9,10,11
#    .\tools\scan-legacy-fixer-refs.ps1 -Root "D:\scripts-fixer"
#
#  Exit codes:
#    0 = PASS (no matches)
#    1 = FAIL (matches found)
#    2 = error (bad path, etc. -- always logs exact path + reason)
# --------------------------------------------------------------------------
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)),
    [int[]]$Versions = @(8, 9, 10),
    [string[]]$ExcludeDirs = @('.git', 'node_modules', 'dist', 'build', '.next', '.lovable\compliance-reports', '.legacy-fix-backups'),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FileError {
    param([string]$Path, [string]$Reason)
    # CODE RED: every file/path error must include exact path + reason
    Write-Host "  [FAIL] path: $Path -- reason: $Reason" -ForegroundColor Red
}

# ---- Validate root ----------------------------------------------------------
if (-not (Test-Path -LiteralPath $Root)) {
    Write-FileError -Path $Root -Reason 'directory does not exist'
    exit 2
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath

# ---- Build pattern (e.g. scripts-fixer-v(8|9|10)) ---------------------------
$verAlt  = ($Versions | ForEach-Object { [string]$_ }) -join '|'
$pattern = "scripts-fixer-v($verAlt)\b"

if (-not $Quiet) {
    Write-Host ""
    Write-Host "  Legacy scripts-fixer reference scan" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Root     : {0}" -f $Root)        -ForegroundColor DarkGray
    Write-Host ("  Pattern  : {0}" -f $pattern)     -ForegroundColor DarkGray
    Write-Host ("  Skipping : {0}" -f ($ExcludeDirs -join ', ')) -ForegroundColor DarkGray
    Write-Host ""
}

# ---- Walk files -------------------------------------------------------------
$matches = New-Object System.Collections.Generic.List[object]
$scriptSelf = $MyInvocation.MyCommand.Definition

try {
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction Stop
} catch {
    Write-FileError -Path $Root -Reason $_.Exception.Message
    exit 2
}

foreach ($file in $files) {
    # Never flag this scanner itself, the auto-fix tools, the verify pipeline,
    # the migration README, or the JSON report (all legitimately mention v8/v9/v10).
    if ($file.FullName -ieq $scriptSelf) { continue }
    if ($file.Name -imatch '-legacy-(fixer-refs|refs)\.(ps1|sh)$') { continue }
    if ($file.Name -ieq 'legacy-fix-report.json') { continue }
    $relForCheck = $file.FullName.Substring($Root.Length).TrimStart('\','/').Replace('/','\')
    if ($relForCheck -ieq 'tools\readme.md') { continue }

    # Skip excluded directories (path-segment match, case-insensitive)
    $rel = $file.FullName.Substring($Root.Length).TrimStart('\','/')
    $isExcluded = $false
    foreach ($ex in $ExcludeDirs) {
        $needle = $ex.Replace('/', '\')
        if ($rel -ilike "$needle\*" -or $rel -ieq $needle) { $isExcluded = $true; break }
    }
    if ($isExcluded) { continue }

    # Skip obvious binary by extension
    if ($file.Extension -imatch '^\.(png|jpg|jpeg|gif|webp|ico|pdf|zip|7z|exe|dll|woff2?|ttf|otf|mp4|mp3)$') { continue }

    try {
        $hits = Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches -ErrorAction Stop
    } catch {
        Write-FileError -Path $file.FullName -Reason $_.Exception.Message
        continue
    }

    foreach ($h in $hits) {
        $matches.Add([pscustomobject]@{
            File   = $rel
            Line   = $h.LineNumber
            Match  = $h.Matches[0].Value
            Text   = $h.Line.Trim()
        }) | Out-Null
    }
}

# ---- Report -----------------------------------------------------------------
Write-Host ""
if ($matches.Count -eq 0) {
    Write-Host "  [ PASS ] No references to scripts-fixer-v$($Versions -join '/v') found." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host ("  [ FAIL ] Found {0} reference(s):" -f $matches.Count) -ForegroundColor Red
Write-Host ""
$grouped = $matches | Group-Object File | Sort-Object Name
foreach ($g in $grouped) {
    Write-Host ("  {0}" -f $g.Name) -ForegroundColor Yellow
    foreach ($m in $g.Group) {
        $snippet = if ($m.Text.Length -gt 100) { $m.Text.Substring(0,97) + '...' } else { $m.Text }
        Write-Host ("    line {0,4}: {1}" -f $m.Line, $snippet) -ForegroundColor DarkGray
    }
    Write-Host ""
}

# Brief summary by version
$byVer = $matches | Group-Object Match | Sort-Object Name
Write-Host "  Summary:" -ForegroundColor Cyan
foreach ($v in $byVer) {
    Write-Host ("    {0,-22} {1}" -f $v.Name, $v.Count) -ForegroundColor DarkGray
}
Write-Host ""
exit 1
