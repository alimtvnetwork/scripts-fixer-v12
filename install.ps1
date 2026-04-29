# --------------------------------------------------------------------------
#  Scripts Fixer -- One-liner bootstrap installer
#  Usage:  irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex
#
#  Auto-discovery: probes scripts-fixer-vN repos (N = current+1..current+30)
#  in parallel and redirects to the newest published version.
#  Spec: spec/install-bootstrap/readme.md
#  Disable with: -NoUpgrade  or  $env:SCRIPTS_FIXER_NO_UPGRADE = "1"
#  Version check: -Version (shows current and latest, no install)
# --------------------------------------------------------------------------
& {
    param([switch]$NoUpgrade, [switch]$Version, [switch]$Help, [switch]$DryRun)

    $ErrorActionPreference = "Stop"

    # ----- Configuration ----------------------------------------------------
    $owner    = "alimtvnetwork"
    $baseName = "scripts-fixer"
    $current  = 12  # <-- bump this when this file is copied into a new -vN repo
    $repo     = "https://github.com/$owner/$baseName-v$current.git"
    # NOTE: $folder is resolved later -- it is CWD-aware (see Resolve-TargetFolder).
    # Fallback only kicks in when CWD is a protected/system directory.
    $fallbackFolder = Join-Path $env:USERPROFILE "scripts-fixer"

    $probeMax = 30
    if ($env:SCRIPTS_FIXER_PROBE_MAX) {
        $parsed = 0
        if ([int]::TryParse($env:SCRIPTS_FIXER_PROBE_MAX, [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 100) {
            $probeMax = $parsed
        }
    }

    Write-Host ""
    Write-Host "  Scripts Fixer -- Bootstrap Installer (v$current)" -ForegroundColor Cyan
    Write-Host ""

    # ----- Help mode -------------------------------------------------------
    if ($Help) {
        Write-Host "  Usage: install.ps1 [-Version] [-Help] [-NoUpgrade] [-DryRun]" -ForegroundColor White
        Write-Host ""
        Write-Host "  Flags:" -ForegroundColor White
        Write-Host "    -Version     Print bootstrap repo version + payload semver, then exit." -ForegroundColor DarkGray
        Write-Host "                 Also probes for newer scripts-fixer-vN repos and reports" -ForegroundColor DarkGray
        Write-Host "                 the highest one available without redirecting." -ForegroundColor DarkGray
        Write-Host "    -Help        Show this help and exit." -ForegroundColor DarkGray
        Write-Host "    -NoUpgrade   Skip auto-discovery; install from the current repo." -ForegroundColor DarkGray
        Write-Host "    -DryRun      Print every step but mutate nothing." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Env:" -ForegroundColor White
        Write-Host "    `$env:SCRIPTS_FIXER_NO_UPGRADE = '1'   Same as -NoUpgrade" -ForegroundColor DarkGray
        Write-Host "    `$env:SCRIPTS_FIXER_PROBE_MAX  = N     How many vN+k to probe (default 30, max 100)" -ForegroundColor DarkGray
        Write-Host "    `$env:SCRIPTS_FIXER_REDIRECTED = '1'   Internal loop guard, set after one redirect" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    # ----- Helper: fetch payload semver from a repo's scripts/version.json -
    # Best-effort: returns "(unknown)" on any failure (network, missing file,
    # malformed JSON). Never throws -- version reporting must not crash.
    function Get-PayloadSemver {
        param([string]$RepoName)
        $url = "https://raw.githubusercontent.com/$owner/$RepoName/main/scripts/version.json"
        try {
            $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content
            if ([string]::IsNullOrWhiteSpace($raw)) { return "(unknown)" }
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            $hasVersion = $null -ne $obj.PSObject.Properties['version']
            if ($hasVersion -and -not [string]::IsNullOrWhiteSpace($obj.version)) {
                return [string]$obj.version
            }
            return "(unknown)"
        } catch {
            return "(unknown)"
        }
    }

    # ----- Version check mode (discover + report, no clone) ----------------
    if ($Version) {
        $rangeEnd = $current + $probeMax
        $currentSemver = Get-PayloadSemver -RepoName "$baseName-v$current"
        Write-Host "  [VERSION] Bootstrap repo : $baseName-v$current" -ForegroundColor Cyan
        Write-Host "  [VERSION] Payload semver : $currentSemver" -ForegroundColor Cyan
        Write-Host "  [SCAN] Probing v$($current + 1)..v$rangeEnd for newer releases (parallel)..." -ForegroundColor Yellow

        $hasThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
        $found = @()

        try {
            if ($hasThreadJob) {
                $jobs = @()
                foreach ($n in ($current + 1)..$rangeEnd) {
                    $url = "https://raw.githubusercontent.com/$owner/$baseName-v$n/main/install.ps1"
                    $jobs += Start-ThreadJob -ScriptBlock {
                        param($u, $v)
                        try {
                            $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                            if ($r.StatusCode -eq 200) { return $v }
                        } catch {}
                        return $null
                    } -ArgumentList $url, $n
                }
                $results = $jobs | Wait-Job -Timeout 15 | Receive-Job
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
                $found = @($results | Where-Object { $null -ne $_ })
            } else {
                foreach ($n in ($current + 1)..$rangeEnd) {
                    $url = "https://raw.githubusercontent.com/$owner/$baseName-v$n/main/install.ps1"
                    try {
                        $r = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                        if ($r.StatusCode -eq 200) { $found += $n }
                    } catch {}
                }
            }
        } catch {
            Write-Host "  [WARN] Discovery failed: $_" -ForegroundColor Yellow
        }

        if ($found.Count -gt 0) {
            $latest = ($found | Measure-Object -Maximum).Maximum
            if ($latest -gt $current) {
                $latestSemver = Get-PayloadSemver -RepoName "$baseName-v$latest"
                Write-Host "  [FOUND]    Newer repo     : $baseName-v$latest" -ForegroundColor Green
                Write-Host "  [FOUND]    Newer semver   : $latestSemver" -ForegroundColor Green
                Write-Host "  [RESOLVED] Would redirect to $baseName-v$latest" -ForegroundColor Cyan
            } else {
                Write-Host "  [OK] You're on the latest ($baseName-v$current, semver $currentSemver)" -ForegroundColor Green
            }
        } else {
            Write-Host "  [OK] You're on the latest ($baseName-v$current, semver $currentSemver)" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "  (Use without -Version flag to actually install)" -ForegroundColor DarkGray
        return
    }

    # ----- Auto-discovery: probe for newer -vN repos -----------------------
    $skipDiscovery = $NoUpgrade -or $env:SCRIPTS_FIXER_NO_UPGRADE -eq "1" -or $env:SCRIPTS_FIXER_REDIRECTED -eq "1"

    if ($skipDiscovery) {
        if ($env:SCRIPTS_FIXER_REDIRECTED -eq "1") {
            Write-Host "  [SKIP] Auto-discovery skipped (already redirected)." -ForegroundColor DarkGray
        } else {
            Write-Host "  [SKIP] Auto-discovery disabled." -ForegroundColor DarkGray
        }
    } else {
        $rangeEnd = $current + $probeMax
        Write-Host "  [SCAN] Currently on v$current. Probing v$($current + 1)..v$rangeEnd for newer releases (parallel)..." -ForegroundColor Yellow

        $hasThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
        $found = @()

        try {
            if ($hasThreadJob) {
                $jobs = @()
                foreach ($n in ($current + 1)..$rangeEnd) {
                    $url = "https://raw.githubusercontent.com/$owner/$baseName-v$n/main/install.ps1"
                    $jobs += Start-ThreadJob -ScriptBlock {
                        param($u, $v)
                        try {
                            $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                            if ($r.StatusCode -eq 200) { return $v }
                        } catch {}
                        return $null
                    } -ArgumentList $url, $n
                }
                $results = $jobs | Wait-Job -Timeout 15 | Receive-Job
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
                $found = @($results | Where-Object { $null -ne $_ })
            } else {
                # Sequential fallback (Windows PowerShell 5.1 without ThreadJob module)
                foreach ($n in ($current + 1)..$rangeEnd) {
                    $url = "https://raw.githubusercontent.com/$owner/$baseName-v$n/main/install.ps1"
                    try {
                        $r = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                        if ($r.StatusCode -eq 200) { $found += $n }
                    } catch {}
                }
            }
        } catch {
            Write-Host "  [WARN] Discovery failed: $_  -- continuing with v$current" -ForegroundColor Yellow
            $found = @()
        }

        if ($found.Count -gt 0) {
            $latest = ($found | Measure-Object -Maximum).Maximum
            if ($latest -gt $current) {
                Write-Host "  [FOUND] Newer version available: v$latest" -ForegroundColor Green
                Write-Host "  [REDIRECT] Switching to $baseName-v$latest..." -ForegroundColor Cyan
                Write-Host ""
                $env:SCRIPTS_FIXER_REDIRECTED = "1"
                $newUrl = "https://raw.githubusercontent.com/$owner/$baseName-v$latest/main/install.ps1"
                try {
                    $script = (Invoke-WebRequest -Uri $newUrl -UseBasicParsing -TimeoutSec 15).Content
                    Invoke-Expression $script
                    return
                } catch {
                    Write-Host "  [WARN] Failed to fetch v$latest installer: $_  -- falling back to v$current" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  [OK] You're on the latest (v$current). Continuing..." -ForegroundColor Green
            }
        } else {
            Write-Host "  [OK] You're on the latest (v$current). Continuing..." -ForegroundColor Green
        }
        Write-Host ""
    }

    # ----- Check git is available ------------------------------------------
    $hasGit = Get-Command git -ErrorAction SilentlyContinue
    if (-not $hasGit) {
        Write-Host "  [ERROR] git is not installed. Install Git first, then re-run." -ForegroundColor Red
        Write-Host "          winget install Git.Git" -ForegroundColor DarkGray
        return
    }

    # ----- Helper: invoke git cleanly (silences stderr-as-error noise) -----
    function Invoke-GitClone {
        param([string]$RepoUrl, [string]$TargetPath)
        Write-Host "  [GIT] Cloning from : $RepoUrl" -ForegroundColor Cyan
        Write-Host "  [GIT] Cloning into : $TargetPath" -ForegroundColor Cyan
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            # Redirect stderr to file so PowerShell does NOT raise NativeCommandError
            # on git's normal progress messages. Capture stdout for diagnostics.
            $stdout = & git clone --quiet $RepoUrl $TargetPath 2>$errFile
            $exit = $LASTEXITCODE
            $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { "" }
            return [pscustomobject]@{ ExitCode = $exit; StdOut = $stdout; StdErr = $stderr }
        } finally {
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    # ----- Helper: safe remove with read-only attribute clearing -----------
    function Remove-FolderSafe {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $true }
        try {
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Host "  [WARN] Could not remove $Path" -ForegroundColor Yellow
            Write-Host "         Reason: $_" -ForegroundColor DarkGray
            return $false
        }
    }

    # ----- Helper: resolve target folder (CWD-aware with safe fallback) ----
    # Decision tree:
    #   1. If CWD's leaf folder name == 'scripts-fixer' -> target = CWD itself
    #      (we are inside an existing checkout; clone back into the same path).
    #   2. Else if CWD contains a 'scripts-fixer' subfolder -> target = that subfolder.
    #   3. Else if CWD is "safe" (writable, not a protected/system dir) -> target = <CWD>\scripts-fixer.
    #   4. Else -> $env:USERPROFILE\scripts-fixer (fallback).
    function Test-CwdIsSafe {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $protected = @(
            "$env:WINDIR",
            "$env:WINDIR\System32",
            "$env:WINDIR\SysWOW64",
            "$env:ProgramFiles",
            "${env:ProgramFiles(x86)}",
            "$env:ProgramData"
        ) | Where-Object { $_ }
        foreach ($p in $protected) {
            if ($Path -ieq $p) { return $false }
            if ($Path.StartsWith($p + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        # Refuse drive root (e.g. "C:\") -- too noisy to drop a repo there
        try {
            $root = [System.IO.Path]::GetPathRoot($Path).TrimEnd('\','/')
            $trimmed = $Path.TrimEnd('\','/')
            if ($trimmed -ieq $root) { return $false }
        } catch {}
        # Quick writability probe
        try {
            $probe = Join-Path $Path (".sf-write-probe-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            return $true
        } catch {
            return $false
        }
    }

    function Resolve-TargetFolder {
        param([string]$Cwd, [string]$Fallback)
        $leaf = Split-Path $Cwd -Leaf
        if ($leaf -ieq 'scripts-fixer') {
            return [pscustomobject]@{ Path = $Cwd; Reason = 'cwd-is-target'; IsInside = $true }
        }
        $sibling = Join-Path $Cwd 'scripts-fixer'
        if (Test-Path $sibling) {
            return [pscustomobject]@{ Path = $sibling; Reason = 'cwd-has-sibling'; IsInside = $false }
        }
        if (Test-CwdIsSafe -Path $Cwd) {
            return [pscustomobject]@{ Path = (Join-Path $Cwd 'scripts-fixer'); Reason = 'cwd-safe'; IsInside = $false }
        }
        return [pscustomobject]@{ Path = $Fallback; Reason = 'fallback-userprofile'; IsInside = $false }
    }

    # ----- Resolve target (CWD-aware) --------------------------------------
    $cwd            = (Get-Location).Path
    $resolved       = Resolve-TargetFolder -Cwd $cwd -Fallback $fallbackFolder
    $folder         = $resolved.Path
    $isInsideTarget = $resolved.IsInside

    Write-Host ""
    Write-Host "  [LOCATE] Current directory : $cwd" -ForegroundColor DarkGray
    Write-Host "  [LOCATE] Target folder     : $folder" -ForegroundColor DarkGray
    switch ($resolved.Reason) {
        'cwd-is-target'        { Write-Host "  [LOCATE] You are INSIDE a 'scripts-fixer' folder -- cloning back into the same path." -ForegroundColor Yellow }
        'cwd-has-sibling'      { Write-Host "  [LOCATE] A 'scripts-fixer' subfolder exists in CWD -- cloning into it." -ForegroundColor Yellow }
        'cwd-safe'             { Write-Host "  [LOCATE] CWD is writable -- cloning into <CWD>\scripts-fixer." -ForegroundColor DarkGray }
        'fallback-userprofile' { Write-Host "  [LOCATE] CWD is a protected/system path -- falling back to USERPROFILE." -ForegroundColor Yellow }
    }

    # ----- Step out of folder if we're sitting inside the target -----------
    if ($isInsideTarget) {
        $parent = Split-Path $cwd -Parent
        Write-Host "  [CD] Stepping out to parent  : $parent" -ForegroundColor Yellow
        if ($DryRun) {
            Write-Host "  [DRYRUN] Set-Location $parent  (skipped)" -ForegroundColor Magenta
        } else {
            Set-Location $parent
        }
    }

    # ----- Try to remove existing target folder ----------------------------
    $removed = $true
    if (Test-Path $folder) {
        Write-Host "  [CLEAN] Removing existing folder: $folder" -ForegroundColor Yellow
        $removed = Remove-FolderSafe -Path $folder -IsDryRun:$DryRun
        if ($removed) {
            if ($DryRun) {
                Write-Host "  [DRYRUN] (would have removed) Folder: $folder" -ForegroundColor Magenta
            } else {
                Write-Host "  [OK] Folder removed." -ForegroundColor Green
            }
        } else {
            Write-Host "  [INFO] Direct removal failed -- will use TEMP staging fallback." -ForegroundColor Yellow
        }
    }

    # ----- Direct clone path (no conflict OR remove succeeded) -------------
    if ($removed) {
        Write-Host ""
        Write-Host "  [>>] Direct clone into target..." -ForegroundColor Yellow
        $r = Invoke-GitClone -RepoUrl $repo -TargetPath $folder -IsDryRun:$DryRun
        if (-not $DryRun) {
            if ($r.ExitCode -ne 0 -or -not (Test-Path (Join-Path $folder ".git"))) {
                Write-Host "  [ERROR] Clone failed (exit $($r.ExitCode))" -ForegroundColor Red
                Write-Host "          Repo   : $repo" -ForegroundColor Red
                Write-Host "          Target : $folder" -ForegroundColor Red
                if ($r.StdErr) {
                    Write-Host "          Git stderr:" -ForegroundColor DarkGray
                    ($r.StdErr -split "`n") | ForEach-Object { if ($_.Trim()) { Write-Host "            $_" -ForegroundColor DarkGray } }
                }
                Write-Host "          Verify the repo exists and your network is reachable." -ForegroundColor DarkGray
                return
            }
            Write-Host "  [OK] Cloned successfully into $folder" -ForegroundColor Green
        }
    }
    else {
        # ----- TEMP staging fallback (remove failed -- folder is locked) ---
        $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
        $tempDir = Join-Path $env:TEMP "scripts-fixer-bootstrap-$stamp"
        Write-Host ""
        Write-Host "  [TEMP] Staging clone path  : $tempDir" -ForegroundColor Yellow
        $r = Invoke-GitClone -RepoUrl $repo -TargetPath $tempDir -IsDryRun:$DryRun
        if (-not $DryRun) {
            if ($r.ExitCode -ne 0 -or -not (Test-Path (Join-Path $tempDir ".git"))) {
                Write-Host "  [ERROR] Temp clone failed (exit $($r.ExitCode))" -ForegroundColor Red
                Write-Host "          Repo   : $repo" -ForegroundColor Red
                Write-Host "          Target : $tempDir" -ForegroundColor Red
                if ($r.StdErr) {
                    Write-Host "          Git stderr:" -ForegroundColor DarkGray
                    ($r.StdErr -split "`n") | ForEach-Object { if ($_.Trim()) { Write-Host "            $_" -ForegroundColor DarkGray } }
                }
                return
            }
            Write-Host "  [OK] Temp clone complete." -ForegroundColor Green
        }

        # Copy contents over the locked folder (overwrite)
        Write-Host "  [COPY] From : $tempDir" -ForegroundColor Yellow
        Write-Host "  [COPY] To   : $folder" -ForegroundColor Yellow
        if ($DryRun) {
            Write-Host "  [DRYRUN] Copy-Item -Recurse -Force from $tempDir to $folder  (skipped)" -ForegroundColor Magenta
        } else {
            if (-not (Test-Path $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            try {
                Copy-Item -Path (Join-Path $tempDir '*') -Destination $folder -Recurse -Force -ErrorAction Stop
                Write-Host "  [OK] Files copied into $folder" -ForegroundColor Green
            } catch {
                Write-Host "  [ERROR] Copy from temp failed." -ForegroundColor Red
                Write-Host "          Source : $tempDir" -ForegroundColor Red
                Write-Host "          Target : $folder" -ForegroundColor Red
                Write-Host "          Reason : $_" -ForegroundColor Red
                Write-Host "          Files remain in temp -- copy manually if needed." -ForegroundColor DarkGray
                return
            }

            # Best-effort cleanup of temp staging
            Remove-FolderSafe -Path $tempDir -IsDryRun:$false | Out-Null
            Write-Host "  [CLEAN] Temp staging removed." -ForegroundColor DarkGray
        }
    }

    # ----- Enter folder and launch run.ps1 (no args, user picks) -----------
    Write-Host ""
    Write-Host "  [CD] Entering              : $folder" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "  [DRYRUN] Set-Location $folder  (skipped)" -ForegroundColor Magenta
        Write-Host "  [DRYRUN] & .\run.ps1  (skipped)" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "  [DRYRUN] Dry-run complete. Re-run without -DryRun to actually install." -ForegroundColor Magenta
        Write-Host ""
        return
    }
    Set-Location $folder
    Write-Host "  [RUN] Launching .\run.ps1 ..." -ForegroundColor Cyan
    Write-Host ""
    & .\run.ps1
} @args
