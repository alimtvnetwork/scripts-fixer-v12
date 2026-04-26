<#
.SYNOPSIS
    Install logic for the VS Code menu installer (script 54).

.DESCRIPTION
    Writes the three context menu registry keys per edition (file, folder,
    folder background). Does NOT enumerate or touch any other registry
    location. Caller passes the resolved VS Code executable path.
#>

$_sharedDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Audit logger -- side-by-side helper. Loaded once; safe to dot-source again.
$_auditPath = Join-Path $PSScriptRoot "audit-log.ps1"
if ((Test-Path $_auditPath) -and -not (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue)) {
    . $_auditPath
}

function Get-HkcrSubkeyPath {
    param([string]$PsPath)
    return ($PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
}

function ConvertTo-RegExePath {
    param([string]$PsPath)
    $p = $PsPath -replace '^Registry::', ''
    return ($p -replace '^HKEY_CLASSES_ROOT', 'HKCR')
}

function Resolve-MenuScope {
    <#
    .SYNOPSIS
        Decides the install scope when the caller passes -Scope (or omits it).

    .DESCRIPTION
        Returns one of: 'CurrentUser', 'AllUsers'.

        - 'AllUsers'    -> writes to HKLM via the HKEY_CLASSES_ROOT view.
                          Requires admin. CALLER must enforce that.
        - 'CurrentUser' -> writes to HKCU\Software\Classes\... so no admin
                          rights are needed and the entries only affect the
                          user who ran the script.
        - 'Auto' (default) -> 'AllUsers' when running elevated, else
                              'CurrentUser'. This matches the user's stated
                              expectation and never silently downgrades a
                              caller who explicitly asked for AllUsers.

        Inputs are case-insensitive. Unknown values are rejected with a
        clear error that names the offending value -- no silent default.
    #>
    param(
        [string]$Requested,
        [bool]  $IsAdmin
    )

    $value = if ([string]::IsNullOrWhiteSpace($Requested)) { 'Auto' } else { $Requested.Trim() }
    switch ($value.ToLowerInvariant()) {
        'currentuser' { return 'CurrentUser' }
        'user'        { return 'CurrentUser' }
        'hkcu'        { return 'CurrentUser' }
        'allusers'    { return 'AllUsers' }
        'machine'     { return 'AllUsers' }
        'hklm'        { return 'AllUsers' }
        'auto'        {
            if ($IsAdmin) { return 'AllUsers' } else { return 'CurrentUser' }
        }
        default {
            throw "Invalid -Scope value '$Requested'. Use one of: Auto (default), CurrentUser, AllUsers."
        }
    }
}

function Write-ScopeAdminGuidance {
    <#
    .SYNOPSIS
        Print user-facing guidance about whether the current run needs to
        be re-launched from an elevated PowerShell, based on the requested
        and resolved -Scope plus the live admin token.

    .DESCRIPTION
        Centralizes the four cases every entry-point (install, uninstall,
        repair, sync) used to log inline:

        1. Requested=AllUsers, IsAdmin=false       -> BLOCK (returns $false)
           Loud, multi-line action plan: how to elevate, exact commands to
           re-run with -Scope AllUsers AND a fallback to -Scope CurrentUser
           that does NOT need admin. Mentions per-action verb so copy-paste
           is one keystroke away.

        2. Resolved=AllUsers, IsAdmin=false        -> BLOCK (returns $false)
           (Defensive -- Resolve-MenuScope's Auto branch never gets here,
           but a future scope mapping bug would surface clearly.)

        3. Resolved=AllUsers, IsAdmin=true         -> proceed (returns $true)
           One-line confirmation that the elevated session is doing the
           machine-wide write, including the exact hive (HKLM\Software\Classes).

        4. Resolved=CurrentUser                    -> proceed (returns $true)
           Friendly nudge: "no admin needed; this only affects YOU. To make
           the menu visible to every user on the box, re-run elevated with
           -Scope AllUsers." Skipped when the caller explicitly asked for
           CurrentUser -- they don't need to be told what they already chose.

        The helper writes via Write-Log so the toolkit's structured JSON
        log + console rendering both pick it up. Returns a bool the caller
        uses as the gate ($false -> exit early without doing damage).
    .PARAMETER Action
        The verb being run (install | uninstall | repair | sync). Drives
        the verb-specific text in the rerun command examples so the user
        can copy-paste without mental translation.
    .PARAMETER RequestedScope
        The raw -Scope value the user typed (or '' when omitted -> Auto).
    .PARAMETER ResolvedScope
        Output of Resolve-MenuScope: 'CurrentUser' or 'AllUsers'.
    .PARAMETER IsAdmin
        Live admin-token check from the entry-point script.
    .OUTPUTS
        [bool] $true  -> caller may proceed
               $false -> caller MUST return without writing the registry
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('install','uninstall','repair','sync')]
        [string] $Action,

        [Parameter(Mandatory)]
        [string] $RequestedScope,

        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser','AllUsers')]
        [string] $ResolvedScope,

        [Parameter(Mandatory)]
        [bool]   $IsAdmin
    )

    $isAllUsersRequested = ($RequestedScope -ieq 'AllUsers' -or
                            $RequestedScope -ieq 'Machine'  -or
                            $RequestedScope -ieq 'HKLM')
    $wasOmitted          = [string]::IsNullOrWhiteSpace($RequestedScope) -or ($RequestedScope -ieq 'Auto')
    $isAllUsersResolved  = ($ResolvedScope -eq 'AllUsers')

    # ---- BLOCK: AllUsers requested but no admin -------------------------
    if ($isAllUsersRequested -and -not $IsAdmin) {
        Write-Log "" -Level "error"
        Write-Log "============================================================" -Level "error"
        Write-Log " ELEVATION REQUIRED -- you asked for -Scope AllUsers"        -Level "error"
        Write-Log "============================================================" -Level "error"
        Write-Log ("AllUsers writes to HKEY_CLASSES_ROOT (physically " +
                   "HKLM\Software\Classes), which only Administrators can modify.") -Level "error"
        Write-Log ("Current process is NOT elevated, so the " + $Action +
                   " was BLOCKED before any registry change was attempted.") -Level "error"
        Write-Log "" -Level "info"
        Write-Log "ACTION REQUIRED -- pick ONE of the two options below:" -Level "warn"
        Write-Log "" -Level "info"
        Write-Log "  Option 1) Re-run elevated (machine-wide -- every user sees the menu):" -Level "info"
        Write-Log "    1. Right-click PowerShell -> 'Run as Administrator'." -Level "info"
        Write-Log ("    2. cd into the repo root, then run:") -Level "info"
        Write-Log ("       .\\run.ps1 -I 54 " + $Action + " -Scope AllUsers") -Level "info"
        Write-Log "" -Level "info"
        Write-Log "  Option 2) Stay in this NON-admin shell (only YOUR user sees the menu):" -Level "info"
        Write-Log ("       .\\run.ps1 -I 54 " + $Action + " -Scope CurrentUser") -Level "info"
        Write-Log "" -Level "info"
        Write-Log "Tip: -Scope Auto picks AllUsers when elevated, otherwise CurrentUser." -Level "info"
        return $false
    }

    # ---- BLOCK (defensive): resolver returned AllUsers but no admin -----
    if ($isAllUsersResolved -and -not $IsAdmin) {
        Write-Log "" -Level "error"
        Write-Log ("Resolved scope is AllUsers but this PowerShell is NOT " +
                   "elevated -- refusing to attempt machine-wide registry writes.") -Level "error"
        Write-Log ("ACTION: re-run from an elevated PowerShell:  " +
                   ".\\run.ps1 -I 54 " + $Action + " -Scope AllUsers") -Level "warn"
        Write-Log ("Or, if you only want to affect the current user (no admin needed):  " +
                   ".\\run.ps1 -I 54 " + $Action + " -Scope CurrentUser") -Level "warn"
        return $false
    }

    # ---- PROCEED: AllUsers + admin --------------------------------------
    if ($isAllUsersResolved -and $IsAdmin) {
        Write-Log ("Proceeding with -Scope AllUsers (elevated session detected). " +
                   "Writes will land in HKLM\\Software\\Classes and be visible " +
                   "to EVERY user on this machine.") -Level "success"
        return $true
    }

    # ---- PROCEED: CurrentUser -------------------------------------------
    # Only nudge about elevation when the user did NOT explicitly choose
    # CurrentUser -- otherwise we're telling them what they already know.
    if ($wasOmitted) {
        Write-Log ("Auto-resolved scope to CurrentUser (no admin token). " +
                   "Writes will land in HKCU\\Software\\Classes and be visible " +
                   "ONLY to the current user (" + $env:USERNAME + ").") -Level "info"
        Write-Log ("Want every user on this machine to see the menu? Re-run " +
                   "from an elevated PowerShell:  .\\run.ps1 -I 54 " + $Action +
                   " -Scope AllUsers") -Level "info"
    } else {
        Write-Log ("Proceeding with -Scope CurrentUser (no admin needed). " +
                   "Writes will land in HKCU\\Software\\Classes and be visible " +
                   "ONLY to user '" + $env:USERNAME + "'.") -Level "info"
    }
    return $true
}

