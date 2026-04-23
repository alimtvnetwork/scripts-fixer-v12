# --------------------------------------------------------------------------
#  llama.cpp model picker -- interactive numbered model selection
#  Displays catalog, lets user pick by number/range, downloads via aria2c.
# --------------------------------------------------------------------------

function Show-ModelCatalog {
    <#
    .SYNOPSIS
        Displays the model catalog as a numbered list with rich metadata.
        Groups models by starred (recommended) first, then by size.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Models
    )

    $colNum   = 5
    $colName  = 38
    $colParam = 10
    $colQuant = 8
    $colSize  = 8
    $colRAM   = 8
    $colSpeed = 10
    $colCaps  = 20

    Write-Host ""
    Write-Host ("  {0,-$colNum} {1,-$colName} {2,-$colParam} {3,-$colQuant} {4,-$colSize} {5,-$colRAM} {6,-$colSpeed} {7}" -f "#", "Model", "Params", "Quant", "Size", "RAM", "Speed", "Capabilities") -ForegroundColor Cyan
    Write-Host ("  " + ("-" * ($colNum + $colName + $colParam + $colQuant + $colSize + $colRAM + $colSpeed + $colCaps))) -ForegroundColor DarkGray

    $prevStarred = $null
    foreach ($model in $Models) {
        $isStarred = $model.displayName.StartsWith([char]0x2605)

        # Section separator between starred and non-starred
        if ($null -ne $prevStarred -and $prevStarred -and -not $isStarred) {
            Write-Host ("  " + ("-" * ($colNum + $colName + $colParam + $colQuant + $colSize + $colRAM + $colSpeed + $colCaps))) -ForegroundColor DarkGray
        }
        $prevStarred = $isStarred

        # Build capabilities string
        $caps = @()
        if ($model.isCoding)       { $caps += "code" }
        if ($model.isReasoning)    { $caps += "reason" }
        if ($model.isWriting)      { $caps += "write" }
        if ($model.isVoice)        { $caps += "voice" }
        if ($model.isChat)         { $caps += "chat" }
        if ($model.isMultilingual) { $caps += "multi" }
        $capsStr = $caps -join ", "

        # Speed tier based on fileSizeGB (proxy for parameter count at similar quant)
        $speedTier = if ($model.fileSizeGB -lt 1)  { "instant" }
                     elseif ($model.fileSizeGB -lt 3)  { "fast" }
                     elseif ($model.fileSizeGB -lt 8)  { "moderate" }
                     else { "slow" }

        # Color based on rating
        $rating = if ($model.rating.overall) { $model.rating.overall } else { 0 }
        $color = if ($rating -ge 9) { "Green" } elseif ($rating -ge 7) { "Yellow" } elseif ($rating -ge 5) { "White" } else { "DarkGray" }

        $sizeStr = "$($model.fileSizeGB) GB"
        $ramStr  = "$($model.ramRequiredGB) GB"
        $truncName = if ($model.displayName.Length -gt ($colName - 2)) { $model.displayName.Substring(0, $colName - 4) + ".." } else { $model.displayName }

        Write-Host ("  {0,-$colNum} {1,-$colName} {2,-$colParam} {3,-$colQuant} {4,-$colSize} {5,-$colRAM} {6,-$colSpeed} {7}" -f "[$($model.index)]", $truncName, $model.parameters, $model.quantization, $sizeStr, $ramStr, $speedTier, $capsStr) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "  Total: $($Models.Count) models" -ForegroundColor Cyan
    Write-Host ""
}

