# ---------------------------------------------------------------------------
# Script 53 -- helpers/precheck.ps1
#
# Pre-flight inspection: for every (edition, target) pair this reports the
# CURRENT registry state and the PLANNED action (ENSURE / REMOVE / SKIP /
# NOOP) WITHOUT touching the registry. Used by the `precheck` / `dry-run` /
# `whatif` commands and also called automatically before the apply phase so
# the user always sees "what will change" before it changes.
#
# Returns: hashtable[] of plan rows. Also prints a colored table.
# ---------------------------------------------------------------------------

function _PreCheck-QueryKey {
    param([string]$RegistryPath)
    # Convert "Registry::HKEY_CLASSES_ROOT\..." to a reg.exe-friendly form.
    $regPath = $RegistryPath -replace '^Registry::',''
    $null = reg.exe query "$regPath" 2>&1
    return ($LASTEXITCODE -eq 0)
}

function _PreCheck-ReadDefault {
    param([string]$RegistryPath)
    $regPath = $RegistryPath -replace '^Registry::',''
    $cmdPath = "$regPath\command"
    $label   = $null
    $cmd     = $null
    try {
        $out = reg.exe query "$regPath" /ve 2>$null
        if ($LASTEXITCODE -eq 0) {
            $line = $out | Where-Object { $_ -match '\(Default\)' } | Select-Object -First 1
            if ($line) { $label = ($line -split 'REG_SZ',2)[-1].Trim() }
        }
        $out2 = reg.exe query "$cmdPath" /ve 2>$null
        if ($LASTEXITCODE -eq 0) {
            $line2 = $out2 | Where-Object { $_ -match '\(Default\)' } | Select-Object -First 1
            if ($line2) { $cmd = ($line2 -split 'REG_SZ',2)[-1].Trim() }
        }
    } catch { }
    return [pscustomobject]@{ Label = $label; Command = $cmd }
}

function Invoke-FolderRepairPreCheck {
    <#
    .SYNOPSIS
        Pre-flight inspection of folder + background context-menu state.

    .DESCRIPTION
        For every enabled edition + every configured target (removeFromTargets
        + ensureOnTargets), reports CURRENT state and PLANNED action without
        modifying the registry. Prints a colored table and returns the rows
        as a hashtable[] for callers (apply phase) to reuse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $LogMessages,
        [Parameter(Mandatory)] [string[]] $DetectedEditions,
        [Parameter(Mandatory)] [string]   $InstallType,
        [Parameter(Mandatory)] [string]   $ScriptDir,
        [switch] $ApplyMode  # if set, header says "Planned changes" instead of "Dry-run"
    )

    $removeTargets = @($Config.removeFromTargets)
    $ensureTargets = @($Config.ensureOnTargets)
    $rows = @()

    foreach ($editionName in $DetectedEditions) {
        $edition = $Config.editions.$editionName
        if (-not $edition) { continue }

        # Resolve VS Code exe (read-only -- never installs)
        $vsCodeExe = $null
        try {
            $vsCodeExe = Resolve-VsCodePath `
                -PathConfig    $edition.vscodePath `
                -PreferredType $InstallType `
                -ScriptDir     $ScriptDir `
                -EditionName   $editionName
        } catch { $vsCodeExe = $null }
        $isExeMissing = -not $vsCodeExe

        foreach ($target in $removeTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $present = _PreCheck-QueryKey -RegistryPath $regPath
            $plan    = if ($present) { 'REMOVE' } else { 'NOOP' }
            $reason  = if ($present) { 'present -- will be deleted (file-target leaf)' } else { 'already absent -- nothing to do' }
            $rows += @{
                Edition  = $editionName
                Target   = $target
                Path     = $regPath
                Current  = $(if ($present) { 'present' } else { 'absent' })
                Plan     = $plan
                Reason   = $reason
            }
        }

        foreach ($target in $ensureTargets) {
            $regPath = $edition.registryPaths.$target
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $present = _PreCheck-QueryKey -RegistryPath $regPath

            $plan   = $null
            $reason = $null
            if ($isExeMissing) {
                $plan   = 'SKIP'
                $reason = ("VS Code exe not found for edition '{0}' -- cannot ensure entry" -f $editionName)
            } elseif (-not $present) {
                $plan   = 'ENSURE'
                $reason = 'missing -- will be created'
            } else {
                # Present: check whether label / command match the desired state.
                $current = _PreCheck-ReadDefault -RegistryPath $regPath
                $labelOk = ($current.Label -eq $edition.contextMenuLabel)
                $cmdOk   = $false
                if ($current.Command) { $cmdOk = ($current.Command -like ("*""$vsCodeExe""*")) }
                if ($labelOk -and $cmdOk) {
                    $plan   = 'NOOP'
                    $reason = 'present and matches desired label + command'
                } else {
                    $plan = 'REPAIR'
                    $bits = @()
                    if (-not $labelOk) { $bits += ("label mismatch (have='{0}', want='{1}')" -f $current.Label, $edition.contextMenuLabel) }
                    if (-not $cmdOk)   { $bits += ("command mismatch (have='{0}', want exe='{1}')" -f $current.Command, $vsCodeExe) }
                    $reason = ($bits -join '; ')
                }
            }

            $rows += @{
                Edition = $editionName
                Target  = $target
                Path    = $regPath
                Current = $(if ($present) { 'present' } else { 'absent' })
                Plan    = $plan
                Reason  = $reason
            }
        }
    }

    Write-FolderRepairPreCheckTable -Rows $rows -ApplyMode:$ApplyMode -LogMessages $LogMessages
    return ,$rows
}

