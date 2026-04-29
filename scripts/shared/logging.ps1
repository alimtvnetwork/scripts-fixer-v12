<#
.SYNOPSIS
    Shared logging helpers used by all scripts in this repo.
    Logs are written to scripts/logs/ as structured JSON files.
#>

# ── Module-scoped log state ──────────────────────────────────────────────────
$script:_LogEvents   = [System.Collections.ArrayList]::new()
$script:_LogErrors   = [System.Collections.ArrayList]::new()
$script:_LogWarnings = [System.Collections.ArrayList]::new()
$script:_LogName     = $null
$script:_LogStart    = $null
$script:_LogsDir     = $null
# Cached identity fields (resolved once per session, stamped into every event
# so log lines stay traceable even after grep / split / concat).
$script:_LogIdentity = $null

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [string]$Status = "info",

        [string]$Level
    )

    # -Level alias: map new-style names to old-style names
    if ($Level) {
        $Status = switch ($Level.ToLower()) {
            "success" { "ok" }
            "error"   { "fail" }
            default   { $Level }
        }
    }

    # Validate
    $validStatuses = @("ok", "fail", "info", "warn", "skip")
    if ($Status -notin $validStatuses) { $Status = "info" }

    $badge  = $null
    $hasLogMessages = (Get-Variable -Name LogMessages -Scope Script -ErrorAction SilentlyContinue) -and
                      $script:LogMessages.PSObject.Properties['status']
    if ($hasLogMessages) {
        $badge = $script:LogMessages.status.$Status
    }
    $isBadgeMissing = -not $badge
    if ($isBadgeMissing) {
        $fallbackBadges = @{ ok = "[  OK  ]"; fail = "[ FAIL ]"; info = "[ INFO ]"; warn = "[ WARN ]"; skip = "[ SKIP ]" }
        $badge = $fallbackBadges[$Status]
    }

    $colors = @{
        ok   = "Green"
        fail = "Red"
        info = "Cyan"
        warn = "Yellow"
        skip = "DarkGray"
    }

    Write-Host "  $badge " -ForegroundColor $colors[$Status] -NoNewline

    # Highlight version numbers in a distinct color
    $versionPattern = '(v?\d+\.\d+[\.\d]*[a-zA-Z0-9\-\.]*)'
    $parts = [regex]::Split($Message, $versionPattern)
    foreach ($part in $parts) {
        $isVersion = [regex]::IsMatch($part, "^$versionPattern$")
        if ($isVersion) {
            Write-Host $part -ForegroundColor Yellow -NoNewline
        }
        else {
            Write-Host $part -NoNewline
        }
    }
    Write-Host ""

    # ── Record structured event ──────────────────────────────────────────
    # Stamp identity (projectVersion + invokedFrom) onto every event so a
    # single grepped line is still traceable to its origin script and version.
    $hasCachedIdentity = $null -ne $script:_LogIdentity
    if (-not $hasCachedIdentity) {
        try { $script:_LogIdentity = Get-LogIdentityFields } catch {
            $script:_LogIdentity = @{ projectVersion = "unknown"; invokedFrom = "unknown"; gitSha = "unknown"; gitShaFull = "unknown"; gitBranch = "unknown"; gitDirty = $false; gitRemote = "unknown" }
        }
    }
    $event = [ordered]@{
        timestamp      = (Get-Date -Format "o")
        level          = $Status
        message        = $Message
        projectVersion = $script:_LogIdentity.projectVersion
        invokedFrom    = $script:_LogIdentity.invokedFrom
        gitSha         = $script:_LogIdentity.gitSha
        gitBranch      = $script:_LogIdentity.gitBranch
        scriptName     = $script:_LogName
    }
    $script:_LogEvents.Add($event) | Out-Null

    # Track errors and warnings separately
    $isError = $Status -eq "fail"
    if ($isError) {
        $script:_LogErrors.Add($event) | Out-Null
    }
    $isWarn = $Status -eq "warn"
    if ($isWarn) {
        $script:_LogWarnings.Add($event) | Out-Null
    }
}