function Read-RamFilter {
    <#
    .SYNOPSIS
        Prompts user for available RAM and filters models that fit.
        Returns filtered (and re-indexed) model array.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Models
    )

    # Detect system RAM
    $detectedRAM = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($null -ne $os) {
            $detectedRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
        }
    } catch { }

    Write-Host ""
    Write-Host "  Filter by available RAM:" -ForegroundColor Cyan
    if ($null -ne $detectedRAM) {
        Write-Host "    Detected system RAM: ~$detectedRAM GB" -ForegroundColor Green
    }
    Write-Host "    [1]  4 GB" -ForegroundColor White
    Write-Host "    [2]  8 GB" -ForegroundColor White
    Write-Host "    [3] 16 GB" -ForegroundColor White
    Write-Host "    [4] 32 GB" -ForegroundColor White
    Write-Host "    [5] 64 GB+" -ForegroundColor White
    Write-Host ""
    Write-Host "    [Enter] No RAM filter (show all)" -ForegroundColor DarkGray
    if ($null -ne $detectedRAM) {
        Write-Host "    [d] Use detected RAM ($detectedRAM GB)" -ForegroundColor DarkGray
    }
    Write-Host ""

    $input = Read-Host -Prompt "  RAM filter selection"
    $trimmed = $input.Trim().ToLower()

    $isEmpty = [string]::IsNullOrWhiteSpace($trimmed)
    if ($isEmpty) { return $Models }

    $ramLimit = $null
    switch ($trimmed) {
        "1" { $ramLimit = 4 }
        "2" { $ramLimit = 8 }
        "3" { $ramLimit = 16 }
        "4" { $ramLimit = 32 }
        "5" { $ramLimit = 64 }
        "d" { $ramLimit = $detectedRAM }
        default {
            # Allow direct numeric input
            if ($trimmed -match "^\d+$") { $ramLimit = [int]$trimmed }
        }
    }

    if ($null -eq $ramLimit) { return $Models }

    $filtered = @($Models | Where-Object { $_.ramRequiredGB -le $ramLimit })

    Write-Host ""
    Write-Log "  Filtered to models requiring <= $ramLimit GB RAM ($($filtered.Count) models)" -Level "info"

    # Re-index
    $idx = 1
    foreach ($m in $filtered) {
        $m.index = $idx
        $idx++
    }

    return $filtered
}

function Read-SizeFilter {
    <#
    .SYNOPSIS
        Prompts user to filter models by download size tier.
        Returns filtered (and re-indexed) model array.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Models
    )

    Write-Host ""
    Write-Host "  Filter by download size:" -ForegroundColor Cyan
    Write-Host "    [1] Tiny    (< 1 GB)  -- runs on anything" -ForegroundColor White
    Write-Host "    [2] Small   (< 3 GB)  -- phones, tablets, Raspberry Pi" -ForegroundColor White
    Write-Host "    [3] Medium  (< 6 GB)  -- laptops, desktops" -ForegroundColor White
    Write-Host "    [4] Large   (< 12 GB) -- workstations" -ForegroundColor White
    Write-Host "    [5] XLarge  (12+ GB)  -- high-end GPUs" -ForegroundColor White
    Write-Host ""
    Write-Host "    [Enter] No size filter (show all)" -ForegroundColor DarkGray
    Write-Host ""

    $input = Read-Host -Prompt "  Size filter selection"
    $trimmed = $input.Trim().ToLower()

    $isEmpty = [string]::IsNullOrWhiteSpace($trimmed)
    if ($isEmpty) { return $Models }

    $maxSizeGB = $null
    $minSizeGB = 0
    $tierLabel = ""
    switch ($trimmed) {
        "1" { $maxSizeGB = 1;   $tierLabel = "Tiny (< 1 GB)" }
        "2" { $maxSizeGB = 3;   $tierLabel = "Small (< 3 GB)" }
        "3" { $maxSizeGB = 6;   $tierLabel = "Medium (< 6 GB)" }
        "4" { $maxSizeGB = 12;  $tierLabel = "Large (< 12 GB)" }
        "5" { $minSizeGB = 12;  $tierLabel = "XLarge (12+ GB)" }
    }

    if ($null -eq $maxSizeGB -and $minSizeGB -eq 0) { return $Models }

    if ($minSizeGB -gt 0) {
        $filtered = @($Models | Where-Object { $_.fileSizeGB -ge $minSizeGB })
    } else {
        $filtered = @($Models | Where-Object { $_.fileSizeGB -lt $maxSizeGB })
    }

    Write-Host ""
    Write-Log "  Filtered to $tierLabel ($($filtered.Count) models)" -Level "info"

    # Re-index
    $idx = 1
    foreach ($m in $filtered) {
        $m.index = $idx
        $idx++
    }

    return $filtered
}