function Write-FolderRepairPreCheckTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable[]] $Rows,
        [Parameter(Mandatory)] $LogMessages,
        [switch] $ApplyMode
    )

    $title = if ($ApplyMode) { '  Pre-Check -- Planned Changes (will apply next)' } else { '  Pre-Check -- Dry Run (NO changes will be made)' }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host $title                                                          -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan

    if ($Rows.Count -eq 0) {
        Write-Host "  (no editions / targets to inspect)" -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor DarkCyan
        return
    }

    $fmt = "  {0,-10} {1,-12} {2,-9} {3,-7}  {4}"
    Write-Host ($fmt -f 'EDITION','TARGET','CURRENT','PLAN','PATH') -ForegroundColor Gray
    Write-Host "  ------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray

    $counts = @{ ENSURE = 0; REMOVE = 0; REPAIR = 0; NOOP = 0; SKIP = 0 }
    foreach ($r in $Rows) {
        $color = switch ($r.Plan) {
            'ENSURE' { 'Green' }
            'REMOVE' { 'Yellow' }
            'REPAIR' { 'Magenta' }
            'NOOP'   { 'DarkGray' }
            'SKIP'   { 'Red' }
            default  { 'White' }
        }
        Write-Host ($fmt -f $r.Edition, $r.Target, $r.Current, $r.Plan, $r.Path) -ForegroundColor $color
        if ($r.Reason) {
            Write-Host ("              -> {0}" -f $r.Reason) -ForegroundColor DarkGray
        }
        if ($counts.ContainsKey($r.Plan)) { $counts[$r.Plan]++ }
    }

    Write-Host "  ------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
    $changeCount = $counts.ENSURE + $counts.REMOVE + $counts.REPAIR
    $summary = "  TOTAL: {0}   ensure={1}   remove={2}   repair={3}   noop={4}   skip={5}   (changes={6})" -f `
        $Rows.Count, $counts.ENSURE, $counts.REMOVE, $counts.REPAIR, $counts.NOOP, $counts.SKIP, $changeCount
    $summaryColor = if ($counts.SKIP -gt 0) { 'Red' } elseif ($changeCount -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host $summary -ForegroundColor $summaryColor
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}
