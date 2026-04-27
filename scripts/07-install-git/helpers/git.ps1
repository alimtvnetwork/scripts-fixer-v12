# --------------------------------------------------------------------------
#  Git, Git LFS, and GitHub CLI helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}
# git-config defaults are owned by the shared helper (single source of truth
# shared with the bash side). Configure-GitGlobal below delegates all
# scalar/url/safe-directory writes to Apply-DefaultGitConfig.
$_gitDefaultsPath = Join-Path $_sharedDir "git-config-defaults.ps1"
if ((Test-Path $_gitDefaultsPath) -and -not (Get-Command Apply-DefaultGitConfig -ErrorAction SilentlyContinue)) {
    . $_gitDefaultsPath
}


function Install-Git {
    param(
        $Config,
        $LogMessages
    )

    # Delegates the detect/upgrade/install/track flow to the shared
    # Ensure-Tool helper so the same logic runs whether the user invokes
    # script 07 directly or via the "advanced" profile in script 12.
    $packageName = $Config.chocoPackageName
    $alwaysUpgrade = [bool]$Config.alwaysUpgradeToLatest

    $ensureParams = @{
        Name         = "git"
        Command      = "git"
        ChocoPackage = $packageName
        FriendlyName = "Git"
    }
    if ($alwaysUpgrade) { $ensureParams.AlwaysUpgradeToLatest = $true }

    $result = Ensure-Tool @ensureParams

    # Map Ensure-Tool outcome back onto the per-script log message catalog so
    # the on-screen output stays consistent with what users saw before.
    $version = if ($result.Version) { $result.Version } else { "unknown" }
    switch ($result.Action) {
        "skipped"   { Write-Log ($LogMessages.messages.gitAlreadyInstalled -replace '\{version\}', $version) -Level "info" }
        "installed" { Write-Log ($LogMessages.messages.gitInstallSuccess  -replace '\{version\}', $version) -Level "success" }
        "upgraded"  { Write-Log ($LogMessages.messages.gitUpgradeSuccess  -replace '\{version\}', $version) -Level "success" }
        "failed"    { Write-Log "Git install/upgrade failed: $($result.Error)" -Level "error" }
    }
}

