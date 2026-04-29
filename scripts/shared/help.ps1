<#
.SYNOPSIS
    Shared --help display helper.

.DESCRIPTION
    Provides Show-ScriptHelp for consistent help output across all scripts.
    Supports two calling conventions:
      Old-style: Show-ScriptHelp -Name -Version -Description -Commands -Flags -Examples
      New-style: Show-ScriptHelp -LogMessages $logMessages
#>

# -- Bootstrap shared log messages --------------------------------------------
if (-not (Get-Variable -Name SharedLogMessages -Scope Script -ErrorAction SilentlyContinue)) {
    $sharedLogPath = Join-Path $PSScriptRoot "log-messages.json"
    $isSharedLogFound = Test-Path $sharedLogPath
    if ($isSharedLogFound) {
        $script:SharedLogMessages = Get-Content $sharedLogPath -Raw | ConvertFrom-Json
    }
}

function Show-ScriptHelp {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Description,
        [hashtable[]]$Commands = @(),
        [string[]]$Examples = @(),
        [hashtable[]]$Flags = @(),
        [PSObject]$LogMessages
    )

    $slm = $script:SharedLogMessages

    # New-style: extract from LogMessages object
    if ($LogMessages) {
        # ----- helpers (local) ------------------------------------------------
        # Read a property off a PSCustomObject without throwing under StrictMode.
        function _GetProp {
            param($Obj, [string]$Name)
            if ($null -eq $Obj) { return $null }
            $hasName = $false
            try {
                if ($Obj.PSObject -and $Obj.PSObject.Properties) {
                    $hasName = ($Obj.PSObject.Properties.Name -contains $Name)
                }
            } catch { $hasName = $false }
            if ($hasName) { return $Obj.$Name } else { return $null }
        }
        # Convert either { "k": "v", ... } OR [ { Name=..; Description=.. }, ... ]
        # OR [ "string", ... ] into an array of @{ Name=..; Description=.. }.
        function _NormalizePairs {
            param($Node)
            $out = @()
            if ($null -eq $Node) { return $out }
            if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
                foreach ($el in $Node) {
                    if ($el -is [string]) {
                        $out += @{ Name = ''; Description = $el }
                    } elseif ($el.PSObject -and $el.PSObject.Properties.Name -contains 'Name') {
                        $desc = if ($el.PSObject.Properties.Name -contains 'Description') { $el.Description } else { '' }
                        $out += @{ Name = $el.Name; Description = $desc }
                    }
                }
                return $out
            }
            # Treat as dict-shaped PSCustomObject.
            if ($Node.PSObject -and $Node.PSObject.Properties) {
                foreach ($prop in $Node.PSObject.Properties) {
                    $out += @{ Name = $prop.Name; Description = "$($prop.Value)" }
                }
            }
            return $out
        }

        # ----- Name + description (with aliases) -----------------------------
        $candName = _GetProp $LogMessages 'scriptName'
        if (-not $Name -and $candName) { $Name = "$candName" }

        if (-not $Description) {
            $candDesc = _GetProp $LogMessages 'description'
            if (-not $candDesc) { $candDesc = _GetProp $LogMessages 'synopsis' }
            if (-not $candDesc) { $candDesc = _GetProp $LogMessages 'scriptDesc' }
            if (-not $candDesc) { $candDesc = _GetProp $LogMessages 'scriptTitle' }
            if (-not $candDesc) {
                $msgsNode = _GetProp $LogMessages 'messages'
                $candDesc = _GetProp $msgsNode 'scriptDesc'
                if (-not $candDesc) { $candDesc = _GetProp $msgsNode 'scriptTitle' }
            }
            if ($candDesc) { $Description = "$candDesc" }
        }

        $helpNode = _GetProp $LogMessages 'help'

        # ----- Commands (help.commands | help.subverbs) ----------------------
        if ($Commands.Count -eq 0 -and $helpNode) {
            $cmdNode = _GetProp $helpNode 'commands'
            if (-not $cmdNode) { $cmdNode = _GetProp $helpNode 'subverbs' }
            $Commands = _NormalizePairs $cmdNode
        }

        # ----- Flags (help.parameters | help.flags) --------------------------
        if ($Flags.Count -eq 0 -and $helpNode) {
            $flagNode = _GetProp $helpNode 'parameters'
            if (-not $flagNode) { $flagNode = _GetProp $helpNode 'flags' }
            $Flags = _NormalizePairs $flagNode
        }

        # Auto-inject -Path parameter if not already listed AND this looks
        # like a script that uses -Path (only when other -Foo flags exist).
        $hasPathFlag = $false
        foreach ($f in $Flags) { if ($f.Name -eq '-Path') { $hasPathFlag = $true; break } }
        $hasDashFlag = $false
        foreach ($f in $Flags) { if ("$($f.Name)".StartsWith('-') -and -not "$($f.Name)".StartsWith('--')) { $hasDashFlag = $true; break } }
        if (-not $hasPathFlag -and $hasDashFlag) {
            $Flags += @{ Name = "-Path"; Description = "Custom dev directory path (overrides smart detection)" }
        }

        # ----- Examples (help.examples | top-level usage | top-level examples)
        if ($Examples.Count -eq 0) {
            $exNode = if ($helpNode) { _GetProp $helpNode 'examples' } else { $null }
            if (-not $exNode) { $exNode = _GetProp $LogMessages 'usage' }
            if (-not $exNode) { $exNode = _GetProp $LogMessages 'examples' }
            if ($exNode) { $Examples = @($exNode) }
        }
    }

    # -- Auto-resolve version from scripts/version.json if not provided -------
    if ([string]::IsNullOrWhiteSpace($Version)) {
        try {
            $versionJsonPath = Join-Path (Split-Path $PSScriptRoot -Parent) "version.json"
            if (Test-Path $versionJsonPath) {
                $vJson = Get-Content $versionJsonPath -Raw | ConvertFrom-Json
                if ($vJson -and $vJson.version) { $Version = "$($vJson.version)" }
            }
        } catch {}
    }

    Write-Host ""
    $headerLine = $slm.messages.helpHeader -replace '\{name\}', $Name -replace '\{version\}', $Version
    Write-Host $headerLine -ForegroundColor Cyan
    $descLine = $slm.messages.helpDescription -replace '\{description\}', $Description
    Write-Host $descLine -ForegroundColor Gray

    # -- Version detection (versionDetect array in log-messages.json) ----------
    $hasVersionDetect = $LogMessages -and $LogMessages.PSObject.Properties.Name -contains "versionDetect"
    if ($hasVersionDetect) {
        Write-Host ""
        foreach ($probe in $LogMessages.versionDetect) {
            $probeCmd  = $probe.command
            $probeFlag = if ($probe.PSObject.Properties.Name -contains "flag") { $probe.flag } else { "--version" }
            $probeLabel = if ($probe.PSObject.Properties.Name -contains "label") { $probe.label } else { $probeCmd }

            $cmdInfo = Get-Command $probeCmd -ErrorAction SilentlyContinue
            $isCmdFound = $null -ne $cmdInfo
            if ($isCmdFound) {
                $rawVersion = $null
                $flagArgs = $probeFlag -split '\s+'
                try { $rawVersion = & $probeCmd @flagArgs 2>$null } catch {}

                $versionText = "$rawVersion".Trim()
                $hasVersion = -not [string]::IsNullOrWhiteSpace($versionText)
                if ($hasVersion) {
                    Write-Host "    $probeLabel : " -NoNewline -ForegroundColor Gray
                    Write-Host $versionText -ForegroundColor Green
                } else {
                    Write-Host "    $probeLabel : " -NoNewline -ForegroundColor Gray
                    Write-Host "(installed, version unknown)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    $probeLabel : " -NoNewline -ForegroundColor Gray
                Write-Host "not installed" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ""

    if ($Commands.Count -gt 0) {
        Write-Host $slm.messages.helpCommandsLabel -ForegroundColor Yellow
        foreach ($cmd in $Commands) {
            $label = "{0,-16}" -f $cmd.Name
            $line = $slm.messages.helpCommandItem -replace '\{label\}', $label -replace '\{description\}', $cmd.Description
            Write-Host $line -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($Flags.Count -gt 0) {
        Write-Host $slm.messages.helpParametersLabel -ForegroundColor Yellow
        foreach ($flag in $Flags) {
            $label = "{0,-16}" -f $flag.Name
            $line = $slm.messages.helpParameterItem -replace '\{label\}', $label -replace '\{description\}', $flag.Description
            Write-Host $line -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($Examples.Count -gt 0) {
        Write-Host $slm.messages.helpExamplesLabel -ForegroundColor Yellow
        foreach ($ex in $Examples) {
            $line = $slm.messages.helpExampleItem -replace '\{example\}', $ex
            Write-Host $line -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # -- Footer with version ---------------------------------------------------
    $footerTpl = $slm.messages.helpFooter
    if ($footerTpl) {
        $footerLine = $footerTpl -replace '\{version\}', $Version -replace '\{name\}', $Name
        Write-Host $footerLine -ForegroundColor DarkCyan
        Write-Host ""
    }
}