function Read-SpeedFilter {
    <#
    .SYNOPSIS
        Prompts user to filter models by speed tier (based on fileSizeGB).
        Returns filtered (and re-indexed) model array.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Models
    )

    # Count models per tier
    $countInstant  = @($Models | Where-Object { $_.fileSizeGB -lt 1 }).Count
    $countFast     = @($Models | Where-Object { $_.fileSizeGB -ge 1 -and $_.fileSizeGB -lt 3 }).Count
    $countModerate = @($Models | Where-Object { $_.fileSizeGB -ge 3 -and $_.fileSizeGB -lt 8 }).Count
    $countSlow     = @($Models | Where-Object { $_.fileSizeGB -ge 8 }).Count

    Write-Host ""
    Write-Host "  Filter by inference speed:" -ForegroundColor Cyan
    Write-Host "    [1] Instant   (< 1 GB)  -- near real-time    ($countInstant models)" -ForegroundColor White
    Write-Host "    [2] Fast      (< 3 GB)  -- very responsive   ($countFast models)" -ForegroundColor White
    Write-Host "    [3] Moderate  (< 8 GB)  -- good throughput   ($countModerate models)" -ForegroundColor White
    Write-Host "    [4] Slow      (8+ GB)   -- requires patience ($countSlow models)" -ForegroundColor White
    Write-Host ""
    Write-Host "    Combine: 1,2 = instant + fast  |  1-3 = up to moderate" -ForegroundColor DarkGray
    Write-Host "    [Enter] No speed filter (show all)" -ForegroundColor DarkGray
    Write-Host ""

    $input = Read-Host -Prompt "  Speed filter selection"
    $trimmed = $input.Trim().ToLower()

    $isEmpty = [string]::IsNullOrWhiteSpace($trimmed)
    if ($isEmpty) { return $Models }

    # Parse selection (supports single, range, comma-separated)
    $selectedNums = @()
    $parts = $trimmed -split ","
    foreach ($part in $parts) {
        $part = $part.Trim()
        $isRange = $part -match "^(\d+)\s*-\s*(\d+)$"
        if ($isRange) {
            $rangeStart = [int]$Matches[1]
            $rangeEnd   = [int]$Matches[2]
            if ($rangeStart -gt $rangeEnd) { $rangeStart, $rangeEnd = $rangeEnd, $rangeStart }
            for ($i = $rangeStart; $i -le $rangeEnd; $i++) {
                $isValid = $i -ge 1 -and $i -le 4
                if ($isValid) { $selectedNums += $i }
            }
        } elseif ($part -match "^\d+$") {
            $num = [int]$part
            $isValid = $num -ge 1 -and $num -le 4
            if ($isValid) { $selectedNums += $num }
        }
    }
    $selectedNums = $selectedNums | Sort-Object -Unique

    $hasSelection = $selectedNums.Count -gt 0
    if (-not $hasSelection) { return $Models }

    # Build filter
    $filtered = @($Models | Where-Object {
        $size = $_.fileSizeGB
        $isMatch = $false
        foreach ($num in $selectedNums) {
            switch ($num) {
                1 { if ($size -lt 1) { $isMatch = $true } }
                2 { if ($size -ge 1 -and $size -lt 3) { $isMatch = $true } }
                3 { if ($size -ge 3 -and $size -lt 8) { $isMatch = $true } }
                4 { if ($size -ge 8) { $isMatch = $true } }
            }
            if ($isMatch) { break }
        }
        $isMatch
    })

    $tierNames = @{ 1 = "Instant"; 2 = "Fast"; 3 = "Moderate"; 4 = "Slow" }
    $labels = @($selectedNums | ForEach-Object { $tierNames[$_] })
    $filterStr = $labels -join ", "

    Write-Host ""
    Write-Log "  Filtered to speed: $filterStr ($($filtered.Count) models)" -Level "info"

    # Re-index
    $idx = 1
    foreach ($m in $filtered) {
        $m.index = $idx
        $idx++
    }

    return $filtered
}