function Write-FileError {
    <#
    .SYNOPSIS
        CODE RED: Logs a file/path error with exact path, operation, and failure reason.
        All file-related errors in the project MUST use this helper.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$Module,

        [string]$Fallback
    )

    # Soft-validate Operation: never crash the caller for an unknown verb.
    # Older callers (or new verbs added in newer scripts running against an
    # older shared logger) MUST NOT bring the whole script down. Unknown verbs
    # are accepted as-is and the original CODE RED log line is still emitted
    # with the exact path + reason, which is the contract that matters.
    $knownOperations = @(
        "read", "write", "copy", "move", "inject", "load", "extract", "resolve",
        "install", "delete", "execute", "download", "parse",
        "backup", "checksum", "create", "fetch", "mkdir", "symlink", "verify"
    )
    $isUnknownOperation = $Operation -notin $knownOperations
    if ($isUnknownOperation) {
        Write-Log ("[CODE RED] Unknown Write-FileError Operation '{0}' -- accepting as-is so logging cannot mask the real error" -f $Operation) -Level "warn"
    }

    # Auto-detect module from call stack if not provided
    $isModuleMissing = [string]::IsNullOrWhiteSpace($Module)
    if ($isModuleMissing) {
        $caller = (Get-PSCallStack)[1]
        $Module = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { "unknown" }
    }

    $msg = "[CODE RED] File error during ${Operation}: ${FilePath} -- Reason: ${Reason} [Module: ${Module}]"
    $hasFallback = -not [string]::IsNullOrWhiteSpace($Fallback)
    if ($hasFallback) {
        $msg += " -- Fallback: ${Fallback}"
    }

    Write-Log $msg -Level "error"

    # Record structured file-error event (also stamped with identity)
    $hasCachedIdentity = $null -ne $script:_LogIdentity
    if (-not $hasCachedIdentity) {
        try { $script:_LogIdentity = Get-LogIdentityFields } catch {
            $script:_LogIdentity = @{ projectVersion = "unknown"; invokedFrom = "unknown"; gitSha = "unknown"; gitShaFull = "unknown"; gitBranch = "unknown"; gitDirty = $false; gitRemote = "unknown" }
        }
    }
    $fileErrorEvent = [ordered]@{
        timestamp      = (Get-Date -Format "o")
        level          = "fail"
        type           = "file-error"
        filePath       = $FilePath
        operation      = $Operation
        reason         = $Reason
        module         = $Module
        fallback       = if ($hasFallback) { $Fallback } else { $null }
        message        = $msg
        projectVersion = $script:_LogIdentity.projectVersion
        invokedFrom    = $script:_LogIdentity.invokedFrom
        gitSha         = $script:_LogIdentity.gitSha
        gitBranch      = $script:_LogIdentity.gitBranch
        scriptName     = $script:_LogName
    }
    $script:_LogEvents.Add($fileErrorEvent) | Out-Null
    $script:_LogErrors.Add($fileErrorEvent) | Out-Null
}

function Write-Banner {
    param(
        [Parameter(Position = 0)]
        [string[]]$Lines,

        [Parameter(Position = 1)]
        [string]$Color = "Magenta",

        [string]$Title,
        [string]$Version
    )

    # New-style: -Title and -Version params
    if ($Title) {
        # Always read version from the central scripts/version.json
        $versionFilePath = Join-Path (Split-Path -Parent $PSScriptRoot) "version.json"
        $isShared = (Split-Path -Leaf $PSScriptRoot) -eq "shared"
        if ($isShared) {
            $versionFilePath = Join-Path (Split-Path -Parent $PSScriptRoot) "version.json"
        }
        $hasVersionFile = Test-Path $versionFilePath
        if ($hasVersionFile) {
            $versionData = Get-Content $versionFilePath -Raw | ConvertFrom-Json
            $Version = $versionData.version
        }

        $header = if ($Version) { "$Title -- v$Version" } else { $Title }
        $border = "-" * ([Math]::Max($header.Length + 6, 60))
        $Lines = @($border, "  $header", $border)
    }

    Write-Host ""
    foreach ($line in $Lines) { Write-Host $line -ForegroundColor $Color }
    Write-Host ""
}

