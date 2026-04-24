# --------------------------------------------------------------------------
#  helpers/regen-models-list.ps1
#  Regenerates models-list.md from models-catalog.json.
#
#  Public functions:
#    Invoke-ModelsListRegen  -- main entry point
#
#  Replaces the one-off /tmp/gen_models_list.py script. Pure PowerShell;
#  no Python dependency. Outputs the same markdown shape: header, capability
#  table, leaderboard table, per-family tables, filters explainer, and the
#  >=64 GB datacenter section.
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

# Em dash (U+2014). The original models-list.md uses em dashes in prose.
# Hard-coded as a unicode escape so this source file stays ASCII-safe and
# survives any encoding round-trip (matches the user's banner-safety rule).
$script:EmDash = [string][char]0x2014
# Black star (U+2605) used to mark curated models in the catalog/markdown.
$script:Star   = [string][char]0x2605

function Format-SizeGB {
    # Match Python's repr/str(float): shortest round-trip representation
    # but always at least one decimal digit (e.g. 8.4, 0.075, 130.0).
    param([Parameter(Mandatory)] [double] $Value)
    # "R" round-trips the value to the shortest exact representation.
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $s = $Value.ToString("R", $invariant)
    $hasDot = $s.Contains(".")
    if (-not $hasDot) { $s = "$s.0" }
    return $s
}

function Get-ModelTier {
    param([Parameter(Mandatory)] [double] $SizeGB)
    if ($SizeGB -lt 1)  { return "Tiny"   }
    if ($SizeGB -lt 3)  { return "Small"  }
    if ($SizeGB -lt 6)  { return "Medium" }
    if ($SizeGB -lt 12) { return "Large"  }
    return "XLarge"
}

function Get-ModelSpeed {
    param([Parameter(Mandatory)] [double] $SizeGB)
    if ($SizeGB -lt 1) { return "Instant"  }
    if ($SizeGB -lt 3) { return "Fast"     }
    if ($SizeGB -lt 8) { return "Moderate" }
    return "Slow"
}

function Get-ModelCapabilities {
    param([Parameter(Mandatory)] [psobject] $Model)
    $caps = @()
    if ($Model.isCoding)       { $caps += "Coding"       }
    if ($Model.isReasoning)    { $caps += "Reasoning"    }
    if ($Model.isWriting)      { $caps += "Writing"      }
    if ($Model.isVoice)        { $caps += "Voice"        }
    if ($Model.isMultilingual) { $caps += "Multilingual" }
    if ($Model.isChat)         { $caps += "Chat"         }
    if ($caps.Count -eq 0)     { return "-" }
    return ($caps -join ", ")
}

function Format-ModelRow {
    param([Parameter(Mandatory)] [psobject] $Model)
    $sizeGB  = [double]$Model.fileSizeGB
    $tier    = Get-ModelTier  -SizeGB $sizeGB
    $speed   = Get-ModelSpeed -SizeGB $sizeGB
    $caps    = Get-ModelCapabilities -Model $Model
    $coding  = "$($Model.rating.coding)/10"
    $reason  = "$($Model.rating.reasoning)/10"
    $hf      = if ($Model.huggingfacePage) { $Model.huggingfacePage } else { $Model.downloadUrl }
    $sizeFmt = Format-SizeGB -Value $sizeGB
    return "| ``$($Model.id)`` | $($Model.displayName) | $($Model.parameters) | $sizeFmt | $tier | $speed | $($Model.ramRequiredGB) | $caps | $coding | $reason | $($Model.quantization) | $($Model.license) | [HF]($hf) |"
}