function Read-CapabilityFilter {
    <#
    .SYNOPSIS
        Displays capability filter menu. Returns filtered model array.
        User picks capabilities to filter by, or Enter to show all.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Models
    )

    # Gather available capabilities from catalog
    $capMap = [ordered]@{
        "1" = @{ key = "isCoding";       label = "Coding" }
        "2" = @{ key = "isReasoning";    label = "Reasoning" }
        "3" = @{ key = "isWriting";      label = "Writing" }
        "4" = @{ key = "isChat";         label = "Chat" }
        "5" = @{ key = "isVoice";        label = "Voice / Speech" }
        "6" = @{ key = "isMultilingual"; label = "Multilingual" }
    }

    # Count models per capability
    Write-Host ""
    Write-Host "  Filter by capability:" -ForegroundColor Cyan
    foreach ($entry in $capMap.GetEnumerator()) {
        $capKey = $entry.Value.key
        $count  = @($Models | Where-Object { $_.$capKey -eq $true }).Count
        if ($count -gt 0) {
            Write-Host "    [$($entry.Key)] $($entry.Value.label) ($count models)" -ForegroundColor White
        } else {
            Write-Host "    [$($entry.Key)] $($entry.Value.label) (0 models)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "    [Enter] Show all models" -ForegroundColor DarkGray
    Write-Host "    Examples: 1  |  1,3  |  1-3,5" -ForegroundColor DarkGray
    Write-Host ""

    $input = Read-Host -Prompt "  Filter selection"
    $trimmed = $input.Trim().ToLower()

    # No filter -- return all
    $isEmpty = [string]::IsNullOrWhiteSpace($trimmed)
    if ($isEmpty) {
        return $Models
    }

    # Parse selection (reuse same syntax as model selection)
    $selectedNums = @()
    $parts = $trimmed -split ","
    foreach ($part in $parts) {
        $part = $part.Trim()
        $isRange = $part -match "^(\d+)\s*-\s*(\d+)$"
        if ($isRange) {
            $rangeStart = [int]$Matches[1]
            $rangeEnd   = [int]$Matches[2]
            if ($rangeStart -gt $rangeEnd) { $rangeStart, $rangeEnd = $rangeEnd, $rangeStart }
            for ($i = $rangeStart; $i -le $rangeEnd; $i++) {
                $isValid = $i -ge 1 -and $i -le 6
                if ($isValid) { $selectedNums += $i }
            }
        } elseif ($part -match "^\d+$") {
            $num = [int]$part
            $isValid = $num -ge 1 -and $num -le 6
            if ($isValid) { $selectedNums += $num }
        }
    }
    $selectedNums = $selectedNums | Sort-Object -Unique

    $hasSelection = $selectedNums.Count -gt 0
    if (-not $hasSelection) {
        return $Models
    }

    # Build capability keys to match (OR logic: model matches if ANY selected cap is true)
    $capKeys = @()
    $capLabels = @()
    foreach ($num in $selectedNums) {
        $entry = $capMap["$num"]
        if ($null -ne $entry) {
            $capKeys   += $entry.key
            $capLabels += $entry.label
        }
    }

    $filtered = @($Models | Where-Object {
        $model = $_
        $isMatch = $false
        foreach ($ck in $capKeys) {
            if ($model.$ck -eq $true) { $isMatch = $true; break }
        }
        $isMatch
    })

    $filterStr = $capLabels -join ", "
    Write-Host ""
    Write-Log "  Filtered to: $filterStr ($($filtered.Count) models)" -Level "info"

    # Re-index for display
    $idx = 1
    foreach ($m in $filtered) {
        $m.index = $idx
        $idx++
    }

    return $filtered
}

function Read-ModelSelection {
    <#
    .SYNOPSIS
        Reads user input for model selection.
        Supports: single numbers (3), ranges (1-5), comma-separated (1,3,7),
        mixed (1-3,7,12-15), "all", or "q" to quit.
    .RETURNS
        Array of selected index numbers, or $null if user quits.
    #>
    param(
        [int]$MaxIndex
    )

    Write-Host "  Select models to download:" -ForegroundColor Cyan
    Write-Host "    Examples: 1,3,5  |  1-5  |  1-3,7,12-15  |  all  |  q (quit)" -ForegroundColor DarkGray
    Write-Host ""
    $input = Read-Host -Prompt "  Your selection"

    $trimmed = $input.Trim().ToLower()
    if ($trimmed -eq "q" -or $trimmed -eq "quit" -or $trimmed -eq "exit") {
        return $null
    }

    if ($trimmed -eq "all") {
        return @(1..$MaxIndex)
    }

    $selectedIndices = @()
    $parts = $trimmed -split ","

    foreach ($part in $parts) {
        $part = $part.Trim()
        $isRange = $part -match "^(\d+)\s*-\s*(\d+)$"
        if ($isRange) {
            $rangeStart = [int]$Matches[1]
            $rangeEnd   = [int]$Matches[2]
            if ($rangeStart -gt $rangeEnd) { $rangeStart, $rangeEnd = $rangeEnd, $rangeStart }
            for ($i = $rangeStart; $i -le $rangeEnd; $i++) {
                $isValid = $i -ge 1 -and $i -le $MaxIndex
                if ($isValid) { $selectedIndices += $i }
            }
        } elseif ($part -match "^\d+$") {
            $num = [int]$part
            $isValid = $num -ge 1 -and $num -le $MaxIndex
            if ($isValid) { $selectedIndices += $num }
        }
    }

    # Deduplicate and sort
    $selectedIndices = $selectedIndices | Sort-Object -Unique
    return $selectedIndices
}

function Install-SelectedModels {
    <#
    .SYNOPSIS
        Downloads selected models from the catalog using aria2c with fallback.
        Tracks each download in .installed/ for idempotency.

        When DownloadConfig.parallelEnabled is true and 2+ models are pending,
        runs aria2c in batch (parallel) mode first, then falls back to the
        sequential per-file path for any items that did not succeed.
        Spec: spec/2025-batch/suggestions/03-parallel-downloads.md.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Models,

        [Parameter(Mandatory)]
        [array]$SelectedIndices,

        [Parameter(Mandatory)]
        [string]$ModelsDir,

        $Aria2Config,
        $DownloadConfig,
        $LogMessages
    )

    # Filter selected models
    $selectedModels = @()
    foreach ($model in $Models) {
        $isSelected = $SelectedIndices -contains $model.index
        if ($isSelected) { $selectedModels += $model }
    }

    $totalCount    = $selectedModels.Count
    $totalSizeGB   = ($selectedModels | Measure-Object -Property fileSizeGB -Sum).Sum
    Write-Log "Selected $totalCount models ($([math]::Round($totalSizeGB, 1)) GB total) for download." -Level "info"

    # aria2c config
    $maxConn    = if ($Aria2Config.maxConnections) { $Aria2Config.maxConnections } else { 16 }
    $maxDl      = if ($Aria2Config.maxDownloads) { $Aria2Config.maxDownloads } else { 16 }
    $chunkSize  = if ($Aria2Config.chunkSize) { $Aria2Config.chunkSize } else { "1M" }
    $isContinue = if ($null -ne $Aria2Config.continueDownload) { $Aria2Config.continueDownload } else { $true }

    # Parallel batch config (spec 03)
    $isParallelEnabled = $true
    $batchMaxConcurrent = 3
    $batchConnsPerServer = 8
    $batchSplits = 8
    if ($null -ne $DownloadConfig) {
        if ($null -ne $DownloadConfig.parallelEnabled)      { $isParallelEnabled   = [bool]$DownloadConfig.parallelEnabled }
        if ($DownloadConfig.maxConcurrent)                  { $batchMaxConcurrent  = [int]$DownloadConfig.maxConcurrent }
        if ($DownloadConfig.connectionsPerServer)           { $batchConnsPerServer = [int]$DownloadConfig.connectionsPerServer }
        if ($DownloadConfig.splitsPerFile)                  { $batchSplits         = [int]$DownloadConfig.splitsPerFile }
    }

    $downloadedCount = 0
    $skippedCount    = 0
    $failedCount     = 0

    # Progress tracking helpers (spec: per-model download progress indicator)
    function Format-Bar {
        param([int]$Done, [int]$Total, [int]$Width = 20)
        if ($Total -le 0) { return ("[" + (" " * $Width) + "]") }
        $ratio = [math]::Min(1.0, [double]$Done / [double]$Total)
        $filled = [int][math]::Round($ratio * $Width)
        $empty  = $Width - $filled
        return ("[" + ("#" * $filled) + ("-" * $empty) + "]")
    }

    # -- Pass 1: classify each selection (skip / pending) ----------------------
    $pending = @()
    foreach ($model in $selectedModels) {
        $outputPath   = Join-Path $ModelsDir $model.fileName
        $trackingName = "model-$($model.id)"

        $existingRecord = Get-InstalledRecord -Name $trackingName
        $isTracked      = $null -ne $existingRecord
        $isFilePresent  = Test-Path $outputPath

        if ($isTracked -and $isFilePresent) {
            Write-Log "  [$($model.index)] Already downloaded: $($model.displayName) ($($model.fileSizeGB) GB)" -Level "info"
            $skippedCount++
            continue
        }

        # Stale tracking cleanup: tracked but file is missing.
        if ($isTracked -and -not $isFilePresent) {
            Write-Log "  Stale tracking for $($model.displayName), file missing. Re-downloading." -Level "warn"
            Remove-InstalledRecord -Name $trackingName
        }

        $pending += [pscustomobject]@{
            Model        = $model
            OutputPath   = $outputPath
            TrackingName = $trackingName
        }
    }

    $pendingCount = $pending.Count
    if ($pendingCount -eq 0) {
        Write-Host ""
        Write-Log ("Models summary: $downloadedCount downloaded, $skippedCount skipped, $failedCount failed (of $totalCount selected)") -Level "success"
        Write-Log "Models directory: $ModelsDir" -Level "info"
        return
    }

    # Pending size totals for the progress indicator
    $pendingTotalGB = 0.0
    foreach ($p in $pending) { $pendingTotalGB += [double]$p.Model.fileSizeGB }
    $processedGB = 0.0
    Write-Host ""
    Write-Log ("Pending downloads: $pendingCount file(s), $([math]::Round($pendingTotalGB,1)) GB total") -Level "info"

    # -- Pass 2: optional batch (parallel) attempt ------------------------------
    $batchSuccessKeys = New-Object System.Collections.Generic.HashSet[string]
    $useBatch = $isParallelEnabled -and ($pendingCount -ge 2) -and ($null -ne (Get-Command aria2c.exe -ErrorAction SilentlyContinue))

    if ($useBatch) {
        Write-Log "Parallel batch mode: $pendingCount file(s) via aria2c (concurrency=$batchMaxConcurrent)" -Level "info"
        $batchItems = foreach ($p in $pending) {
            [pscustomobject]@{
                Key     = $p.Model.id
                Uri     = $p.Model.downloadUrl
                OutFile = $p.OutputPath
                Label   = $p.Model.displayName
            }
        }
        $batchResults = Invoke-Aria2BatchDownload -Items $batchItems `
            -MaxConcurrent $batchMaxConcurrent `
            -ConnectionsPerServer $batchConnsPerServer `
            -SplitsPerFile $batchSplits `
            -ContinueDownload $isContinue

        if ($null -ne $batchResults) {
            foreach ($p in $pending) {
                $key = $p.Model.id
                $isOk = $batchResults.ContainsKey($key) -and $batchResults[$key]
                if ($isOk) { [void]$batchSuccessKeys.Add($key) }
            }
        } else {
            Write-Log "[FALLBACK] Batch unavailable; reverting all $pendingCount file(s) to sequential." -Level "warn"
        }
    } elseif ($pendingCount -eq 1) {
        Write-Log "Single pending download -- skipping batch mode (no parallelism benefit)." -Level "info"
    } elseif (-not $isParallelEnabled) {
        Write-Log "Parallel downloads disabled in config -- using sequential mode." -Level "info"
    }

    # -- Pass 3: per-file finalize (verify+track for batch wins, sequential for misses) --
    $progressIdx = 0
    foreach ($p in $pending) {
        $progressIdx++
        $model        = $p.Model
        $outputPath   = $p.OutputPath
        $trackingName = $p.TrackingName

        $isBatchHit = $batchSuccessKeys.Contains($model.id)

        $remaining = $pendingCount - $progressIdx
        $modeTag   = if ($isBatchHit) { "[PARALLEL]" } elseif ($useBatch) { "[FALLBACK]" } else { "[SEQUENTIAL]" }
        $bar       = Format-Bar -Done ($progressIdx - 1) -Total $pendingCount
        $pctFiles  = [int][math]::Round((($progressIdx - 1) / [double]$pendingCount) * 100)
        $pctBytes  = if ($pendingTotalGB -gt 0) { [int][math]::Round(($processedGB / $pendingTotalGB) * 100) } else { 0 }

        Write-Host ""
        Write-Log ("  Progress $bar $progressIdx/$pendingCount files ($pctFiles%) | $([math]::Round($processedGB,1))/$([math]::Round($pendingTotalGB,1)) GB ($pctBytes%) | $remaining remaining | mode=$modeTag") -Level "info"

        if ($isBatchHit) {
            Write-Log "  [$($model.index)] $modeTag $($model.displayName) -- verifying ($($model.fileSizeGB) GB)" -Level "info"
            $isDownloadOk = $true
        } else {
            $logLevel = if ($useBatch) { "warn" } else { "info" }
            Write-Log "  [$($model.index)] $modeTag Downloading: $($model.displayName)" -Level $logLevel
            Write-Log "    $($model.parameters) | $($model.quantization) | $($model.fileSizeGB) GB | RAM: $($model.ramRequiredGB)+ GB" -Level "info"
            Write-Log "    $($model.bestFor)" -Level "info"

            $isDownloadOk = Invoke-Aria2Download -Uri $model.downloadUrl -OutFile $outputPath -Label $model.displayName `
                -MaxConnections $maxConn -MaxDownloads $maxDl -ChunkSize $chunkSize -ContinueDownload $isContinue
        }

        if (-not $isDownloadOk) {
            Write-Log "  [$($model.index)] FAILED: $($model.displayName)" -Level "error"
            Write-FileError -FilePath $outputPath -Operation "download" -Reason "Download failed after retries" -Module "Install-SelectedModels"
            $failedCount++
            $processedGB += [double]$model.fileSizeGB
            continue
        }

        # SHA256 integrity verification (shared between batch + sequential)
        $isChecksumOk = $true
        $hasChecksum  = -not [string]::IsNullOrWhiteSpace($model.sha256)
        if ($hasChecksum) {
            Write-Log "    [VERIFY] SHA256 for $($model.fileName)" -Level "info"
            $actualHash   = (Get-FileHash -Path $outputPath -Algorithm SHA256).Hash.ToLower()
            $expectedHash = $model.sha256.Trim().ToLower()

            if ($actualHash -eq $expectedHash) {
                Write-Log "    Checksum verified: $($actualHash.Substring(0, 16))..." -Level "success"
            } else {
                Write-Log "    Checksum MISMATCH for $($model.displayName)" -Level "error"
                Write-Log "      Expected: $expectedHash" -Level "error"
                Write-Log "      Actual:   $actualHash" -Level "error"
                Write-FileError -FilePath $outputPath -Operation "checksum" -Reason "SHA256 mismatch (expected $expectedHash, got $actualHash)" -Module "Install-SelectedModels"
                $isChecksumOk = $false
            }
        }

        if ($isChecksumOk) {
            $method = if ($isBatchHit) { "aria2c-batch" } else { "aria2c" }
            Write-Log "  [$($model.index)] Downloaded: $($model.displayName)" -Level "success"
            Save-InstalledRecord -Name $trackingName -Version $model.quantization -Method $method
            $downloadedCount++
        } else {
            Write-Log "  [$($model.index)] FAILED (checksum): $($model.displayName)" -Level "error"
            if (Test-Path $outputPath) {
                try { Remove-Item $outputPath -Force } catch { }
            }
            $failedCount++
        }

        $processedGB += [double]$model.fileSizeGB
    }

    # Summary
    Write-Host ""
    $finalBar = Format-Bar -Done $pendingCount -Total $pendingCount
    Write-Log ("  Progress $finalBar $pendingCount/$pendingCount files (100%) | done") -Level "success"
    Write-Log ("Models summary: $downloadedCount downloaded, $skippedCount skipped, $failedCount failed (of $totalCount selected)") -Level "success"
    Write-Log "Models directory: $ModelsDir" -Level "info"
}

function Invoke-ModelInstaller {
    <#
    .SYNOPSIS
        Main entry point for the interactive model installer.
        Loads catalog, shows picker, downloads selected models.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CatalogPath,

        [Parameter(Mandatory)]
        [string]$DevDir,

        [string]$DefaultModelsSubfolder = "llama-models",

        $Aria2Config,
        $DownloadConfig,
        $LogMessages
    )

    # Load catalog
    $isFilePresent = Test-Path $CatalogPath
    if (-not $isFilePresent) {
        Write-Log "Models catalog not found: $CatalogPath" -Level "error"
        Write-FileError -FilePath $CatalogPath -Operation "load" -Reason "File not found" -Module "Invoke-ModelInstaller"
        return
    }

    $catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json
    $models  = $catalog.models
    Write-Log "Loaded model catalog: $($models.Count) models available." -Level "info"

    # -- Resolve models directory -----------------------------------------------
    $defaultModelsDir = Join-Path $DevDir $DefaultModelsSubfolder

    $modelsDir = $defaultModelsDir
    $isOrchestratorRun = $env:SCRIPTS_ROOT_RUN -eq "1"

    if (-not $isOrchestratorRun) {
        Write-Host ""
        Write-Host "  Default models directory: $defaultModelsDir" -ForegroundColor Cyan
        $userInput = Read-Host -Prompt "  Enter models directory (press Enter for default) [$defaultModelsDir]"
        $hasUserInput = -not [string]::IsNullOrWhiteSpace($userInput)
        if ($hasUserInput) {
            $modelsDir = $userInput.Trim()
        }
    } else {
        Write-Log "Orchestrator mode: using default models directory." -Level "info"
    }

    # Create directory
    $isDirMissing = -not (Test-Path $modelsDir)
    if ($isDirMissing) {
        New-Item -Path $modelsDir -ItemType Directory -Force | Out-Null
    }
    Write-Log "Models directory: $modelsDir" -Level "info"

    # -- Ensure aria2c --------------------------------------------------------
    $isAria2Ok = Assert-Aria2c
    if ($isAria2Ok) {
        Write-Log "aria2c download accelerator ready." -Level "success"
    } else {
        Write-Log "aria2c unavailable, using standard downloader as fallback." -Level "warn"
    }

    # -- Honor LLAMA_CPP_INSTALL_IDS env var (set by scripts/models orchestrator) --
    # When present, skip filters + prompts entirely and install only the
    # requested ids (CSV, exact or partial match against catalog `id`).
    $csvIds = $env:LLAMA_CPP_INSTALL_IDS
    $hasCsvOverride = -not [string]::IsNullOrWhiteSpace($csvIds)

    if ($hasCsvOverride) {
        Write-Log "LLAMA_CPP_INSTALL_IDS detected: $csvIds -- non-interactive mode" -Level "info"
        $requestedIds = @($csvIds -split '[,\s]+' | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_.Trim().ToLower() })

        $matched = @()
        foreach ($rid in $requestedIds) {
            $hit = $models | Where-Object { $_.id.ToLower() -eq $rid } | Select-Object -First 1
            if (-not $hit) {
                $hit = $models | Where-Object { $_.id.ToLower() -like "*$rid*" } | Select-Object -First 1
            }
            if ($hit) {
                Write-Log "  Matched '$rid' -> $($hit.id)" -Level "success"
                $matched += $hit
            } else {
                Write-Log "  No match for id '$rid' in llama.cpp catalog." -Level "warn"
            }
        }

        $hasMatches = $matched.Count -gt 0
        if (-not $hasMatches) {
            Write-Log "No matching models found for LLAMA_CPP_INSTALL_IDS. Aborting." -Level "error"
            return $modelsDir
        }

        # Re-index matched subset and skip the picker
        $idx = 1
        foreach ($m in $matched) { $m.index = $idx; $idx++ }
        $displayModels = $matched
        $selectedIndices = @(1..$matched.Count)
        Show-ModelCatalog -Models $displayModels
    }
    else {
        # -- Filters (interactive only) -----------------------------------------
        $displayModels = $models
        if (-not $isOrchestratorRun) {
            $displayModels = Read-RamFilter -Models $models
            $displayModels = Read-SizeFilter -Models $displayModels
            $displayModels = Read-SpeedFilter -Models $displayModels
            $displayModels = Read-CapabilityFilter -Models $displayModels
        }

        # -- Show catalog and get selection ------------------------------------
        Show-ModelCatalog -Models $displayModels

        if ($isOrchestratorRun) {
            Write-Log "Orchestrator mode: downloading all models." -Level "info"
            $selectedIndices = @(1..$displayModels.Count)
        } else {
            $selectedIndices = Read-ModelSelection -MaxIndex $displayModels.Count
            if ($null -eq $selectedIndices -or $selectedIndices.Count -eq 0) {
                Write-Log "No models selected. Skipping model downloads." -Level "info"
                return $modelsDir
            }
        }
    }

    # Map filtered indices back to original models for download
    $downloadModels = $displayModels

    # -- Disk space pre-check --------------------------------------------------
    $selectedModels = @($downloadModels | Where-Object { $selectedIndices -contains $_.index })
    $totalBytes = 0
    foreach ($m in $selectedModels) {
        $totalBytes += [long]($m.fileSizeGB * 1073741824)
    }
    $isSpaceOk = Test-DiskSpace -TargetPath $modelsDir -RequiredBytes $totalBytes -Label "selected models" -WarnOnly
    if (-not $isSpaceOk) {
        Write-Log "Proceeding despite low disk space warning..." -Level "warn"
    }

    # -- Download selected models ----------------------------------------------
    Install-SelectedModels -Models $downloadModels -SelectedIndices $selectedIndices `
        -ModelsDir $modelsDir -Aria2Config $Aria2Config -DownloadConfig $DownloadConfig `
        -LogMessages $LogMessages

    return $modelsDir
}