function Initialize-Logging {
    param(
        [Parameter(Position = 0)]
        [string]$ScriptName
    )

    # Resolve .logs/ directory at project root (parent of scripts/)
    $scriptsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $isSharedDir = (Split-Path -Leaf $PSScriptRoot) -eq "shared"
    if ($isSharedDir) {
        $scriptsRoot = Split-Path -Parent $PSScriptRoot
    }
    $projectRoot = Split-Path -Parent $scriptsRoot
    $logsDir = Join-Path $projectRoot ".logs"

    # Create .logs dir if missing
    $isLogsDirMissing = -not (Test-Path $logsDir)
    if ($isLogsDirMissing) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }

    # Sanitise script name for filename (e.g. "Install Golang" -> "golang")
    $safeName = $ScriptName.ToLower() -replace '[^a-z0-9]+', '-'
    $safeName = $safeName.Trim('-')

    # Store state
    $script:_LogsDir   = $logsDir
    $script:_LogName   = $safeName
    $script:_LogStart  = Get-Date
    $script:_LogEvents   = [System.Collections.ArrayList]::new()
    $script:_LogErrors   = [System.Collections.ArrayList]::new()
    $script:_LogWarnings = [System.Collections.ArrayList]::new()

    # Resolve identity ONCE per session and cache it. Every event written via
    # Write-Log / Write-FileError will copy these two fields onto its own
    # record so individual log lines stay traceable after grep / split / merge.
    try { $script:_LogIdentity = Get-LogIdentityFields } catch {
        $script:_LogIdentity = @{ projectVersion = "unknown"; invokedFrom = "unknown"; gitSha = "unknown"; gitShaFull = "unknown"; gitBranch = "unknown"; gitDirty = $false; gitRemote = "unknown" }
    }

    Write-Log "Logging initialised -- events will be saved to: $logsDir\$safeName.json" -Level "info"
}