function Invoke-ModelsListRegen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CatalogPath,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $isCatalogMissing = -not (Test-Path -LiteralPath $CatalogPath)
    if ($isCatalogMissing) {
        Write-Log "Catalog file not found: $CatalogPath (failure: cannot regenerate models-list.md without source catalog)" -Level "error"
        return $false
    }

    try {
        $raw     = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop
        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Failed to parse catalog JSON: $CatalogPath (failure: $($_.Exception.Message))" -Level "error"
        return $false
    }

    $hasModels = $catalog.PSObject.Properties.Name -contains "models"
    if (-not $hasModels) {
        Write-Log "Catalog has no 'models' array: $CatalogPath (failure: schema mismatch)" -Level "error"
        return $false
    }

    $models       = @($catalog.models)
    $totalCount   = $models.Count
    $hasCatVer    = $catalog.PSObject.Properties.Name -contains "catalogVersion"
    $hasVer       = $catalog.PSObject.Properties.Name -contains "version"
    if ($hasCatVer)  { $version = $catalog.catalogVersion }
    elseif ($hasVer) { $version = $catalog.version        }
    else             { $version = "unknown"               }
    $familyGroups = $models | Group-Object -Property family | Sort-Object Name
    $familyCount  = $familyGroups.Count

    $sb = New-Object System.Text.StringBuilder

    # -- Header ---------------------------------------------------------------
    [void]$sb.AppendLine("# Local AI Models Catalog")
    [void]$sb.AppendLine("> $totalCount downloadable GGUF models for ``llama.cpp`` (script ``43-install-llama-cpp``).")
    [void]$sb.AppendLine("> Catalog version **$version** $($script:EmDash) auto-grouped by family, size, capability.")
    [void]$sb.AppendLine("> Models marked **$($script:Star)** are curated picks. Models tagged **[Leaderboard #N]** are the open-weight portion of the OpenRouter LLM Leaderboard (Nov 2025).")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Quick install")
    [void]$sb.AppendLine('```powershell')
    [void]$sb.AppendLine('# Interactive picker (4-filter chain: RAM -> Size -> Speed -> Capability)')
    [void]$sb.AppendLine('.\run.ps1 install llama-cpp')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Direct CSV install (skip filters, picks by id)')
    [void]$sb.AppendLine('.\run.ps1 models qwen2.5-coder-3b,phi-4-mini-3.8b,gemma-3-4b-it')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Browse without installing')
    [void]$sb.AppendLine('.\run.ps1 models list llama')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Capability flags")
    [void]$sb.AppendLine("| Flag | Meaning |")
    [void]$sb.AppendLine("|---|---|")
    [void]$sb.AppendLine("| ``isCoding`` | Model is trained/optimized for code generation, completion, and debugging |")
    [void]$sb.AppendLine("| ``isReasoning`` | Model supports chain-of-thought, step-by-step logical reasoning |")
    [void]$sb.AppendLine("| ``isVoice`` | Model supports voice/audio input or output (speech-to-text, TTS) |")
    [void]$sb.AppendLine("| ``isWriting`` | Model is good at creative writing, long-form content, essays, documentation |")
    [void]$sb.AppendLine("| ``isMultilingual`` | Model supports multiple human languages (not just English) |")
    [void]$sb.AppendLine("| ``isChat`` | Model is optimized for conversational/chat interactions |")
    [void]$sb.AppendLine("| ``leaderboardRank`` | Position on OpenRouter LLM Leaderboard (Nov 2025) if applicable. Open-weight models only. |")
    [void]$sb.AppendLine("")

    # -- Leaderboard section --------------------------------------------------
    $hasRankProp = { param($m) ($m.PSObject.Properties.Name -contains "leaderboardRank") -and ($null -ne $m.leaderboardRank) }
    $leaderboardModels = @($models | Where-Object { & $hasRankProp $_ } | Sort-Object -Property leaderboardRank)
    if ($leaderboardModels.Count -gt 0) {
        [void]$sb.AppendLine("## OpenRouter Leaderboard (Open-Weight Coverage)")
        [void]$sb.AppendLine("Source: OpenRouter LLM Leaderboard, Nov 2025. Closed-source API models (Claude, GPT-5.4, Gemini, Grok) are intentionally excluded $($script:EmDash) this catalog only ships locally-runnable GGUF models.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| Rank | Model | Size (GB) | RAM (GB) | Capabilities | Source |")
        [void]$sb.AppendLine("|---|---|---|---|---|---|")
        foreach ($m in $leaderboardModels) {
            $caps    = Get-ModelCapabilities -Model $m
            $sizeFmt = Format-SizeGB -Value ([double]$m.fileSizeGB)
            $hf      = if ($m.huggingfacePage) { $m.huggingfacePage } else { $m.downloadUrl }
            [void]$sb.AppendLine("| $($m.leaderboardRank) | [$($m.displayName)]($hf) | $sizeFmt | $($m.ramRequiredGB)+ | $caps | $($m.source) |")
        }
        [void]$sb.AppendLine("")
    }

    # -- Per-family tables ---------------------------------------------------
    [void]$sb.AppendLine("## All Models by Family")
    [void]$sb.AppendLine("")
    foreach ($group in $familyGroups) {
        [void]$sb.AppendLine("### $($group.Name) ($($group.Count))")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |")
        [void]$sb.AppendLine("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        # Stable sort by file size only -- preserves catalog (JSON) order on ties.
        $sortedFamilyModels = $group.Group | Sort-Object -Stable -Property @{ Expression = { [double]$_.fileSizeGB } }
        foreach ($m in $sortedFamilyModels) {
            [void]$sb.AppendLine((Format-ModelRow -Model $m))
        }
        [void]$sb.AppendLine("")
    }

    # -- Filters explainer ---------------------------------------------------
    [void]$sb.AppendLine("## Filters (interactive picker)")
    [void]$sb.AppendLine("The picker chains four optional filters; press Enter at any prompt to skip.")
    [void]$sb.AppendLine("1. **RAM** $($script:EmDash) auto-detects system RAM, presets 4/8/16/32/64 GB, free input.")
    [void]$sb.AppendLine("2. **Size** $($script:EmDash) Tiny <1, Small <3, Medium <6, Large <12, XLarge 12+ GB.")
    [void]$sb.AppendLine("3. **Speed** $($script:EmDash) Instant <1, Fast <3, Moderate <8, Slow 8+ GB.")
    [void]$sb.AppendLine("4. **Capability** $($script:EmDash) Coding / Reasoning / Writing / Chat / Voice / Multilingual.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("After filtering, surviving models are re-indexed ``1..N`` so you can multi-select with ``1,3,5`` or ``1-4``.")
    [void]$sb.AppendLine("")

    # -- Datacenter-class section -------------------------------------------
    $datacenter = @($models | Where-Object { [int]$_.ramRequiredGB -ge 64 } | Sort-Object -Property @{ Expression = { -[double]$_.fileSizeGB } })
    if ($datacenter.Count -gt 0) {
        [void]$sb.AppendLine("## Datacenter-class models (>=64 GB RAM)")
        [void]$sb.AppendLine("$($datacenter.Count) models require workstation/server hardware:")
        [void]$sb.AppendLine("")
        foreach ($m in $datacenter) {
            $sizeFmt = Format-SizeGB -Value ([double]$m.fileSizeGB)
            [void]$sb.AppendLine("- ``$($m.id)`` $($script:EmDash) $($m.displayName) $($script:EmDash) **$sizeFmt GB file, $($m.ramRequiredGB) GB RAM**")
        }
        [void]$sb.AppendLine("")
    }

    # -- See also -----------------------------------------------------------
    [void]$sb.AppendLine("## See also")
    [void]$sb.AppendLine("- [``scripts/43-install-llama-cpp/readme.md``](readme.md) $($script:EmDash) installer script docs")
    [void]$sb.AppendLine("- [``scripts/models/``](../models/) $($script:EmDash) unified backend orchestrator (llama.cpp + Ollama)")
    [void]$sb.AppendLine("- [``scripts/42-install-ollama/readme.md``](../42-install-ollama/readme.md) $($script:EmDash) Ollama daemon backend")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("*Generated from ``models-catalog.json`` v$version $($script:EmDash) $totalCount models, $familyCount families*")

    # -- Atomic write -------------------------------------------------------
    $tempPath = "$OutputPath.tmp"
    try {
        Set-Content -LiteralPath $tempPath -Value $sb.ToString() -Encoding UTF8 -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force -ErrorAction Stop
    } catch {
        Write-Log "Failed to write models-list.md: $OutputPath (failure: $($_.Exception.Message))" -Level "error"
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    Write-Log "Regenerated models-list.md: $OutputPath ($totalCount models, $familyCount families)" -Level "success"
    return $true
}