function Convert-MenuPathForScope {
    <#
    .SYNOPSIS
        Translates a Registry::HKEY_CLASSES_ROOT\... path to the equivalent
        per-user path under HKCU\Software\Classes when Scope='CurrentUser'.
        For Scope='AllUsers' the path is returned unchanged so the existing
        HKCR-via-HKLM behavior is preserved bit-for-bit.

    .NOTES
        HKCR is a merged view: writes through HKCR land in HKLM (machine
        scope, requires admin). To install an entry for the current user
        only, we must write to HKCU\Software\Classes directly. Reads from
        HKCR will still see HKCU entries because Windows merges both hives.
    #>
    param(
        [Parameter(Mandatory)] [string] $PsPath,
        [Parameter(Mandatory)] [ValidateSet('CurrentUser','AllUsers')] [string] $Scope
    )

    if ($Scope -eq 'AllUsers') { return $PsPath }

    # CurrentUser: rewrite the hive segment only; everything after stays put.
    $rewritten = $PsPath -replace '^Registry::HKEY_CLASSES_ROOT\\', 'Registry::HKEY_CURRENT_USER\Software\Classes\'
    return $rewritten
}

function Convert-EditionPathsForScope {
    <#
    .SYNOPSIS
        Returns a copy of $EditionConfig with every registryPaths.<target>
        rewritten for the given Scope. The original config object is left
        untouched so subsequent edition iterations see the same baseline.
    #>
    param(
        [Parameter(Mandatory)] $EditionConfig,
        [Parameter(Mandatory)] [ValidateSet('CurrentUser','AllUsers')] [string] $Scope
    )

    if ($Scope -eq 'AllUsers') { return $EditionConfig }

    # Build a shallow clone, then replace the registryPaths sub-object.
    $rewritten = [PSCustomObject]@{}
    foreach ($prop in $EditionConfig.PSObject.Properties) {
        $rewritten | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
    }

    $newPaths = [PSCustomObject]@{}
    foreach ($t in @('file','directory','background')) {
        $hasT = $EditionConfig.registryPaths.PSObject.Properties.Name -contains $t
        if (-not $hasT) { continue }
        $orig = $EditionConfig.registryPaths.$t
        if ([string]::IsNullOrWhiteSpace($orig)) { continue }
        $newPaths | Add-Member -NotePropertyName $t -NotePropertyValue (Convert-MenuPathForScope -PsPath $orig -Scope $Scope)
    }
    $rewritten.registryPaths = $newPaths
    return $rewritten
}