function Install-GitLfs {
    param(
        $Config,
        $LogMessages
    )

    $lfsConfig = $Config.gitLfs
    $isLfsDisabled = -not $lfsConfig.enabled
    if ($isLfsDisabled) { return }

    $packageName = $lfsConfig.chocoPackageName

    $existing = Get-Command git-lfs -ErrorAction SilentlyContinue
    if ($existing) {
        $currentVersion = try { & git lfs version 2>$null } catch { $null }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($currentVersion)

        # Check .installed/ tracking
        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name "git-lfs" -CurrentVersion $currentVersion
            if ($isAlreadyTracked) {
                Write-Log ($LogMessages.messages.lfsAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"
                return
            }
        }

        Write-Log ($LogMessages.messages.lfsAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"

        if ($lfsConfig.alwaysUpgradeToLatest) {
            try {
                Upgrade-ChocoPackage -PackageName $packageName
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                $newVersion = try { & git lfs version 2>$null } catch { $null }
                $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
                if ($isVersionEmpty) { $newVersion = "(version pending)" }
                Write-Log ($LogMessages.messages.lfsUpgradeSuccess -replace '\{version\}', $newVersion) -Level "success"
                Save-InstalledRecord -Name "git-lfs" -Version "$newVersion".Trim()
            } catch {
                Write-Log "Git LFS upgrade failed: $_" -Level "error"
                Save-InstalledError -Name "git-lfs" -ErrorMessage "$_"
            }
        }
    }
    else {
        Write-Log $LogMessages.messages.lfsNotFound -Level "info"
        try {
            Install-ChocoPackage -PackageName $packageName

            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            $installedVersion = & git lfs version 2>$null
            Write-Log ($LogMessages.messages.lfsInstallSuccess -replace '\{version\}', $installedVersion) -Level "success"
            Save-InstalledRecord -Name "git-lfs" -Version $installedVersion
        } catch {
            Write-Log "Git LFS install failed: $_" -Level "error"
            Save-InstalledError -Name "git-lfs" -ErrorMessage "$_"
        }
    }

    # Initialize LFS in the global git config
    & git lfs install 2>$null
    Write-Log $LogMessages.messages.lfsInitSuccess -Level "success"
}

function Install-GitHubCli {
    param(
        $Config,
        $LogMessages
    )

    $ghConfig = $Config.githubCli
    $isGhDisabled = -not $ghConfig.enabled
    if ($isGhDisabled) { return }

    $packageName = $ghConfig.chocoPackageName

    $existing = Get-Command gh -ErrorAction SilentlyContinue
    if ($existing) {
        $currentVersion = try { & gh --version 2>$null | Select-Object -First 1 } catch { $null }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($currentVersion)

        # Check .installed/ tracking
        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name "github-cli" -CurrentVersion $currentVersion
            if ($isAlreadyTracked) {
                Write-Log ($LogMessages.messages.ghAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"
                return
            }
        }

        Write-Log ($LogMessages.messages.ghAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"

        if ($ghConfig.alwaysUpgradeToLatest) {
            try {
                Write-Log $LogMessages.messages.ghUpgrading -Level "info"
                Upgrade-ChocoPackage -PackageName $packageName
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                $newVersion = try { & gh --version 2>$null | Select-Object -First 1 } catch { $null }
                $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
                if ($isVersionEmpty) { $newVersion = "(version pending)" }
                Write-Log ($LogMessages.messages.ghUpgradeSuccess -replace '\{version\}', $newVersion) -Level "success"
                Save-InstalledRecord -Name "github-cli" -Version "$newVersion".Trim()
            } catch {
                Write-Log "GitHub CLI upgrade failed: $_" -Level "error"
                Save-InstalledError -Name "github-cli" -ErrorMessage "$_"
            }
        }
    }
    else {
        Write-Log $LogMessages.messages.ghNotFound -Level "info"
        try {
            Install-ChocoPackage -PackageName $packageName

            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            $installedVersion = & gh --version 2>$null | Select-Object -First 1
            Write-Log ($LogMessages.messages.ghInstallSuccess -replace '\{version\}', $installedVersion) -Level "success"
            Save-InstalledRecord -Name "github-cli" -Version $installedVersion
        } catch {
            Write-Log "GitHub CLI install failed: $_" -Level "error"
            Save-InstalledError -Name "github-cli" -ErrorMessage "$_"
        }
    }

    # Prompt for login if configured
    if ($ghConfig.promptLogin) {
        $authStatus = & gh auth status 2>&1
        $isAuthenticated = $LASTEXITCODE -eq 0
        if ($isAuthenticated) {
            $ghUser = & gh api user --jq '.login' 2>$null
            Write-Log ($LogMessages.messages.ghAlreadyAuthenticated -replace '\{user\}', $ghUser) -Level "info"
        }
        else {
            Write-Log $LogMessages.messages.ghLoginStart -Level "info"
            & gh auth login
        }
    }
}

function Configure-GitGlobal {
    param(
        $Config,
        $LogMessages
    )

    $gc = $Config.gitConfig
    Write-Log $LogMessages.messages.configuringGit -Level "info"

    # -- user.name ---------------------------------------------------------------
    $nameConfig = $gc.userName
    $currentName = & git config --global user.name 2>$null

    if ($currentName) {
        Write-Log ($LogMessages.messages.userNameAlreadySet -replace '\{value\}', $currentName) -Level "info"
    }
    else {
        $name = $nameConfig.value
        $hasNoName = -not $name
        $hasGitNameEnv = -not [string]::IsNullOrWhiteSpace($env:GIT_USER_NAME)
        if ($hasNoName -and $hasGitNameEnv) {
            $name = $env:GIT_USER_NAME
        }
        $hasOrchestratorEnv = -not [string]::IsNullOrWhiteSpace($env:SCRIPTS_ROOT_RUN)
        if ($hasNoName -and -not $hasGitNameEnv -and $nameConfig.promptOnFirstRun -and -not $hasOrchestratorEnv) {
            $name = Read-Host $LogMessages.messages.promptUserName
        }
        if ($name) {
            & git config --global user.name $name
            Write-Log ($LogMessages.messages.settingUserName -replace '\{value\}', $name) -Level "success"
        }
    }

    # -- user.email --------------------------------------------------------------
    $emailConfig = $gc.userEmail
    $currentEmail = & git config --global user.email 2>$null

    if ($currentEmail) {
        Write-Log ($LogMessages.messages.userEmailAlreadySet -replace '\{value\}', $currentEmail) -Level "info"
    }
    else {
        $email = $emailConfig.value
        $hasNoEmail = -not $email
        $hasGitEmailEnv = -not [string]::IsNullOrWhiteSpace($env:GIT_USER_EMAIL)
        if ($hasNoEmail -and $hasGitEmailEnv) {
            $email = $env:GIT_USER_EMAIL
        }
        $hasOrchestratorEnv = -not [string]::IsNullOrWhiteSpace($env:SCRIPTS_ROOT_RUN)
        if ($hasNoEmail -and -not $hasGitEmailEnv -and $emailConfig.promptOnFirstRun -and -not $hasOrchestratorEnv) {
            $email = Read-Host $LogMessages.messages.promptUserEmail
        }
        if ($email) {
            & git config --global user.email $email
            Write-Log ($LogMessages.messages.settingUserEmail -replace '\{value\}', $email) -Level "success"
        }
    }

    # -- All other scalar defaults (init.defaultBranch, core.autocrlf,
    #    core.editor, credential.helper, push.autoSetupRemote, pull.rebase,
    #    fetch.prune, safe.directory, url.* rewrites) are owned by the
    #    shared helper, which is the single source of truth used by both
    #    Windows install.ps1 and Linux install.sh.
    #
    #    Per-key overrides from this script's config.json (when set) are
    #    forwarded so users keep deployment-specific control.
    $overrides = @{}
    if ($gc.PSObject.Properties.Name -contains "defaultBranch"       -and $gc.defaultBranch.enabled       -and $gc.defaultBranch.value)       { $overrides["init.defaultBranch"]   = $gc.defaultBranch.value }
    if ($gc.PSObject.Properties.Name -contains "credentialManager"   -and $gc.credentialManager.enabled   -and $gc.credentialManager.helper)  { $overrides["credential.helper"]    = $gc.credentialManager.helper }
    if ($gc.PSObject.Properties.Name -contains "lineEndings"         -and $gc.lineEndings.enabled         -and $gc.lineEndings.autocrlf)      { $overrides["core.autocrlf"]        = $gc.lineEndings.autocrlf }
    if ($gc.PSObject.Properties.Name -contains "editor"              -and $gc.editor.enabled              -and $gc.editor.value)              { $overrides["core.editor"]          = $gc.editor.value }
    if ($gc.PSObject.Properties.Name -contains "pushAutoSetupRemote" -and $gc.pushAutoSetupRemote.enabled)                                     { $overrides["push.autoSetupRemote"] = "true" }

    Apply-DefaultGitConfig -Overrides $overrides | Out-Null
}

function Update-GitPath {
    param(
        $Config,
        $LogMessages
    )

    $isPathUpdateDisabled = -not $Config.path.updateUserPath
    if ($isPathUpdateDisabled) { return }

    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    $isGitMissing = -not $gitExe
    if ($isGitMissing) { return }

    $gitDir = Split-Path -Parent $gitExe.Source

    $isAlreadyInPath = Test-InPath -Directory $gitDir
    if ($isAlreadyInPath) {
        Write-Log ($LogMessages.messages.pathAlreadyContains -replace '\{path\}', $gitDir) -Level "info"
    }
    else {
        Write-Log ($LogMessages.messages.addingToPath -replace '\{path\}', $gitDir) -Level "info"
        Add-ToUserPath -Directory $gitDir
    }
}

function Uninstall-Git {
    <#
    .SYNOPSIS
        Full Git uninstall: choco uninstall git, git-lfs, gh, purge tracking.
    #>
    param(
        $Config,
        $LogMessages
    )

    # 1. Uninstall Git
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Git") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $Config.chocoPackageName
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "Git") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "Git") -Level "error"
    }

    # 2. Uninstall Git LFS
    $hasLfs = $Config.gitLfs.enabled
    if ($hasLfs) {
        Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Git LFS") -Level "info"
        Uninstall-ChocoPackage -PackageName $Config.gitLfs.chocoPackageName
    }

    # 3. Uninstall GitHub CLI
    $hasGhCli = $Config.githubCli.enabled
    if ($hasGhCli) {
        Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "GitHub CLI") -Level "info"
        Uninstall-ChocoPackage -PackageName $Config.githubCli.chocoPackageName
    }

    # 4. Remove tracking records
    Remove-InstalledRecord -Name "git"
    Remove-InstalledRecord -Name "git-lfs"
    Remove-InstalledRecord -Name "gh"
    Remove-ResolvedData -ScriptFolder "07-install-git"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