function Get-LogIdentityFields {
    <#
    .SYNOPSIS
        Returns @{ projectVersion = "X.Y.Z"; invokedFrom = "scripts/.../run.ps1" }
        for stamping into every .logs/*.json payload so log files are
        self-identifying without reading the surrounding repo state.
        Both fields are best-effort -- never throw.
    #>
    $projectVersion = "unknown"
    $invokedFrom    = "unknown"
    $gitSha         = "unknown"
    $gitShaFull     = "unknown"
    $gitBranch      = "unknown"
    $gitDirty       = $false
    $gitRemote      = "unknown"

    try {
        # Resolve project root the same way Initialize-Logging does.
        $scriptsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $isSharedDir = (Split-Path -Leaf $PSScriptRoot) -eq "shared"
        if ($isSharedDir) {
            $scriptsRoot = Split-Path -Parent $PSScriptRoot
        }
        $projectRoot = Split-Path -Parent $scriptsRoot

        # ----- git identity (best-effort, never throws) -----
        try {
            $gitDir = Join-Path $projectRoot ".git"
            if (Test-Path -LiteralPath $gitDir) {
                Push-Location -LiteralPath $projectRoot
                try {
                    $sha = (& git rev-parse --short=12 HEAD 2>$null) | Select-Object -First 1
                    if ($sha) { $gitSha = "$sha".Trim() }
                    $shaFull = (& git rev-parse HEAD 2>$null) | Select-Object -First 1
                    if ($shaFull) { $gitShaFull = "$shaFull".Trim() }
                    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null) | Select-Object -First 1
                    if ($branch) { $gitBranch = "$branch".Trim() }
                    $remote = (& git config --get remote.origin.url 2>$null) | Select-Object -First 1
                    if ($remote) { $gitRemote = "$remote".Trim() }
                    $status = (& git status --porcelain 2>$null)
                    if ($status) { $gitDirty = $true }
                } finally { Pop-Location }
            }
        } catch { }

        # ----- projectVersion : read scripts/version.json -----
        $versionFile = Join-Path $scriptsRoot "version.json"
        $hasVersionFile = Test-Path -LiteralPath $versionFile
        if ($hasVersionFile) {
            try {
                $vd = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
                if ($vd.version) { $projectVersion = "$($vd.version)" }
            } catch {
                Write-Log "logging: failed to read version.json at ${versionFile}: $($_.Exception.Message)" -Level "warn"
            }
        } else {
            Write-Log "logging: version.json missing at ${versionFile} -- projectVersion=unknown" -Level "warn"
        }

        # ----- invokedFrom : top-of-callstack script, relative to project root -----
        try {
            $stack = Get-PSCallStack
            $thisFile = $PSCommandPath
            $candidate = $null
            # Walk from the bottom (oldest frame) and pick the first frame whose
            # ScriptName lives under the project root and is NOT this logging file.
            for ($i = $stack.Count - 1; $i -ge 0; $i--) {
                $sn = $stack[$i].ScriptName
                if ([string]::IsNullOrWhiteSpace($sn)) { continue }
                if ($sn -eq $thisFile) { continue }
                if ($sn.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $candidate = $sn
                    break
                }
            }
            if (-not $candidate) {
                # Fall back to the very last non-logging frame, even if outside the repo.
                for ($i = $stack.Count - 1; $i -ge 0; $i--) {
                    $sn = $stack[$i].ScriptName
                    if (-not [string]::IsNullOrWhiteSpace($sn) -and $sn -ne $thisFile) {
                        $candidate = $sn
                        break
                    }
                }
            }
            if ($candidate) {
                if ($candidate.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $candidate.Substring($projectRoot.Length).TrimStart('\','/')
                    $invokedFrom = ($rel -replace '\\','/')
                } else {
                    # Outside the repo -- store the absolute path so the log is still useful.
                    $invokedFrom = $candidate
                }
            }
        } catch {
            Write-Log "logging: callstack resolution failed: $($_.Exception.Message)" -Level "warn"
        }
    } catch {
        # Total fallback -- both fields stay "unknown".
    }

    return @{
        projectVersion = $projectVersion
        invokedFrom    = $invokedFrom
        gitSha         = $gitSha
        gitShaFull     = $gitShaFull
        gitBranch      = $gitBranch
        gitDirty       = $gitDirty
        gitRemote      = $gitRemote
    }
}

function Save-LogFile {
    <#
    .SYNOPSIS
        Flush collected log events to scripts/logs/<name>.json
        and scripts/logs/<name>-error.json (if errors exist).
    #>
    param(
        [string]$Status = "ok"
    )

    $isNotInitialised = -not $script:_LogsDir
    if ($isNotInitialised) { return }

    $endTime  = Get-Date
    $duration = ($endTime - $script:_LogStart).TotalSeconds

    # Identity fields stamped into every log payload (v0.42.2+) AND into
    # every event entry (v0.43.1+). Reuse the cached value from
    # Initialize-Logging so we don't walk the call stack twice.
    $hasCachedIdentity = $null -ne $script:_LogIdentity
    if ($hasCachedIdentity) {
        $identity = $script:_LogIdentity
    } else {
        $identity = Get-LogIdentityFields
    }

    # Main log file
    $logData = [ordered]@{
        projectVersion = $identity.projectVersion
        invokedFrom    = $identity.invokedFrom
        gitSha         = $identity.gitSha
        gitShaFull     = $identity.gitShaFull
        gitBranch      = $identity.gitBranch
        gitDirty       = $identity.gitDirty
        gitRemote      = $identity.gitRemote
        scriptName     = $script:_LogName
        status         = $Status
        startTime      = $script:_LogStart.ToString("o")
        endTime        = $endTime.ToString("o")
        duration       = [math]::Round($duration, 2)
        eventCount     = $script:_LogEvents.Count
        errorCount     = $script:_LogErrors.Count
        warnCount      = $script:_LogWarnings.Count
        events         = @($script:_LogEvents)
    }

    $logPath = Join-Path $script:_LogsDir "$($script:_LogName).json"
    $logData | ConvertTo-Json -Depth 5 | Set-Content -Path $logPath -Encoding UTF8
    Write-Host "  [  OK  ] Log saved: $logPath" -ForegroundColor Green

    # Error/warning log file -- written when there are errors, warnings, or overall failure
    $hasErrors = $script:_LogErrors.Count -gt 0
    $hasWarnings = $script:_LogWarnings.Count -gt 0
    $isOverallFailure = $Status -eq "fail"
    $shouldWriteErrorLog = $hasErrors -or $hasWarnings -or $isOverallFailure
    if ($shouldWriteErrorLog) {
        $errorData = [ordered]@{
            projectVersion = $identity.projectVersion
            invokedFrom    = $identity.invokedFrom
            gitSha         = $identity.gitSha
            gitShaFull     = $identity.gitShaFull
            gitBranch      = $identity.gitBranch
            gitDirty       = $identity.gitDirty
            gitRemote      = $identity.gitRemote
            scriptName     = $script:_LogName
            overallStatus  = $Status
            startTime      = $script:_LogStart.ToString("o")
            endTime        = $endTime.ToString("o")
            duration       = [math]::Round($duration, 2)
            errorCount     = $script:_LogErrors.Count
            warnCount      = $script:_LogWarnings.Count
            errors         = @($script:_LogErrors)
            warnings       = @($script:_LogWarnings)
        }

        $errorPath = Join-Path $script:_LogsDir "$($script:_LogName)-error.json"
        $errorJson = $errorData | ConvertTo-Json -Depth 5
        $errorJson | Set-Content -Path $errorPath -Encoding UTF8
        Write-Host "  [ WARN ] Error log saved: $errorPath" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  ---- Error log contents ----" -ForegroundColor Red
        $errorJson -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
        Write-Host "  ----------------------------" -ForegroundColor Red
    }

    # Print one-line summary for easy copy-paste
    $summaryParts = @("[$($script:_LogName)] Status: $Status | Duration: $([math]::Round($duration, 1))s")
    if ($hasErrors) { $summaryParts += "Errors: $($script:_LogErrors.Count)" }
    if ($hasWarnings) { $summaryParts += "Warnings: $($script:_LogWarnings.Count)" }
    $summaryLine = $summaryParts -join " | "
    $summaryColor = if ($isOverallFailure) { "Red" } elseif ($hasWarnings) { "Yellow" } else { "Green" }
    Write-Host ""
    Write-Host "  $summaryLine" -ForegroundColor $summaryColor

    # If there are errors, print each on its own line for quick scanning
    if ($hasErrors) {
        foreach ($err in $script:_LogErrors) {
            Write-Host "    >> $($err.message)" -ForegroundColor Red
        }
    }
}

function Import-JsonConfig {
    param(
        [Parameter(Position = 0, Mandatory)]
        [string]$FilePath,

        [Parameter(Position = 1)]
        [string]$Label
    )

    $slm = $script:SharedLogMessages

    $isLabelMissing = -not $Label
    if ($isLabelMissing) { $Label = Split-Path -Leaf $FilePath }

    # Use shared log messages if available, otherwise fall back to direct Write-Host
    $hasSharedLogs = $null -ne $slm
    if ($hasSharedLogs) {
        Write-Log ($slm.messages.importLoading -replace '\{label\}', $Label -replace '\{path\}', $FilePath) -Level "info"
    }

    $isFileMissing = -not (Test-Path $FilePath)
    if ($isFileMissing) {
        Write-FileError -FilePath $FilePath -Operation "load" -Reason "File does not exist" -Module "Import-JsonConfig"
        if ($hasSharedLogs) {
            Write-Log ($slm.messages.importNotFound -replace '\{label\}', $Label -replace '\{path\}', $FilePath) -Level "error"
        }
        return $null
    }

    $content = Get-Content $FilePath -Raw
    if ($hasSharedLogs) {
        Write-Log ($slm.messages.importFileSize -replace '\{label\}', $Label -replace '\{size\}', $content.Length) -Level "info"
    }

    $parsed = $content | ConvertFrom-Json
    if ($hasSharedLogs) {
        Write-Log ($slm.messages.importLoaded -replace '\{label\}', $Label) -Level "success"
    }
    return $parsed
}

# -- Auto-load installation tracking helper ------------------------------------
$_installedPath = Join-Path $PSScriptRoot "installed.ps1"
if ((Test-Path $_installedPath) -and -not (Get-Command Test-AlreadyInstalled -ErrorAction SilentlyContinue)) {
    . $_installedPath
}

# -- Auto-load tool version helper ---------------------------------------------
$_toolVersionPath = Join-Path $PSScriptRoot "tool-version.ps1"
if ((Test-Path $_toolVersionPath) -and -not (Get-Command Assert-ToolVersion -ErrorAction SilentlyContinue)) {
    . $_toolVersionPath
}