function Resolve-ConfirmShellExe {
    <#
    .SYNOPSIS
        Best-effort lookup of pwsh.exe (preferred) then powershell.exe.
        Mirrors script 53's resolver but kept self-contained so script 54
        does not depend on script 53's helpers.
    #>
    param(
        [string]$Preferred = "pwsh",
        [string]$LegacyPath = "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    )
    if ($Preferred -eq "pwsh") {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        foreach ($p in @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "$env:ProgramFiles\PowerShell\6\pwsh.exe",
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
        )) {
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    $legacy = [System.Environment]::ExpandEnvironmentVariables($LegacyPath)
    if (Test-Path -LiteralPath $legacy) { return $legacy }
    return $null
}

function Register-VsCodeMenuEntry {
    <#
    .SYNOPSIS
        Writes a single context menu entry: parent key with (Default)+Icon,
        and a \command subkey with the command line.

    .PARAMETER ConfirmCfg
        Optional config.confirmBeforeLaunch block. When .enabled is true the
        raw command line is wrapped in a pwsh call to Invoke-ConfirmedLaunch
        (the same helper used by script 53). When omitted or disabled, the
        direct command line from the template is written unchanged.
    #>
    param(
        [string]$TargetName,         # "file" | "directory" | "background"
        [string]$RegistryPath,       # full Registry:: path from config
        [string]$Label,              # menu label
        [string]$VsCodeExe,          # resolved exe path
        [string]$CommandTemplate,    # template with {exe}
        [string]$RepoRoot,           # repo root for confirm-launch wrapper
        $ConfirmCfg,                 # optional confirmBeforeLaunch block
        $LogMsgs,
        [string]$EditionName = ""    # for audit log scoping; optional
    )

    $rawCmd = $CommandTemplate -replace '\{exe\}', $VsCodeExe
    $cmdLine = $rawCmd

    $isConfirmEnabled = ($null -ne $ConfirmCfg) -and ($ConfirmCfg.PSObject.Properties.Name -contains 'enabled') -and $ConfirmCfg.enabled
    if ($isConfirmEnabled) {
        $shellExe = Resolve-ConfirmShellExe -Preferred $ConfirmCfg.shellPreferred -LegacyPath $ConfirmCfg.shellLegacyPath
        $isShellMissing = -not $shellExe
        if ($isShellMissing) {
            Write-Log ("confirmBeforeLaunch enabled but no PowerShell exe resolved -- falling back to direct launch for: " + $RegistryPath) -Level "warn"
        } else {
            $leafLabel = "$Label ($TargetName)"
            # Escape single quotes for safe embedding inside a PS single-quoted string literal
            $innerEscaped = $rawCmd.Replace("'", "''")
            $wrapped = $ConfirmCfg.wrapperTemplate
            $wrapped = $wrapped.Replace('{shellExe}',     $shellExe)
            $wrapped = $wrapped.Replace('{repoRoot}',     $RepoRoot)
            $wrapped = $wrapped.Replace('{leafLabel}',    $leafLabel)
            $wrapped = $wrapped.Replace('{countdown}',    [string]$ConfirmCfg.countdownSeconds)
            $wrapped = $wrapped.Replace('{innerCommand}', $innerEscaped)
            $cmdLine = $wrapped
        }
    }

    Write-Log (($LogMsgs.messages.writingTarget -replace '\{target\}', $TargetName) -replace '\{path\}', $RegistryPath) -Level "info"
    Write-Log ($LogMsgs.messages.writingCommand -replace '\{command\}', $cmdLine) -Level "info"

    try {
        $sub  = Get-HkcrSubkeyPath $RegistryPath
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

        $key = $hkcr.CreateSubKey($sub)
        $key.SetValue("",     $Label)
        $key.SetValue("Icon", "`"$VsCodeExe`"")
        $key.Close()

        $cmdKey = $hkcr.CreateSubKey("$sub\command")
        $cmdKey.SetValue("", $cmdLine)
        $cmdKey.Close()

        Write-Log ($LogMsgs.messages.writeOk -replace '\{path\}', $RegistryPath) -Level "success"

        # Audit: record the exact key + values that were just written.
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "add" `
                -Edition $EditionName -Target $TargetName -RegPath $RegistryPath `
                -Values @{ "(Default)" = $Label; "Icon" = "`"$VsCodeExe`""; "command" = $cmdLine }
        }

        return $true
    } catch {
        $msg = ($LogMsgs.messages.writeFailed -replace '\{path\}', $RegistryPath) -replace '\{error\}', $_
        Write-Log $msg -Level "error"
        if (Get-Command Write-RegistryAuditEvent -ErrorAction SilentlyContinue) {
            $null = Write-RegistryAuditEvent -Operation "fail" `
                -Edition $EditionName -Target $TargetName -RegPath $RegistryPath `
                -Reason ("write failed: " + $_.Exception.Message)
        }
        return $false
    }
}

function Test-VsCodeMenuEntry {
    param(
        [string]$TargetName,
        [string]$RegistryPath,
        $LogMsgs
    )

    $regPath = ConvertTo-RegExePath $RegistryPath
    $null = reg.exe query $regPath 2>&1
    $isPresent = ($LASTEXITCODE -eq 0)
    if ($isPresent) {
        Write-Log ((($LogMsgs.messages.verifyPass -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "success"
        return $true
    }
    Write-Log ((($LogMsgs.messages.verifyMiss -replace '\{target\}', $TargetName) -replace '\{path\}', $regPath)) -Level "error"
    return $false
}

function Resolve-VsCodeExecutable {
    <#
    .SYNOPSIS
        Resolves the VS Code exe for an edition.
        Override > config path expansion > auto-discovery on disk.

    .DESCRIPTION
        When the configured path no longer points at a real file (VS Code
        was uninstalled, moved, or upgraded into a different folder), this
        falls back to Find-VsCodeInstallation so the install/sync flow
        keeps working. The discovered path is logged with its source so
        the user can decide whether to update config.json::vsCodePath.
    #>
    param(
        [string]$EditionName,
        [string]$ConfigPath,
        [string]$Override,
        $LogMsgs
    )

    Write-Log ($LogMsgs.messages.resolvingExe -replace '\{name\}', $EditionName) -Level "info"

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        Write-Log ($LogMsgs.messages.exeOverride -replace '\{path\}', $Override) -Level "info"
        $isOverridePresent = Test-Path -LiteralPath $Override
        if ($isOverridePresent) {
            Write-Log ($LogMsgs.messages.exeOk -replace '\{path\}', $Override) -Level "success"
            return $Override
        }
        $msg = ($LogMsgs.messages.exeMissing -replace '\{path\}', $Override) -replace '\{name\}', $EditionName
        Write-Log $msg -Level "error"
        return $null
    }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($ConfigPath)
    Write-Log ($LogMsgs.messages.exeFromConfig -replace '\{path\}', $expanded) -Level "info"
    $isPresent = Test-Path -LiteralPath $expanded
    if ($isPresent) {
        Write-Log ($LogMsgs.messages.exeOk -replace '\{path\}', $expanded) -Level "success"
        return $expanded
    }

    # Configured path is gone -- attempt auto-discovery before giving up.
    Write-Log ("Configured VS Code path not on disk: " + $expanded + " (failure: file missing -- attempting auto-discovery for edition '" + $EditionName + "')") -Level "warn"
    $discovered = Find-VsCodeInstallation -EditionName $EditionName
    $hasDiscovered = $null -ne $discovered -and -not [string]::IsNullOrWhiteSpace($discovered.Path)
    if ($hasDiscovered) {
        Write-Log ("Auto-discovered VS Code at: " + $discovered.Path + " (source=" + $discovered.Source + ")") -Level "success"
        Write-Log ("Tip: update config.json::editions." + $EditionName + ".vsCodePath to this path so future runs skip discovery.") -Level "info"
        return $discovered.Path
    }

    $msg = ($LogMsgs.messages.exeMissing -replace '\{path\}', $expanded) -replace '\{name\}', $EditionName
    Write-Log $msg -Level "error"
    Write-Log ("Auto-discovery also failed: no '" + $EditionName + "' VS Code install found in well-known locations (failure path: see Find-VsCodeInstallation candidate list).") -Level "error"
    return $null
}

function Find-VsCodeInstallation {
    <#
    .SYNOPSIS
        Best-effort detection of the current VS Code exe on disk.

    .DESCRIPTION
        Probes, in order:
          1. Well-known per-user install     (%LOCALAPPDATA%\Programs\...)
          2. Well-known machine install      (%ProgramFiles%, %ProgramFiles(x86)%)
          3. PATH (Get-Command code / code-insiders -> .cmd shim -> .exe)
          4. Uninstall registry keys (HKLM + HKCU, 32 + 64-bit views)

        Returns a PSCustomObject with .Path and .Source on success, or
        $null when nothing matches. Pure read-only -- never writes anywhere.

        Source values:
          'per-user' | 'machine' | 'path-shim' | 'registry-uninstall'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('stable','insiders')]
        [string] $EditionName
    )

    $isInsiders = ($EditionName -eq 'insiders')
    $exeName    = if ($isInsiders) { 'Code - Insiders.exe' } else { 'Code.exe' }
    $shimName   = if ($isInsiders) { 'code-insiders'        } else { 'code'    }
    $folderTail = if ($isInsiders) { 'Microsoft VS Code Insiders' } else { 'Microsoft VS Code' }

    # 1) per-user install
    $perUser = Join-Path $env:LOCALAPPDATA ("Programs\" + $folderTail + "\" + $exeName)
    if (Test-Path -LiteralPath $perUser) {
        return [pscustomobject]@{ Path = $perUser; Source = 'per-user' }
    }

    # 2) machine install (both Program Files variants)
    $machineCandidates = @(
        (Join-Path $env:ProgramFiles            ($folderTail + "\" + $exeName))
    )
    if ($env:ProgramW6432) {
        $machineCandidates += (Join-Path $env:ProgramW6432 ($folderTail + "\" + $exeName))
    }
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not [string]::IsNullOrWhiteSpace($pf86)) {
        $machineCandidates += (Join-Path $pf86 ($folderTail + "\" + $exeName))
    }
    foreach ($c in $machineCandidates) {
        if (Test-Path -LiteralPath $c) {
            return [pscustomobject]@{ Path = $c; Source = 'machine' }
        }
    }

    # 3) PATH shim -- the 'code' / 'code-insiders' .cmd lives in <install>\bin
    try {
        $cmd = Get-Command $shimName -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            $shimDir   = Split-Path -Parent $cmd.Source              # ...\bin
            $installDir = Split-Path -Parent $shimDir                # install root
            $candidate = Join-Path $installDir $exeName
            if (Test-Path -LiteralPath $candidate) {
                return [pscustomobject]@{ Path = $candidate; Source = 'path-shim' }
            }
        }
    } catch {
        Write-Log ("PATH shim probe failed for '" + $shimName + "' (failure: " + $_.Exception.Message + ")") -Level "warn"
    }

    # 4) Uninstall registry keys (machine + user, both views)
    $uninstallRoots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $matchPattern = if ($isInsiders) { 'Visual Studio Code.*Insiders' } else { '^Microsoft Visual Studio Code( \(User\))?$' }
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            $entries = Get-ChildItem -LiteralPath $root -ErrorAction Stop
        } catch {
            Write-Log ("Failed to enumerate uninstall root: " + $root + " (failure: " + $_.Exception.Message + ")") -Level "warn"
            continue
        }
        foreach ($entry in $entries) {
            try {
                $props = Get-ItemProperty -LiteralPath $entry.PsPath -ErrorAction Stop
            } catch { continue }
            $hasName = $props.PSObject.Properties.Name -contains 'DisplayName'
            if (-not $hasName) { continue }
            $name = [string]$props.DisplayName
            if ($name -notmatch $matchPattern) { continue }
            # InstallLocation is the install root; exe sits at <root>\<exeName>.
            $hasLoc = $props.PSObject.Properties.Name -contains 'InstallLocation'
            if ($hasLoc) {
                $loc = [string]$props.InstallLocation
                if (-not [string]::IsNullOrWhiteSpace($loc)) {
                    $candidate = Join-Path $loc $exeName
                    if (Test-Path -LiteralPath $candidate) {
                        return [pscustomobject]@{ Path = $candidate; Source = 'registry-uninstall' }
                    }
                }
            }
            # Fallback: parse DisplayIcon (often points at the exe directly).
            $hasIcon = $props.PSObject.Properties.Name -contains 'DisplayIcon'
            if ($hasIcon) {
                $icon = [string]$props.DisplayIcon
                if ($icon -match '^"?(.+?\.exe)"?(?:,.*)?$') {
                    $candidate = $Matches[1]
                    if (Test-Path -LiteralPath $candidate) {
                        return [pscustomobject]@{ Path = $candidate; Source = 'registry-uninstall' }
                    }
                }
            }
        }
    }

    return $null
}

function Get-InstalledMenuExePath {
    <#
    .SYNOPSIS
        Reads the current \command (Default) value for one target key and
        extracts the exe path from the leading quoted token. Used by sync
        to compare what's REGISTERED against what's actually on disk.

    .OUTPUTS
        $null when key/command missing or unparseable; otherwise the exe
        path as a string (already passed through ExpandEnvironmentVariables).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RegistryPath)

    $cmdPath = $RegistryPath + '\command'
    if (-not (Test-Path -LiteralPath $cmdPath)) { return $null }
    try {
        $val = (Get-ItemProperty -LiteralPath $cmdPath -ErrorAction Stop).'(default)'
    } catch {
        Write-Log ("Failed to read installed command from: " + $cmdPath + " (failure: " + $_.Exception.Message + ")") -Level "warn"
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }

    # Extract first quoted token. When confirmBeforeLaunch is enabled the
    # outer quoted token is pwsh.exe -- we want the inner VS Code exe in
    # that case. Detect by scanning for "Code.exe" / "Code - Insiders.exe".
    $exeMatches = [regex]::Matches($val, '"([^"]+\.exe)"')
    if ($exeMatches.Count -eq 0) { return $null }
    foreach ($m in $exeMatches) {
        $candidate = $m.Groups[1].Value
        if ($candidate -match '(?i)\\Code( - Insiders)?\.exe$') {
            return [System.Environment]::ExpandEnvironmentVariables($candidate)
        }
    }
    # Fallback: the first .exe match.
    return [System.Environment]::ExpandEnvironmentVariables($exeMatches[0].Groups[1].Value)
}
