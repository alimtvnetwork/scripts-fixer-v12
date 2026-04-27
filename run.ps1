<#
.SYNOPSIS
    Root-level script dispatcher. Runs a numbered script after pulling latest changes.

.DESCRIPTION
    Performs a git pull via the shared helper, sets $env:SCRIPTS_ROOT_RUN = "1"
    so child scripts skip their own git pull, then delegates to
    scripts/<NN>-*/run.ps1 based on the -I parameter.

    When run with no parameters, performs a git pull and shows help.
    Use -Install to run scripts by keyword (e.g. -Install vscode,python,go).
    Use -Clean to wipe all .resolved/ data before running, forcing fresh detection.
    Use -CleanOnly to wipe .resolved/ without running any script.
    Use -Help to see all available scripts and usage information.
    Use 'update' command to upgrade all Chocolatey packages.

.PARAMETER I
    The script number to run (e.g. 1, 2, 3). Maps to folders like 01-*, 02-*, etc.

.PARAMETER Install
    Comma-separated keywords to install (e.g. vscode, nodejs, python, go, git).
    See install-keywords.json for the full mapping.

.PARAMETER Clean
    Wipe all .resolved/ data before running the script.

.PARAMETER CleanOnly
    Wipe all .resolved/ data and exit without running any script.

.PARAMETER Help
    Show usage information and list all available scripts.

.EXAMPLE
    .\run.ps1                        # git pull, show help
    .\run.ps1 -Install vscode        # install VS Code
    .\run.ps1 -Install nodejs,pnpm   # install Node.js + pnpm
    .\run.ps1 -Install python        # install Python + pip
    .\run.ps1 -Install go,git,cpp    # install Go, Git, and C++
    .\run.ps1 -Install all-dev       # interactive dev tools menu
    .\run.ps1 update                 # show outdated, confirm, upgrade all
    .\run.ps1 update nodejs,git        # upgrade specific packages only
    .\run.ps1 update --check           # list outdated packages (no upgrade)
    .\run.ps1 update -y                # upgrade all, skip confirmation
    .\run.ps1 update --exclude=choco   # upgrade all except listed
    .\run.ps1 path D:\devtools       # set default dev directory
    .\run.ps1 path                   # show current dev directory
    .\run.ps1 path --reset           # clear saved path, use smart detection
    .\run.ps1 -d                     # shortcut for -I 12 (interactive menu)
    .\run.ps1 -I 1                   # run scripts/01-*/run.ps1
    .\run.ps1 -I 1 -Clean           # wipe .resolved/, then run script 01
    .\run.ps1 -CleanOnly             # wipe .resolved/ and exit
    .\run.ps1 -Help                  # show all available scripts

.NOTES
    Author : Lovable AI
    Version: 7.3.0
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Install,

    [int]$I,

    [switch]$d,

    [switch]$a,

    [switch]$h,

    [switch]$v,

    [switch]$w,

    [switch]$t,

    [switch]$M,

    [switch]$Defaults,

    [switch]$Y,

    [switch]$Merge,

    [switch]$Clean,

    [switch]$CleanOnly,

    [switch]$List,

    [switch]$Help
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Read project version ─────────────────────────────────────────────
function Get-ScriptVersion {
    $vf = Join-Path (Join-Path $RootDir "scripts") "version.json"
    $isPresent = Test-Path $vf
    if ($isPresent) {
        $data = Get-Content $vf -Raw | ConvertFrom-Json
        return $data.version
    }
    return $null
}

function Show-VersionHeader {
    $ver = Get-ScriptVersion
    $hasVersion = -not [string]::IsNullOrWhiteSpace($ver)
    if ($hasVersion) {
        Write-Host ""
        Write-Host "  Scripts Fixer v$ver" -ForegroundColor Magenta
    }
}

# ── Detect installed tool version (quick, no install) ────────────────
function Get-InstalledTag {
    param([string]$ToolCmd, [string]$Flag = "--version", [scriptblock]$Parse)
    $cmd = Get-Command $ToolCmd -ErrorAction SilentlyContinue
    $isMissing = -not $cmd
    if ($isMissing) { return $null }
    try {
        $raw = & $ToolCmd $Flag 2>$null
        $ver = if ($Parse) { & $Parse "$raw" } else { "$raw".Trim() }
        $hasVer = -not [string]::IsNullOrWhiteSpace($ver)
        if ($hasVer) { return $ver }
    } catch {}
    return $null
}

function Get-VersionMap {
    $map = @{}
    $tools = @(
        @{ Id = "01"; Cmd = "code";      Parse = { param($r) ($r -split '\s+')[1] } },
        @{ Id = "02"; Cmd = "choco";     Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "03"; Cmd = "node";      Parse = { param($r) $r -replace 'v','' } },
        @{ Id = "04"; Cmd = "pnpm";      Parse = { param($r) $r.Trim() } },
        @{ Id = "05"; Cmd = "python";    Parse = { param($r) ($r -replace 'Python\s*','').Trim() } },
        @{ Id = "06"; Cmd = "go";        Flag = "version"; Parse = { param($r) if ($r -match 'go(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "07"; Cmd = "git";       Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "08"; Cmd = "github";    Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "09"; Cmd = "g++";       Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "16"; Cmd = "php";       Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "17"; Cmd = "pwsh";      Parse = { param($r) ($r -replace 'PowerShell\s*','').Trim() } },
        @{ Id = "38"; Cmd = "flutter";   Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } },
        @{ Id = "39"; Cmd = "dotnet";    Parse = { param($r) $r.Trim() } },
        @{ Id = "40"; Cmd = "java";      Flag = "-version"; Parse = { param($r) if ($r -match '(\d[\d._]+)') { $Matches[1] } else { $r } } },
        @{ Id = "42"; Cmd = "ollama";    Parse = { param($r) if ($r -match '(\d[\d.]+)') { $Matches[1] } else { $r } } }
    )
    foreach ($t in $tools) {
        $flag = if ($t.Flag) { $t.Flag } else { "--version" }
        $ver = Get-InstalledTag -ToolCmd $t.Cmd -Flag $flag -Parse $t.Parse
        $hasVer = -not [string]::IsNullOrWhiteSpace($ver)
        if ($hasVer) { $map[$t.Id] = $ver }
    }

    # Registry/file-based detection for GUI apps without CLI --version
    $regApps = @(
        @{ Id = "08"; Name = "GitHub Desktop";   Paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GitHubDesktop",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GitHubDesktop",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\GitHubDesktop"
        )},
        @{ Id = "32"; Name = "DBeaver";          Paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DBeaver*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DBeaver*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\DBeaver*"
        )},
        @{ Id = "33"; Name = "Notepad++";        Paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++"
        )},
        @{ Id = "34"; Name = "Simple Sticky Notes"; Paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Simple Sticky Notes*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Simple Sticky Notes*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Simple Sticky Notes*"
        )},
        @{ Id = "36"; Name = "OBS Studio";       Paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio"
        )},
        @{ Id = "37"; Name = "Windows Terminal";  Paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*WindowsTerminal*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*WindowsTerminal*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*WindowsTerminal*",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*Windows Terminal*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*Windows Terminal*"
        )}
    )

    foreach ($app in $regApps) {
        $isAlreadyDetected = $map.ContainsKey($app.Id)
        if ($isAlreadyDetected) { continue }

        foreach ($regPath in $app.Paths) {
            $keys = Get-Item $regPath -ErrorAction SilentlyContinue
            $hasKeys = $null -ne $keys
            if (-not $hasKeys) { continue }

            foreach ($key in $keys) {
                $displayVersion = $key.GetValue("DisplayVersion")
                $hasDisplayVersion = -not [string]::IsNullOrWhiteSpace($displayVersion)
                if ($hasDisplayVersion) {
                    $map[$app.Id] = "$displayVersion".Trim()
                    break
                }
            }

            $isNowDetected = $map.ContainsKey($app.Id)
            if ($isNowDetected) { break }
        }
    }

    # Winget detection
    $isWingetMissing = -not $map.ContainsKey("14")
    if ($isWingetMissing) {
        $wingetCmd = Get-Command "winget" -ErrorAction SilentlyContinue
        $hasWinget = $null -ne $wingetCmd
        if ($hasWinget) {
            try {
                $wingetRaw = & winget --version 2>$null
                $wingetVer = "$wingetRaw".Trim() -replace '^v',''
                $hasWingetVer = -not [string]::IsNullOrWhiteSpace($wingetVer)
                if ($hasWingetVer) { $map["14"] = $wingetVer }
            } catch {}
        }
    }

    return $map
}

# ── Help function ────────────────────────────────────────────────────
function Show-RootHelp {
    Show-VersionHeader
    Write-Host ""
    Write-Host "  Dev Tools Setup Scripts" -ForegroundColor Cyan
    Write-Host "  =======================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor Yellow
    Write-Host ""
    $col = 44
    Write-Host "    $(".\run.ps1 install <keywords>".PadRight($col))" -NoNewline; Write-Host "Install by keyword (bare command)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -Install <keywords>".PadRight($col))" -NoNewline; Write-Host "Install by keyword (named parameter)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 update".PadRight($col))" -NoNewline; Write-Host "Show outdated, confirm, upgrade all" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 update nodejs,git".PadRight($col))" -NoNewline; Write-Host "Upgrade specific packages only" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 update --check".PadRight($col))" -NoNewline; Write-Host "List outdated packages (no upgrade)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 update -y".PadRight($col))" -NoNewline; Write-Host "Upgrade all, skip confirmation" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 update --exclude=pkg1,pkg2".PadRight($col))" -NoNewline; Write-Host "Upgrade all except listed" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 export".PadRight($col))" -NoNewline; Write-Host "Export all app settings to repo" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 export npp,obs".PadRight($col))" -NoNewline; Write-Host "Export specific app settings" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 status".PadRight($col))" -NoNewline; Write-Host "Show dashboard of all installed tools" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 status --no-choco".PadRight($col))" -NoNewline; Write-Host "Status without outdated package check" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 doctor".PadRight($col))" -NoNewline; Write-Host "Quick health check of project setup" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 doctor --self-check".PadRight($col))" -NoNewline; Write-Host "Deep audit: changelog files, version, clean catalog, keyword resolution, SHA256 pins" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 doctor --self-check --skip-network".PadRight($col))" -NoNewline; Write-Host "Same as above but skips sections (d) + (e) for offline use" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 models".PadRight($col))" -NoNewline; Write-Host "Pick AI model backend (llama.cpp / Ollama), browse + install" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 models <ids>".PadRight($col))" -NoNewline; Write-Host "Direct install: CSV of model ids (auto-routes per backend)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 models list".PadRight($col))" -NoNewline; Write-Host "List all models from both catalogs" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -M".PadRight($col))" -NoNewline; Write-Host "Shortcut for 'models'" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 os <action>".PadRight($col))" -NoNewline; Write-Host "OS housekeeping: clean, temp-clean, hib-off, flp, add-user ('os help')" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 vscode-folder <action>".PadRight($col))" -NoNewline; Write-Host "VS Code folder-only context-menu repair ('vscode-folder help')" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 profile <name>".PadRight($col))" -NoNewline; Write-Host "Run a profile recipe (minimal, base, advance, small-dev, ...)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 gsa".PadRight($col))" -NoNewline; Write-Host "git safe.directory='*' (wildcard, idempotent)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 gsa --scan <path>".PadRight($col))" -NoNewline; Write-Host "Add each .git repo under <path> individually" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 git-tools <action>".PadRight($col))" -NoNewline; Write-Host "Git config helpers ('git-tools help' for actions)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 path <dir>".PadRight($col))" -NoNewline; Write-Host "Set default dev directory" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 path".PadRight($col))" -NoNewline; Write-Host "Show current dev directory" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 path --reset".PadRight($col))" -NoNewline; Write-Host "Clear saved path, use smart detection" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I <number>".PadRight($col))" -NoNewline; Write-Host "Run a specific script by ID" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -d".PadRight($col))" -NoNewline; Write-Host "Shortcut for -I 12 (interactive menu)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -a".PadRight($col))" -NoNewline; Write-Host "Shortcut for -I 13 (audit mode)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -h".PadRight($col))" -NoNewline; Write-Host "Shortcut for -I 13 -Report (health check)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -v".PadRight($col))" -NoNewline; Write-Host "Shortcut for -I 1  (install VS Code)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -w".PadRight($col))" -NoNewline; Write-Host "Shortcut for -I 14 (install Winget)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -t".PadRight($col))" -NoNewline; Write-Host "Shortcut for -I 15 (Windows tweaks)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -Defaults".PadRight($col))" -NoNewline; Write-Host "Use all defaults, prompt to confirm" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -Defaults -Y".PadRight($col))" -NoNewline; Write-Host "Use all defaults, skip confirmation" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I <number> -Merge".PadRight($col))" -NoNewline; Write-Host "Run with merge flag (script 02)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I <number> -Clean".PadRight($col))" -NoNewline; Write-Host "Wipe cache, then run" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -CleanOnly".PadRight($col))" -NoNewline; Write-Host "Wipe all cached data" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -Help".PadRight($col))" -NoNewline; Write-Host "Show this help" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -List".PadRight($col))" -NoNewline; Write-Host "Show keyword table only" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "  Install by Keyword:" -ForegroundColor Yellow
    Write-Host ""
    $kc = 44
    Write-Host "    $("install vscode".PadRight($kc))" -NoNewline; Write-Host "Install Visual Studio Code" -ForegroundColor DarkGray
    Write-Host "    $("install nodejs".PadRight($kc))" -NoNewline; Write-Host "Install Node.js + Yarn + Bun" -ForegroundColor DarkGray
    Write-Host "    $("install pnpm".PadRight($kc))" -NoNewline; Write-Host "Install Node.js + pnpm (auto-chains)" -ForegroundColor DarkGray
    Write-Host "    $("install python".PadRight($kc))" -NoNewline; Write-Host "Install Python + pip" -ForegroundColor DarkGray
    Write-Host "    $("install pylibs".PadRight($kc))" -NoNewline; Write-Host "Install Python + pip + all libraries (numpy, pandas, jupyter...)" -ForegroundColor DarkGray
    Write-Host "    $("install go".PadRight($kc))" -NoNewline; Write-Host "Install Go + configure GOPATH" -ForegroundColor DarkGray
    Write-Host "    $("install git".PadRight($kc))" -NoNewline; Write-Host "Install Git + LFS + GitHub CLI" -ForegroundColor DarkGray
    Write-Host "    $("install cpp".PadRight($kc))" -NoNewline; Write-Host "Install C++ MinGW-w64 compiler" -ForegroundColor DarkGray
    Write-Host "    $("install php".PadRight($kc))" -NoNewline; Write-Host "Install PHP via Chocolatey" -ForegroundColor DarkGray
    Write-Host "    $("install powershell".PadRight($kc))" -NoNewline; Write-Host "Install latest PowerShell" -ForegroundColor DarkGray
    Write-Host "    $("install winget".PadRight($kc))" -NoNewline; Write-Host "Install Winget package manager" -ForegroundColor DarkGray
    Write-Host "    $("install flutter".PadRight($kc))" -NoNewline; Write-Host "Install Flutter SDK + Dart" -ForegroundColor DarkGray
    Write-Host "    $("install dotnet".PadRight($kc))" -NoNewline; Write-Host "Install .NET SDK (latest)" -ForegroundColor DarkGray
    Write-Host "    $("install java".PadRight($kc))" -NoNewline; Write-Host "Install OpenJDK (latest LTS)" -ForegroundColor DarkGray
    Write-Host "    $("install settingssync".PadRight($kc))" -NoNewline; Write-Host "Sync VSCode settings + extensions" -ForegroundColor DarkGray
    Write-Host "    $("install contextmenu".PadRight($kc))" -NoNewline; Write-Host "Fix VSCode right-click context menu" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "    Python & pip libraries:" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "      Quick install:" -ForegroundColor DarkYellow
    Write-Host "    $("install pylibs".PadRight($kc))" -NoNewline; Write-Host "Install Python + all libraries in one go" -ForegroundColor DarkGray
    Write-Host "    $("install python-libs".PadRight($kc))" -NoNewline; Write-Host "Install all pip libraries only (numpy, pandas, etc.)" -ForegroundColor DarkGray
    Write-Host "    $("install python+libs".PadRight($kc))" -NoNewline; Write-Host "Install Python + all libraries in one go" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      By purpose:" -ForegroundColor DarkYellow
    Write-Host "    $("install data-science".PadRight($kc))" -NoNewline; Write-Host "Python + data/viz libs (pandas, matplotlib, plotly)" -ForegroundColor DarkGray
    Write-Host "    $("install ai-dev".PadRight($kc))" -NoNewline; Write-Host "Python + ML libs (numpy, scipy, scikit-learn, torch)" -ForegroundColor DarkGray
    Write-Host "    $("install deep-learning".PadRight($kc))" -NoNewline; Write-Host "Python + ML libs (same as ai-dev)" -ForegroundColor DarkGray
    Write-Host "    $("install jupyter+libs".PadRight($kc))" -NoNewline; Write-Host "Jupyter only (jupyterlab, notebook, ipykernel)" -ForegroundColor DarkGray
    Write-Host "    $("install viz-libs".PadRight($kc))" -NoNewline; Write-Host "Visualization (matplotlib, seaborn, plotly)" -ForegroundColor DarkGray
    Write-Host "    $("install web-libs".PadRight($kc))" -NoNewline; Write-Host "Web frameworks (django, flask, fastapi, uvicorn)" -ForegroundColor DarkGray
    Write-Host "    $("install scraping-libs".PadRight($kc))" -NoNewline; Write-Host "Scraping (requests, beautifulsoup4)" -ForegroundColor DarkGray
    Write-Host "    $("install db-libs".PadRight($kc))" -NoNewline; Write-Host "Database (sqlalchemy)" -ForegroundColor DarkGray
    Write-Host "    $("install cv-libs".PadRight($kc))" -NoNewline; Write-Host "Computer Vision (opencv-python)" -ForegroundColor DarkGray
    Write-Host "    $("install data-libs".PadRight($kc))" -NoNewline; Write-Host "Data tools (pandas, polars)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      With Python (auto-installs Python first):" -ForegroundColor DarkYellow
    Write-Host "    $("install python+viz".PadRight($kc))" -NoNewline; Write-Host "Python + visualization group" -ForegroundColor DarkGray
    Write-Host "    $("install python+web".PadRight($kc))" -NoNewline; Write-Host "Python + web frameworks group" -ForegroundColor DarkGray
    Write-Host "    $("install python+scraping".PadRight($kc))" -NoNewline; Write-Host "Python + scraping group" -ForegroundColor DarkGray
    Write-Host "    $("install python+db".PadRight($kc))" -NoNewline; Write-Host "Python + database group" -ForegroundColor DarkGray
    Write-Host "    $("install python+cv".PadRight($kc))" -NoNewline; Write-Host "Python + computer vision group" -ForegroundColor DarkGray
    Write-Host "    $("install python+data".PadRight($kc))" -NoNewline; Write-Host "Python + data tools group" -ForegroundColor DarkGray
    Write-Host "    $("install python+ml".PadRight($kc))" -NoNewline; Write-Host "Python + ML group" -ForegroundColor DarkGray
    Write-Host "    $("install python+jupyter".PadRight($kc))" -NoNewline; Write-Host "Python + all libraries (includes Jupyter)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      By group (.\run.ps1 -I 41 --):" -ForegroundColor DarkYellow
    Write-Host "    $(".\run.ps1 -I 41 -- group ml".PadRight($kc))" -NoNewline; Write-Host "ML group (numpy, scipy, scikit-learn, torch...)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group jupyter".PadRight($kc))" -NoNewline; Write-Host "Jupyter (jupyterlab, notebook, ipykernel, ipywidgets)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group viz".PadRight($kc))" -NoNewline; Write-Host "Visualization (matplotlib, seaborn, plotly)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group data".PadRight($kc))" -NoNewline; Write-Host "Data tools (pandas, polars)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group web".PadRight($kc))" -NoNewline; Write-Host "Web frameworks (django, flask, fastapi, uvicorn)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group scraping".PadRight($kc))" -NoNewline; Write-Host "Scraping (requests, beautifulsoup4)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group cv".PadRight($kc))" -NoNewline; Write-Host "Computer Vision (opencv-python)" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- group db".PadRight($kc))" -NoNewline; Write-Host "Database (sqlalchemy)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      Utilities:" -ForegroundColor DarkYellow
    Write-Host "    $(".\run.ps1 -I 41 -- add <pkg1> <pkg2>".PadRight($kc))" -NoNewline; Write-Host "Install specific packages by name" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- list".PadRight($kc))" -NoNewline; Write-Host "Show all available library groups" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- installed".PadRight($kc))" -NoNewline; Write-Host "Show currently installed pip packages" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- uninstall".PadRight($kc))" -NoNewline; Write-Host "Uninstall all tracked libraries" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 41 -- uninstall <pkg>".PadRight($kc))" -NoNewline; Write-Host "Uninstall specific packages" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "    Database installs:" -ForegroundColor Magenta
    Write-Host "    $("install databases".PadRight($kc))" -NoNewline; Write-Host "Open the interactive database installer menu" -ForegroundColor DarkGray
    Write-Host "    $("install mysql".PadRight($kc))" -NoNewline; Write-Host "Install MySQL database" -ForegroundColor DarkGray
    Write-Host "    $("install postgresql".PadRight($kc))" -NoNewline; Write-Host "Install PostgreSQL database" -ForegroundColor DarkGray
    Write-Host "    $("install sqlite".PadRight($kc))" -NoNewline; Write-Host "Install SQLite + DB Browser for SQLite" -ForegroundColor DarkGray
    Write-Host "    $("install mongodb,redis".PadRight($kc))" -NoNewline; Write-Host "Install MongoDB + Redis" -ForegroundColor DarkGray
    Write-Host "    $("install alldev".PadRight($kc))" -NoNewline; Write-Host "Interactive dev tools menu (pick what to install)" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "    Combine keywords:" -ForegroundColor Magenta
    Write-Host "    $("install nodejs,pnpm".PadRight($kc))" -NoNewline; Write-Host "Install Node.js + pnpm" -ForegroundColor DarkGray
    Write-Host "    $("install go,git,cpp".PadRight($kc))" -NoNewline; Write-Host "Install Go, Git, and C++" -ForegroundColor DarkGray
    Write-Host "    $("install python,php".PadRight($kc))" -NoNewline; Write-Host "Install Python + PHP" -ForegroundColor DarkGray
    Write-Host "    $("install vscode,nodejs,git".PadRight($kc))" -NoNewline; Write-Host "Install VS Code, Node.js, and Git" -ForegroundColor DarkGray
    Write-Host "    $("install alldev,mysql".PadRight($kc))" -NoNewline; Write-Host "Run the alldev menu, then install MySQL" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "    Remote installers (irm <url> | iex):" -ForegroundColor Magenta
    Write-Host "      All aliases on each row are EQUIVALENT -- pick whichever you remember." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    $("install clean-code".PadRight($kc))" -NoNewline; Write-Host "Coding Guidelines v15 -- alimtvnetwork/coding-guidelines-v15" -ForegroundColor DarkGray
    Write-Host "    $("install code-guide  (= cg, cc)".PadRight($kc))" -NoNewline; Write-Host "Same as 'install clean-code' (4 aliases total)" -ForegroundColor DarkGray
    Write-Host "    $("install coding-guidelines".PadRight($kc))" -NoNewline; Write-Host "Same as 'install clean-code' (long alias)" -ForegroundColor DarkGray
    Write-Host "    $("install starship    (= ss)".PadRight($kc))" -NoNewline; Write-Host "Starship cross-shell prompt -- local wrapper (winget/scoop/cargo)" -ForegroundColor DarkGray
    Write-Host "    $("install oh-my-posh  (= omp, posh)".PadRight($kc))" -NoNewline; Write-Host "Oh My Posh prompt -- ohmyposh.dev/install.ps1" -ForegroundColor DarkGray
    Write-Host "    $("install scoop       (= sc)".PadRight($kc))" -NoNewline; Write-Host "Scoop CLI installer -- get.scoop.sh" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Combine remote + local: install vscode,cg  (VS Code first, then clean-code)" -ForegroundColor DarkGray
    Write-Host ""

    Show-KeywordTable -Inline
    Write-Host ""

    # ── Available Scripts (with installed versions) ──
    Write-Host "  Available Scripts:" -ForegroundColor Yellow
    Write-Host ""

    $vMap = Get-VersionMap
    $nc = 30

    $printRow = {
        param([string]$id, [string]$name, [string]$desc)
        $ver = $vMap[$id]
        $hasVer = -not [string]::IsNullOrWhiteSpace($ver)
        Write-Host "    $id  $($name.PadRight($nc)) " -NoNewline
        Write-Host $desc -ForegroundColor DarkGray -NoNewline
        if ($hasVer) {
            Write-Host "  [" -NoNewline -ForegroundColor DarkGray
            Write-Host "v$ver" -NoNewline -ForegroundColor Green
            Write-Host "]" -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-Host "    ID  $("Name".PadRight($nc))  Description" -ForegroundColor DarkGray
    Write-Host "    --  $(''.PadRight($nc, '-'))  $(''.PadRight(50, '-'))" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Core Tools" -ForegroundColor Magenta
    & $printRow "01" "Install VS Code"          "Install Visual Studio Code (Stable/Insiders)"
    & $printRow "02" "Chocolatey"               "Install Chocolatey package manager"
    & $printRow "03" "Node.js + Yarn + Bun"     "Install Node.js LTS, Yarn, Bun, verify npx"
    & $printRow "04" "pnpm"                     "Install pnpm, configure global store"
    & $printRow "05" "Python"                   "Install Python, configure pip user site"
    & $printRow "41" "Python Libraries"         "Install pip packages: ML, viz, web, jupyter (by group)"
    & $printRow "06" "Golang"                   "Install Go, configure GOPATH and go env"
    & $printRow "07" "Git + LFS + gh"           "Install Git, Git LFS, GitHub CLI, configure settings"
    & $printRow "08" "GitHub Desktop"           "Install GitHub Desktop via Chocolatey"
    & $printRow "09" "C++ (MinGW-w64)"          "Install MinGW-w64 C++ compiler, verify g++/gcc/make"
    & $printRow "16" "PHP"                      "Install PHP via Chocolatey"
    & $printRow "17" "PowerShell (latest)"      "Install latest PowerShell via Winget/Chocolatey"
    & $printRow "38" "Flutter + Dart"           "Install Flutter SDK, Dart, Android toolchain"
    & $printRow "39" ".NET SDK"                 "Install .NET SDK (6/8/9), configure dotnet CLI"
    & $printRow "40" "Java (OpenJDK)"           "Install OpenJDK via Chocolatey (17/21)"
    Write-Host ""
    Write-Host "    Optional" -ForegroundColor Magenta
    & $printRow "10" "VSCode Context Menu Fix"  "Add/repair VSCode right-click context menu entries"
    & $printRow "11" "VSCode Settings Sync"     "Sync VSCode settings, keybindings, and extensions"
    & $printRow "31" "PowerShell Context Menu"  "Add Open PowerShell Here to right-click menu"
    Write-Host ""
    Write-Host "    Orchestrator" -ForegroundColor Magenta
    & $printRow "12" "Install All Dev Tools"    "Interactive grouped menu: pick tools or install everything"
    & $printRow "30" "Install Databases"        "Interactive database installer (SQL, NoSQL, file-based)"
    Write-Host ""
    Write-Host "    Utilities" -ForegroundColor Magenta
    & $printRow "13" "Audit Mode"               "Scan configs, specs, suggestions for stale IDs"
    & $printRow "14" "Install Winget"           "Install/verify Winget package manager (standalone)"
    & $printRow "15" "Windows Tweaks"           "Chris Titus Windows Utility (tweaks and debloating)"
    Write-Host ""
    Write-Host "    Desktop Tools" -ForegroundColor Magenta
    & $printRow "32" "DBeaver Community"        "Universal database visualization and management tool"
    & $printRow "33" "Notepad++ (NPP)"          "Install NPP, NPP Settings, or NPP + Settings"
    & $printRow "34" "Simple Sticky Notes"      "Install Simple Sticky Notes via Chocolatey"
    & $printRow "35" "GitMap"                   "Git repository navigator CLI tool"
    & $printRow "36" "OBS Studio"               "Install OBS, OBS Settings, or OBS + Settings"
    & $printRow "37" "Windows Terminal"          "Install WT, WT Settings, or WT + Settings"
    Write-Host ""

    Write-Host "  Script 12 (Install All Dev Tools):" -ForegroundColor Yellow
    Write-Host "    $(".\run.ps1 -I 12".PadRight($kc))" -NoNewline; Write-Host "Interactive menu -- pick what to install" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 12 -- -All".PadRight($kc))" -NoNewline; Write-Host "Install everything without prompting" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 12 -- -Skip 04,06".PadRight($kc))" -NoNewline; Write-Host "Skip pnpm and Go" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -I 12 -- -Only 02,03".PadRight($kc))" -NoNewline; Write-Host "Run only Package Managers + Node.js" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "  Defaults Mode:" -ForegroundColor Yellow
    Write-Host "    $(".\run.ps1 -d -Defaults".PadRight($kc))" -NoNewline; Write-Host "All-dev with defaults, prompt to confirm" -ForegroundColor DarkGray
    Write-Host "    $(".\run.ps1 -d -Defaults -Y".PadRight($kc))" -NoNewline; Write-Host "All-dev with defaults, auto-confirm" -ForegroundColor DarkGray
    Write-Host ""

    # Resolve actual default dev directory dynamically (saved path > smart detect)
    # Quiet inline detection -- avoids the noisy logging in Find-BestDevDrive.
    $resolvedDefault = $null
    $resolvedSource  = $null
    try {
        $devDirHelperPath = Join-Path $RootDir "scripts\shared\dev-dir.ps1"
        $isDevDirHelperPresent = Test-Path $devDirHelperPath
        if ($isDevDirHelperPresent) {
            . $devDirHelperPath
            $savedPath = Get-SavedDevPath
            $hasSavedPath = $null -ne $savedPath
            if ($hasSavedPath) {
                $resolvedDefault = $savedPath
                $resolvedSource  = "saved via .\run.ps1 path"
            }
        }
    } catch {}

    $isResolvedMissing = [string]::IsNullOrWhiteSpace($resolvedDefault)
    if ($isResolvedMissing) {
        # Quiet drive scan: E: > D: > best non-system fixed drive >= 10 GB free
        $minFreeGB = 10
        $sysLetter = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C" } else { $env:SystemDrive.TrimEnd('\').Substring(0, 1) }
        $bestLetter = $null
        $bestSource = $null
        try {
            $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
            $diskMap = @{}
            foreach ($d in $disks) {
                $letter = $d.DeviceID.Substring(0, 1)
                $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                $diskMap[$letter] = $freeGB
            }
            $hasGoodE = $diskMap.ContainsKey("E") -and $diskMap["E"] -ge $minFreeGB
            $hasGoodD = $diskMap.ContainsKey("D") -and $diskMap["D"] -ge $minFreeGB
            if ($hasGoodE) {
                $bestLetter = "E"; $bestSource = "auto-detected: E: drive ($($diskMap['E']) GB free)"
            } elseif ($hasGoodD) {
                $bestLetter = "D"; $bestSource = "auto-detected: D: drive ($($diskMap['D']) GB free)"
            } else {
                $best = $diskMap.GetEnumerator() |
                    Where-Object { $_.Key -ne $sysLetter -and $_.Key -ne "E" -and $_.Key -ne "D" -and $_.Value -ge $minFreeGB } |
                    Sort-Object Value -Descending | Select-Object -First 1
                $hasBest = $null -ne $best
                if ($hasBest) {
                    $bestLetter = $best.Key
                    $bestSource = "auto-detected: $($best.Key): drive ($($best.Value) GB free)"
                }
            }
        } catch {}

        $hasBestLetter = $null -ne $bestLetter
        if ($hasBestLetter) {
            $resolvedDefault = "${bestLetter}:\dev-tool"
            $resolvedSource  = $bestSource
        } else {
            $resolvedDefault = "${sysLetter}:\dev-tool"
            $resolvedSource  = "fallback to system drive (no qualified drive >= $minFreeGB GB free)"
        }
    }

    Write-Host "    Default dev directory: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$resolvedDefault " -NoNewline -ForegroundColor White
    Write-Host "($resolvedSource)" -ForegroundColor DarkGray
    Write-Host "    Override with: " -NoNewline -ForegroundColor DarkGray; Write-Host ".\run.ps1 -I 12 -- -Path F:\dev-tool" -ForegroundColor White
    Write-Host "    Default VS Code edition: " -NoNewline -ForegroundColor DarkGray; Write-Host "Stable" -ForegroundColor White
    Write-Host "    Default sync mode: " -NoNewline -ForegroundColor DarkGray; Write-Host "Overwrite" -ForegroundColor White
    Write-Host ""

    Write-Host "  Per-script help:" -ForegroundColor Yellow
    Write-Host "    $(".\run.ps1 -I <number> -- -Help".PadRight($kc))" -NoNewline; Write-Host "Show help for a specific script" -ForegroundColor DarkGray
    Write-Host ""
}

# ── Keyword table (compact view) ────────────────────────────────────
function Show-KeywordTable {
    param([switch]$Inline)

    $isStandalone = -not $Inline
    if ($isStandalone) {
        Write-Host ""
        Write-Host "  Available Keywords" -ForegroundColor Cyan
        Write-Host "  ==================" -ForegroundColor DarkGray
    } else {
        Write-Host "  Available Keywords:" -ForegroundColor Yellow
    }
    Write-Host ""

    $kwCol = 28
    $descCol = 36

    Write-Host "    $("Keyword".PadRight($kwCol))$("Description".PadRight($descCol))Script ID" -ForegroundColor DarkGray
    Write-Host "    $(''.PadRight($kwCol, '-'))$(''.PadRight($descCol, '-'))---------" -ForegroundColor DarkGray

    Write-Host "    $("vscode, vs-code".PadRight($kwCol))$("VS Code".PadRight($descCol))01"
    Write-Host "    $("choco, chocolatey".PadRight($kwCol))$("Chocolatey".PadRight($descCol))02"
    Write-Host "    $("nodejs, node".PadRight($kwCol))$("Node.js + Yarn + Bun".PadRight($descCol))03"
    Write-Host "    $("pnpm".PadRight($kwCol))$("Node.js + pnpm".PadRight($descCol))03, 04"
    Write-Host ""
    Write-Host "    Python & Libraries" -ForegroundColor Magenta
    Write-Host "    $("python, pip".PadRight($kwCol))$("Python + pip".PadRight($descCol))05"
    Write-Host "    $("pylibs".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("python-libs, pip-libs".PadRight($kwCol))$("All pip libraries only".PadRight($descCol))41"
    Write-Host "    $("ml-libs, ml-full".PadRight($kwCol))$("ML libraries".PadRight($descCol))41"
    Write-Host "    $("jupyter+libs".PadRight($kwCol))$("Jupyter group only".PadRight($descCol))41"
    Write-Host "    $("viz-libs".PadRight($kwCol))$("Visualization group".PadRight($descCol))41"
    Write-Host "    $("web-libs".PadRight($kwCol))$("Web frameworks group".PadRight($descCol))41"
    Write-Host "    $("scraping-libs".PadRight($kwCol))$("Scraping group".PadRight($descCol))41"
    Write-Host "    $("db-libs".PadRight($kwCol))$("Database group".PadRight($descCol))41"
    Write-Host "    $("cv-libs".PadRight($kwCol))$("Computer Vision group".PadRight($descCol))41"
    Write-Host "    $("data-libs".PadRight($kwCol))$("Data tools group".PadRight($descCol))41"
    Write-Host "    $("python+viz".PadRight($kwCol))$("Python + viz group".PadRight($descCol))05, 41"
    Write-Host "    $("python+web".PadRight($kwCol))$("Python + web group".PadRight($descCol))05, 41"
    Write-Host "    $("python+scraping".PadRight($kwCol))$("Python + scraping group".PadRight($descCol))05, 41"
    Write-Host "    $("python+db".PadRight($kwCol))$("Python + database group".PadRight($descCol))05, 41"
    Write-Host "    $("python+cv".PadRight($kwCol))$("Python + CV group".PadRight($descCol))05, 41"
    Write-Host "    $("python+data".PadRight($kwCol))$("Python + data group".PadRight($descCol))05, 41"
    Write-Host "    $("python+ml".PadRight($kwCol))$("Python + ML group".PadRight($descCol))05, 41"
    Write-Host "    $("python+libs, ml-dev".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("python+jupyter".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("pip+jupyter+libs".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("data-science".PadRight($kwCol))$("Python + data/viz libs".PadRight($descCol))05, 41"
    Write-Host "    $("ai-dev, deep-learning".PadRight($kwCol))$("Python + ML libs".PadRight($descCol))05, 41"
    Write-Host ""
    Write-Host "    Languages & Runtimes" -ForegroundColor Magenta
    Write-Host "    $("go, golang".PadRight($kwCol))$("Go".PadRight($descCol))06"
    Write-Host "    $("git, gh".PadRight($kwCol))$("Git + LFS + GitHub CLI".PadRight($descCol))07"
    Write-Host "    $("github-desktop".PadRight($kwCol))$("GitHub Desktop".PadRight($descCol))08"
    Write-Host "    $("cpp, c++, gcc".PadRight($kwCol))$("C++ (MinGW-w64)".PadRight($descCol))09"
    Write-Host "    $("php, php+phpmyadmin".PadRight($kwCol))$("PHP + phpMyAdmin (default)".PadRight($descCol))16"
    Write-Host "    $("php-only".PadRight($kwCol))$("PHP only".PadRight($descCol))16"
    Write-Host "    $("phpmyadmin".PadRight($kwCol))$("phpMyAdmin only".PadRight($descCol))16"
    Write-Host "    $("powershell, pwsh".PadRight($kwCol))$("PowerShell (latest)".PadRight($descCol))17"
    Write-Host "    $("flutter, dart".PadRight($kwCol))$("Flutter SDK + Dart".PadRight($descCol))38"
    Write-Host "    $("dotnet, csharp, .net".PadRight($kwCol))$(".NET SDK".PadRight($descCol))39"
    Write-Host "    $("java, openjdk, jdk".PadRight($kwCol))$("OpenJDK".PadRight($descCol))40"
    Write-Host ""
    Write-Host "    Config & Settings" -ForegroundColor Magenta
    Write-Host "    $("context-menu".PadRight($kwCol))$("VSCode context menu fix".PadRight($descCol))10"
    Write-Host "    $("settings-sync".PadRight($kwCol))$("VSCode settings sync".PadRight($descCol))11"
    Write-Host "    $("pwsh-menu".PadRight($kwCol))$("PowerShell context menu".PadRight($descCol))31"
    Write-Host "    $("all-dev, all".PadRight($kwCol))$("Interactive dev tools menu".PadRight($descCol))12"
    Write-Host "    $("audit".PadRight($kwCol))$("Audit mode".PadRight($descCol))13"
    Write-Host "    $("health, healthcheck".PadRight($kwCol))$("Health check (audit + report)".PadRight($descCol))13"
    Write-Host "    $("winget".PadRight($kwCol))$("Winget package manager".PadRight($descCol))14"
    Write-Host "    $("tweaks".PadRight($kwCol))$("Windows tweaks".PadRight($descCol))15"
    Write-Host ""
    Write-Host "    Databases" -ForegroundColor Magenta
    Write-Host "    $("mysql".PadRight($kwCol))$("MySQL".PadRight($descCol))18"
    Write-Host "    $("mariadb".PadRight($kwCol))$("MariaDB".PadRight($descCol))19"
    Write-Host "    $("postgresql, postgres".PadRight($kwCol))$("PostgreSQL".PadRight($descCol))20"
    Write-Host "    $("sqlite".PadRight($kwCol))$("SQLite + DB Browser".PadRight($descCol))21"
    Write-Host "    $("mongodb, mongo".PadRight($kwCol))$("MongoDB".PadRight($descCol))22"
    Write-Host "    $("couchdb".PadRight($kwCol))$("CouchDB".PadRight($descCol))23"
    Write-Host "    $("redis".PadRight($kwCol))$("Redis".PadRight($descCol))24"
    Write-Host "    $("cassandra".PadRight($kwCol))$("Apache Cassandra".PadRight($descCol))25"
    Write-Host "    $("neo4j".PadRight($kwCol))$("Neo4j".PadRight($descCol))26"
    Write-Host "    $("elasticsearch".PadRight($kwCol))$("Elasticsearch".PadRight($descCol))27"
    Write-Host "    $("duckdb".PadRight($kwCol))$("DuckDB".PadRight($descCol))28"
    Write-Host "    $("litedb".PadRight($kwCol))$("LiteDB".PadRight($descCol))29"
    Write-Host "    $("databases, db".PadRight($kwCol))$("Database installer menu".PadRight($descCol))30"
    Write-Host ""
    Write-Host "    Desktop Tools" -ForegroundColor Magenta
    Write-Host "    $("notepad++, npp".PadRight($kwCol))$("NPP + Settings (install + sync)".PadRight($descCol))33"
    Write-Host "    $("npp+settings".PadRight($kwCol))$("NPP + Settings (explicit)".PadRight($descCol))33"
    Write-Host "    $("npp-settings".PadRight($kwCol))$("NPP Settings (settings only)".PadRight($descCol))33"
    Write-Host "    $("install-npp".PadRight($kwCol))$("Install NPP (install only)".PadRight($descCol))33"
    Write-Host "    $("sticky-notes, sticky".PadRight($kwCol))$("Simple Sticky Notes".PadRight($descCol))34"
    Write-Host "    $("gitmap, git-map".PadRight($kwCol))$("GitMap CLI".PadRight($descCol))35"
    Write-Host "    $("obs, obs+settings".PadRight($kwCol))$("OBS + Settings (install + sync)".PadRight($descCol))36"
    Write-Host "    $("obs-settings".PadRight($kwCol))$("OBS Settings (settings only)".PadRight($descCol))36"
    Write-Host "    $("install-obs".PadRight($kwCol))$("Install OBS (install only)".PadRight($descCol))36"
    Write-Host "    $("wt, windows-terminal".PadRight($kwCol))$("WT + Settings (install + sync)".PadRight($descCol))37"
    Write-Host "    $("wt+settings".PadRight($kwCol))$("WT + Settings (explicit)".PadRight($descCol))37"
    Write-Host "    $("wt-settings".PadRight($kwCol))$("WT Settings (settings only)".PadRight($descCol))37"
    Write-Host "    $("install-wt".PadRight($kwCol))$("Install WT (install only)".PadRight($descCol))37"
    Write-Host "    $("dbeaver, db-viewer".PadRight($kwCol))$("DBeaver + Settings (install + sync)".PadRight($descCol))32"
    Write-Host "    $("dbeaver-settings".PadRight($kwCol))$("DBeaver Settings (settings only)".PadRight($descCol))32"
    Write-Host "    $("install-dbeaver".PadRight($kwCol))$("Install DBeaver (install only)".PadRight($descCol))32"
    Write-Host ""
    Write-Host "    AI & Local LLM" -ForegroundColor Magenta
    Write-Host "    $("ollama, local-llm".PadRight($kwCol))$("Ollama (local LLM runner)".PadRight($descCol))42"
    Write-Host "    $("llama-cpp, llamacpp".PadRight($kwCol))$("llama.cpp + KoboldCPP".PadRight($descCol))43"
    Write-Host "    $("llama, gguf".PadRight($kwCol))$("llama.cpp (alias)".PadRight($descCol))43"
    Write-Host "    $("llm".PadRight($kwCol))$("LLM tools (Ollama)".PadRight($descCol))42"
    Write-Host "    $("kobold, koboldcpp".PadRight($kwCol))$("KoboldCPP (llama.cpp)".PadRight($descCol))43"
    Write-Host "    $("ollama-models".PadRight($kwCol))$("Ollama model pull only".PadRight($descCol))42"
    Write-Host "    $("llama-models".PadRight($kwCol))$("llama.cpp model picker only".PadRight($descCol))43"
    Write-Host "    $("ai-tools, local-ai".PadRight($kwCol))$("Ollama + llama.cpp".PadRight($descCol))42, 43"
    Write-Host "    $("ollama+llama".PadRight($kwCol))$("Ollama + llama.cpp".PadRight($descCol))42, 43"
    Write-Host "    $("ai-full, aifull".PadRight($kwCol))$("Python + libs + Ollama + llama.cpp".PadRight($descCol))05, 41, 42, 43"
    Write-Host ""
    Write-Host "    DevOps & Containers" -ForegroundColor Magenta
    Write-Host "    $("rust, cargo".PadRight($kwCol))$("Rust + Cargo".PadRight($descCol))44"
    Write-Host "    $("docker".PadRight($kwCol))$("Docker Desktop".PadRight($descCol))45"
    Write-Host "    $("kubernetes, k8s".PadRight($kwCol))$("Kubernetes tools".PadRight($descCol))46"
    Write-Host "    $("devops".PadRight($kwCol))$("Git + Docker + Kubernetes".PadRight($descCol))07, 45, 46"
    Write-Host "    $("container-dev".PadRight($kwCol))$("Docker + Kubernetes".PadRight($descCol))45, 46"
    Write-Host "    $("systems-dev".PadRight($kwCol))$("C++ + Rust".PadRight($descCol))09, 44"
    Write-Host ""
    Write-Host "    Remote installers (irm | iex)" -ForegroundColor Magenta
    Write-Host "    $("clean-code, cg, cc".PadRight($kwCol))$("Coding Guidelines v15".PadRight($descCol))remote"
    Write-Host "    $("code-guide".PadRight($kwCol))$("Coding Guidelines v15 (alias)".PadRight($descCol))remote"
    Write-Host "    $("coding-guidelines".PadRight($kwCol))$("Coding Guidelines v15 (alias)".PadRight($descCol))remote"
    Write-Host "    $("starship, ss".PadRight($kwCol))$("Starship cross-shell prompt".PadRight($descCol))remote"
    Write-Host "    $("starship-prompt".PadRight($kwCol))$("Starship (alias)".PadRight($descCol))remote"
    Write-Host "    $("oh-my-posh, omp, posh".PadRight($kwCol))$("Oh My Posh prompt theme".PadRight($descCol))remote"
    Write-Host "    $("ohmyposh".PadRight($kwCol))$("Oh My Posh (alias)".PadRight($descCol))remote"
    Write-Host "    $("scoop, sc".PadRight($kwCol))$("Scoop CLI installer".PadRight($descCol))remote"
    Write-Host "    $("scoop-installer".PadRight($kwCol))$("Scoop (alias)".PadRight($descCol))remote"
    Write-Host ""

    Write-Host "  Combo Shortcuts:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    $("vscode+settings, vscode+s".PadRight($kwCol))$("VSCode + Settings Sync".PadRight($descCol))01, 11"
    Write-Host "    $("vscode+menu+settings, vms".PadRight($kwCol))$("VSCode + Menu Fix + Sync".PadRight($descCol))01, 10, 11"
    Write-Host "    $("git+desktop, git+gh".PadRight($kwCol))$("Git + GitHub Desktop".PadRight($descCol))07, 08"
    Write-Host "    $("node+pnpm".PadRight($kwCol))$("Node.js + pnpm".PadRight($descCol))03, 04"
    Write-Host "    $("frontend".PadRight($kwCol))$("VSCode + Node + pnpm + Sync".PadRight($descCol))01, 03, 04, 11"
    Write-Host "    $("backend".PadRight($kwCol))$("Python + Go + PHP + PG + .NET + Java".PadRight($descCol))05, 06, 16, 20, 39, 40"
    Write-Host "    $("web-dev, webdev".PadRight($kwCol))$("VSCode + Node + pnpm + Git + Sync".PadRight($descCol))01, 03, 04, 07, 11"
    Write-Host "    $("essentials".PadRight($kwCol))$("VSCode + Choco + Node + Git + Sync".PadRight($descCol))01, 02, 03, 07, 11"
    Write-Host ""
    Write-Host "    Python & Libraries" -ForegroundColor Magenta
    Write-Host "    $("pylibs".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("python+libs, ml-dev".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("python+jupyter".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("pip+jupyter+libs".PadRight($kwCol))$("Python + all libraries".PadRight($descCol))05, 41"
    Write-Host "    $("jupyter+libs".PadRight($kwCol))$("Jupyter group only".PadRight($descCol))41"
    Write-Host "    $("data-science, datascience".PadRight($kwCol))$("Python + data/viz libs".PadRight($descCol))05, 41"
    Write-Host "    $("ai-dev, aidev".PadRight($kwCol))$("Python + ML libs".PadRight($descCol))05, 41"
    Write-Host "    $("deep-learning, ml-full".PadRight($kwCol))$("Python + ML libs".PadRight($descCol))05, 41"
    Write-Host ""
    Write-Host "    General" -ForegroundColor Magenta
    Write-Host "    $("full-stack, fullstack".PadRight($kwCol))$("Everything for full-stack dev".PadRight($descCol))01-09, 11, 16, 39, 40"
    Write-Host "    $("mobile-dev".PadRight($kwCol))$("Flutter mobile dev".PadRight($descCol))38"
    Write-Host "    $("data-dev".PadRight($kwCol))$("Postgres + Redis + DuckDB + DBeaver".PadRight($descCol))20, 24, 28, 32"
    Write-Host ""
    Write-Host "  Usage: " -NoNewline -ForegroundColor Yellow; Write-Host ".\run.ps1 install <keyword>[,<keyword>,...]"
    Write-Host ""
    }





function Resolve-InstallKeywords {
    param(
        [string[]]$Keywords
    )

    $keywordsFile = Join-Path $RootDir "scripts\shared\install-keywords.json"
    $isKeywordsFileMissing = -not (Test-Path $keywordsFile)
    if ($isKeywordsFileMissing) {
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Keyword mapping not found: $keywordsFile"
        return $null
    }

    $keywordData = Get-Content $keywordsFile -Raw | ConvertFrom-Json
    $keywordMap = $keywordData.keywords
    $modesMap  = $keywordData.modes
    $remoteMap = $keywordData.remote

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($keywordGroup in $Keywords) {
        $isKeywordGroupMissing = [string]::IsNullOrWhiteSpace($keywordGroup)
        if ($isKeywordGroupMissing) {
            continue
        }

        $parts = $keywordGroup -split '[,\s]+' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_.Length -gt 0 }
        foreach ($part in $parts) {
            $tokens.Add($part)
        }
    }

    # Mode priority: install+settings > install-only / settings-only > null
    # When multiple keywords target the same script WITH THE SAME mode, merge to the highest.
    # When modes DIFFER (e.g. "group ml" vs "group jupyter"), keep both as separate runs.
    $modePriority = @{
        "install+settings" = 3
        "install-only"     = 2
        "settings-only"    = 1
    }

    # Build a list of {Id, Mode} entries -- allow same script ID with different modes
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $hasError = $false

    foreach ($token in $tokens) {
        # Try exact match first, then try without hyphens
        $ids = $keywordMap.$token
        if ($null -eq $ids) {
            $stripped = $token -replace '-', ''
            $ids = $keywordMap.$stripped
        }
        $isUnknown = $null -eq $ids
        if ($isUnknown) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "Unknown keyword: '$token'"
            $hasError = $true
            continue
        }

        # Determine mode override for this token (if any)
        $tokenModes = $modesMap.$token
        foreach ($id in $ids) {
            # ── String entry (subcommand or remote convention) ─────────
            # e.g. "os:clean", "profile:base"  -- routes to scripts/<dispatcher>/run.ps1 <action> <args>
            # e.g. "remote:clean-code"         -- streams a remote URL via 'irm | iex'
            $isStringEntry = ($id -is [string]) -and ($id -match '^([a-z]+):(.+)$')
            if ($isStringEntry) {
                $dispatcher = $Matches[1]
                $action     = $Matches[2]

                $isRemoteEntry = $dispatcher -eq "remote"
                if ($isRemoteEntry) {
                    $remoteEntry = $null
                    $hasRemoteMap = $null -ne $remoteMap
                    if ($hasRemoteMap) {
                        $remoteEntry = $remoteMap.$action
                    }
                    # A remote entry must supply either 'url' (HTTP) or 'path' (repo-relative wrapper, v0.47.1+).
                    $remoteUrl  = $null
                    $remotePath = $null
                    if ($null -ne $remoteEntry) {
                        if ($remoteEntry.PSObject.Properties['url'])  { $remoteUrl  = "$($remoteEntry.url)".Trim() }
                        if ($remoteEntry.PSObject.Properties['path']) { $remotePath = "$($remoteEntry.path)".Trim() }
                    }
                    $hasUrl  = -not [string]::IsNullOrWhiteSpace($remoteUrl)
                    $hasPath = -not [string]::IsNullOrWhiteSpace($remotePath)
                    $isRemoteMissing = $null -eq $remoteEntry -or (-not $hasUrl -and -not $hasPath)
                    if ($isRemoteMissing) {
                        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
                        Write-Host "Remote keyword '$token' resolves to 'remote:$action' but no source is mapped in $keywordsFile (need 'remote.$action.url' OR 'remote.$action.path')."
                        $hasError = $true
                        continue
                    }
                    $remoteSha = $null
                    if ($remoteEntry.PSObject.Properties['sha256']) {
                        $rawSha = "$($remoteEntry.sha256)".Trim()
                        if (-not [string]::IsNullOrWhiteSpace($rawSha)) { $remoteSha = $rawSha.ToLowerInvariant() }
                    }
                    # Resolve local path against repo root if present.
                    $resolvedLocalPath = $null
                    if ($hasPath) {
                        $resolvedLocalPath = Join-Path $RootDir $remotePath
                    }
                    $entries.Add(@{ Kind = "remote"; Key = $action; Url = $remoteUrl; LocalPath = $resolvedLocalPath; Label = $remoteEntry.label; Sha256 = $remoteSha; Token = $token })
                    continue
                }

                $entries.Add(@{ Kind = "subcommand"; Dispatcher = $dispatcher; Action = $action; Token = $token })
                continue
            }

            $mode = $null
            if ($null -ne $tokenModes) {
                $mode = $tokenModes."$id"
            }

            # Check if an entry with the same ID already exists
            $existingEntry = $null
            foreach ($e in $entries) {
                $isScriptEntry = ($e.Kind -eq $null) -or ($e.Kind -eq "script")
                if (-not $isScriptEntry) { continue }
                $isSameId = $e.Id -eq [int]$id
                if ($isSameId) {
                    # Same ID: check if mode is identical or mergeable
                    $isSameMode = $e.Mode -eq $mode
                    $isBothNull = ($null -eq $e.Mode) -and ($null -eq $mode)
                    $isBothMergePriority = ($null -ne $e.Mode -and $modePriority.ContainsKey($e.Mode)) -and ($null -ne $mode -and $modePriority.ContainsKey($mode))
                    if ($isSameMode -or $isBothNull -or $isBothMergePriority) {
                        $existingEntry = $e
                        break
                    }
                }
            }

            $isNewEntry = $null -eq $existingEntry
            if ($isNewEntry) {
                $entries.Add(@{ Kind = "script"; Id = [int]$id; Mode = $mode })
            } else {
                # Merge: keep the higher-priority mode (only for install+settings / install-only / settings-only)
                $existingPri = if ($null -ne $existingEntry.Mode -and $modePriority.ContainsKey($existingEntry.Mode)) { $modePriority[$existingEntry.Mode] } else { 0 }
                $newPri      = if ($null -ne $mode -and $modePriority.ContainsKey($mode)) { $modePriority[$mode] } else { 0 }
                $isNewHigher = $newPri -gt $existingPri
                if ($isNewHigher) {
                    $existingEntry.Mode = $mode
                }
            }
        }
    }

    if ($hasError) {
        Write-Host ""
        Write-Host "  Run .\run.ps1 -Help to see all available keywords" -ForegroundColor Cyan
        return $null
    }

    # Sort: subcommands + remote streams keep their original order at the END (run after script installs).
    # Script entries are sorted by ID. We split, sort scripts, then concat.
    $scriptEntries     = @($entries | Where-Object { $_.Kind -eq "script" -or $null -eq $_.Kind })
    $subcommandEntries = @($entries | Where-Object { $_.Kind -eq "subcommand" })
    $remoteEntries     = @($entries | Where-Object { $_.Kind -eq "remote" })
    $sortedScripts     = $scriptEntries | Sort-Object { [int]$_.Id }
    $sorted            = @($sortedScripts) + @($subcommandEntries) + @($remoteEntries)
    return $sorted
}

# ── Run a single script by ID ───────────────────────────────────────
function Invoke-ScriptById {
    param(
        [int]$ScriptId,
        [hashtable]$ExtraArgs = @{}
    )

    $prefix = "{0:D2}" -f $ScriptId
    $registryPath = Join-Path $RootDir "scripts\registry.json"
    $isRegistryAvailable = Test-Path $registryPath

    $scriptDir = $null
    if ($isRegistryAvailable) {
        $registry = Get-Content $registryPath -Raw | ConvertFrom-Json
        $folderName = $registry.scripts.$prefix

        $isRegistered = [bool]$folderName
        if ($isRegistered) {
            $scriptDir = Get-Item (Join-Path $RootDir "scripts\$folderName") -ErrorAction SilentlyContinue
        }
    } else {
        $pattern = Join-Path $RootDir "scripts/$prefix-*"
        $scriptDir = @(Get-Item $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -and (Test-Path (Join-Path $_.FullName "run.ps1")) }) |
            Select-Object -First 1
    }

    $isScriptMissing = -not $scriptDir -or -not (Test-Path $scriptDir.FullName)
    if ($isScriptMissing) {
        Write-Host ""
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "No script folder found for ID $prefix"
        return $false
    }

    $scriptFile = Join-Path $scriptDir.FullName "run.ps1"
    $isRunFileMissing = -not (Test-Path $scriptFile)
    if ($isRunFileMissing) {
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "run.ps1 not found in $($scriptDir.Name)"
        return $false
    }

    # Clean & create logs folder
    $logsDir = Join-Path $scriptDir.FullName "logs"
    if (Test-Path $logsDir) {
        Remove-Item -Path $logsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null

    Write-Host ""
    Write-Host "  [ RUN   ] " -ForegroundColor Magenta -NoNewline
    Write-Host "Executing: $($scriptDir.Name)\run.ps1"
    Write-Host ""

    & $scriptFile @ExtraArgs
    return $true
}

# ── Load choco-update helper ─────────────────────────────────────────
. (Join-Path $RootDir "scripts\shared\choco-update.ps1")

# ── Export command function ────────────────────────────────────────────
function Invoke-ExportCommand {
    param([string[]]$Args)

    Write-Host ""
    Write-Host "  Export Settings" -ForegroundColor Cyan
    Write-Host "  ===============" -ForegroundColor DarkGray
    Write-Host ""

    # Settings-capable scripts: scriptId -> keyword for display
    $exportScripts = @{
        "32" = "DBeaver"
        "33" = "Notepad++"
        "36" = "OBS Studio"
        "37" = "Windows Terminal"
    }

    # Parse filter keywords from args
    $filterKeywords = @()
    $hasArgs = $null -ne $Args -and $Args.Count -gt 0
    if ($hasArgs) {
        foreach ($arg in $Args) {
            $tokens = $arg -split '[,\s]+' | Where-Object { $_.Length -gt 0 }
            $filterKeywords += $tokens
        }
    }

    # Keyword-to-scriptId mapping for filtering
    $exportKeywordMap = @{
        "dbeaver"  = "32"; "db-viewer" = "32"; "dbviewer" = "32"
        "npp"      = "33"; "notepad++" = "33"; "notepadpp" = "33"
        "obs"      = "36"; "obs-studio" = "36"
        "wt"       = "37"; "windows-terminal" = "37"
    }

    # Resolve which scripts to export
    $scriptIds = @()
    $hasFilters = $filterKeywords.Count -gt 0
    if ($hasFilters) {
        foreach ($kw in $filterKeywords) {
            $kwLower = $kw.ToLower()
            $hasMapping = $exportKeywordMap.ContainsKey($kwLower)
            if ($hasMapping) {
                $scriptIds += $exportKeywordMap[$kwLower]
            } else {
                Write-Host "  [ WARN ] Unknown export keyword: $kw" -ForegroundColor Yellow
                Write-Host "           Available: dbeaver, npp, obs, wt" -ForegroundColor DarkGray
            }
        }
        $scriptIds = @($scriptIds | Select-Object -Unique)
    } else {
        $scriptIds = @($exportScripts.Keys | Sort-Object)
    }

    $hasNoScripts = $scriptIds.Count -eq 0
    if ($hasNoScripts) {
        Write-Host "  [ FAIL ] No valid export targets specified" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Usage:" -ForegroundColor Yellow
        Write-Host "    .\run.ps1 export              # export all settings"
        Write-Host "    .\run.ps1 export npp,obs      # export specific apps"
        Write-Host "    .\run.ps1 export dbeaver      # export DBeaver settings"
        Write-Host ""
        return
    }

    Write-Host "  Exporting $($scriptIds.Count) app(s): $($scriptIds | ForEach-Object { $exportScripts[$_] }) " -ForegroundColor Magenta
    Write-Host ""

    $successCount = 0
    $failCount = 0

    foreach ($id in $scriptIds) {
        $label = $exportScripts[$id]
        Write-Host "  [ RUN  ] Exporting: $label (script $id)..." -ForegroundColor Cyan

        try {
            $isExported = Invoke-ScriptById -ScriptId $id -ExtraArgs @("export")
            if ($isExported) {
                $successCount++
            } else {
                $failCount++
            }
        } catch {
            Write-Host "  [ FAIL ] Export failed for $label : $_" -ForegroundColor Red
            $failCount++
        }
    }

    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor DarkGray
    $hasFails = $failCount -gt 0
    if ($hasFails) {
        Write-Host "  [ DONE ] $successCount of $($scriptIds.Count) exported successfully ($failCount failed)" -ForegroundColor Yellow
    } else {
        Write-Host "  [ DONE ] $successCount of $($scriptIds.Count) exported successfully" -ForegroundColor Green
    }
    Write-Host ""
}

# ── Status command function ────────────────────────────────────────────
function Invoke-StatusCommand {
    param([string[]]$Args)

    Write-Host ""
    Write-Host "  Tool Status Dashboard" -ForegroundColor Cyan
    Write-Host "  =====================" -ForegroundColor DarkGray
    Write-Host ""

    $installedDir = Join-Path $RootDir ".installed"
    $isInstalledDirMissing = -not (Test-Path $installedDir)
    if ($isInstalledDirMissing) {
        Write-Host "  No tools tracked yet. Run some install scripts first." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $records = Get-ChildItem -Path $installedDir -Filter "*.json" -File | Sort-Object Name
    $hasNoRecords = $records.Count -eq 0
    if ($hasNoRecords) {
        Write-Host "  No tools tracked yet. Run some install scripts first." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    # Parse --no-choco flag
    $isNoChoco = $false
    if ($null -ne $Args) {
        foreach ($arg in $Args) {
            $argLower = "$arg".Trim().ToLower()
            $isNoChocoFlag = $argLower -eq "--no-choco" -or $argLower -eq "--fast"
            if ($isNoChocoFlag) { $isNoChoco = $true }
        }
    }

    # Table header
    $nameCol = 24
    $versionCol = 24
    $statusCol = 12
    $methodCol = 12
    $header = "    {0}  {1}  {2}  {3}" -f "Tool".PadRight($nameCol), "Version".PadRight($versionCol), "Status".PadRight($statusCol), "Source".PadRight($methodCol)
    Write-Host $header -ForegroundColor DarkGray
    $separator = "    {0}  {1}  {2}  {3}" -f ("-" * $nameCol), ("-" * $versionCol), ("-" * $statusCol), ("-" * $methodCol)
    Write-Host $separator -ForegroundColor DarkGray

    $okCount = 0
    $errorCount = 0
    $unknownCount = 0

    foreach ($file in $records) {
        try {
            $record = Get-Content $file.FullName -Raw | ConvertFrom-Json
        } catch {
            continue
        }

        $toolName = if ($record.name) { $record.name } else { $file.BaseName }
        $version  = if ($record.version) { $record.version } else { "unknown" }
        $method   = if ($record.method) { $record.method } else { "--" }

        # Determine status
        $hasError = $record.lastError -and ($record.lastError -ne "")
        $isVersionUnknown = $version -eq "unknown" -or $version -eq "installed" -or $version -eq "(version pending)"

        $status = "ok"
        $statusColor = "Green"
        if ($hasError) {
            $status = "error"
            $statusColor = "Red"
            $errorCount++
        } elseif ($isVersionUnknown) {
            $status = "unverified"
            $statusColor = "Yellow"
            $unknownCount++
        } else {
            $okCount++
        }

        # Truncate long values
        $displayName = if ($toolName.Length -gt $nameCol) { $toolName.Substring(0, $nameCol - 2) + ".." } else { $toolName }
        $displayVer  = if ($version.Length -gt $versionCol) { $version.Substring(0, $versionCol - 2) + ".." } else { $version }

        Write-Host "    $($displayName.PadRight($nameCol))  $($displayVer.PadRight($versionCol))  " -NoNewline
        Write-Host $status.PadRight($statusCol) -ForegroundColor $statusColor -NoNewline
        Write-Host "  $method"
    }

    Write-Host ""
    Write-Host "  Summary: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$okCount ok" -ForegroundColor Green -NoNewline
    $hasErrors = $errorCount -gt 0
    if ($hasErrors) {
        Write-Host ", $errorCount error(s)" -ForegroundColor Red -NoNewline
    }
    $hasUnknowns = $unknownCount -gt 0
    if ($hasUnknowns) {
        Write-Host ", $unknownCount unverified" -ForegroundColor Yellow -NoNewline
    }
    Write-Host " -- $($records.Count) total tracked"

    # Optionally check choco outdated
    $isChocoCheckEnabled = -not $isNoChoco
    if ($isChocoCheckEnabled) {
        $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
        $isChocoAvailable = $null -ne $chocoCmd
        if ($isChocoAvailable) {
            Write-Host ""
            Write-Host "  Checking for outdated packages..." -ForegroundColor DarkGray
            try {
                $outdated = & choco outdated -r 2>$null | Where-Object { $_ -match '\|' }
                $hasOutdated = $null -ne $outdated -and @($outdated).Count -gt 0
                if ($hasOutdated) {
                    Write-Host ""
                    Write-Host "  Outdated Packages:" -ForegroundColor Yellow
                    foreach ($line in $outdated) {
                        $parts = $line -split '\|'
                        $hasParts = $parts.Count -ge 3
                        if ($hasParts) {
                            $pkgName = $parts[0]
                            $currentVer = $parts[1]
                            $availableVer = $parts[2]
                            Write-Host "    $($pkgName.PadRight(24))  $currentVer -> $availableVer" -ForegroundColor DarkGray
                        }
                    }
                } else {
                    Write-Host "  All Chocolatey packages are up to date." -ForegroundColor Green
                }
            } catch {
                Write-Host "  Could not check Chocolatey outdated: $_" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "  Tip: Use '.\run.ps1 status --no-choco' to skip the outdated check." -ForegroundColor DarkGray
    Write-Host ""
}

# ── Doctor command function ────────────────────────────────────────────
function Invoke-DoctorCommand {
    <#
    .SYNOPSIS
        Quick health-check that verifies the project setup itself.
        Lighter than full audit -- runs in < 2 seconds.
    #>

    Write-Host ""
    Write-Host "  Project Doctor" -ForegroundColor Cyan
    Write-Host "  ==============" -ForegroundColor DarkGray
    Write-Host ""

    $passCount = 0
    $failCount = 0
    $warnCount = 0

    # Helper to print check results
    function Write-Check {
        param([string]$Label, [string]$Status, [string]$Detail = "")
        switch ($Status) {
            "pass" {
                Write-Host "    [PASS] " -ForegroundColor Green -NoNewline
                Write-Host $Label -NoNewline
                if ($Detail) { Write-Host " -- $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
                $script:passCount++
            }
            "fail" {
                Write-Host "    [FAIL] " -ForegroundColor Red -NoNewline
                Write-Host $Label -NoNewline
                if ($Detail) { Write-Host " -- $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
                $script:failCount++
            }
            "warn" {
                Write-Host "    [WARN] " -ForegroundColor Yellow -NoNewline
                Write-Host $Label -NoNewline
                if ($Detail) { Write-Host " -- $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
                $script:warnCount++
            }
        }
    }

    # 1. Check scripts root directory
    $scriptsRoot = Join-Path $RootDir "scripts"
    $hasScriptsDir = Test-Path $scriptsRoot
    if ($hasScriptsDir) {
        Write-Check "Scripts directory exists" "pass" $scriptsRoot
    } else {
        Write-Check "Scripts directory exists" "fail" "Not found: $scriptsRoot"
    }

    # 2. Check version.json
    $versionFile = Join-Path $scriptsRoot "version.json"
    $hasVersionFile = Test-Path $versionFile
    if ($hasVersionFile) {
        try {
            $versionData = Get-Content $versionFile -Raw | ConvertFrom-Json
            $hasVersion = -not [string]::IsNullOrWhiteSpace($versionData.version)
            if ($hasVersion) {
                Write-Check "version.json is valid" "pass" "v$($versionData.version)"
            } else {
                Write-Check "version.json is valid" "fail" "Empty version field"
            }
        } catch {
            Write-Check "version.json is valid" "fail" "Parse error: $_"
        }
    } else {
        Write-Check "version.json is valid" "fail" "Not found"
    }

    # 3. Check registry.json
    $registryFile = Join-Path $scriptsRoot "registry.json"
    $hasRegistry = Test-Path $registryFile
    if ($hasRegistry) {
        try {
            $registryData = Get-Content $registryFile -Raw | ConvertFrom-Json
            $registryCount = ($registryData.scripts.PSObject.Properties | Measure-Object).Count
            Write-Check "registry.json is valid" "pass" "$registryCount scripts registered"
        } catch {
            Write-Check "registry.json is valid" "fail" "Parse error: $_"
        }
    } else {
        Write-Check "registry.json is valid" "fail" "Not found"
    }

    # 4. Check registry IDs match existing folders
    if ($hasRegistry) {
        $missingFolders = @()
        foreach ($prop in $registryData.scripts.PSObject.Properties) {
            $folderPath = Join-Path $scriptsRoot $prop.Value
            $isFolderMissing = -not (Test-Path $folderPath)
            if ($isFolderMissing) {
                $missingFolders += "$($prop.Name):$($prop.Value)"
            }
        }
        $hasMissing = $missingFolders.Count -gt 0
        if ($hasMissing) {
            Write-Check "Registry folders exist" "fail" "Missing: $($missingFolders -join ', ')"
        } else {
            Write-Check "Registry folders exist" "pass" "All $registryCount folders present"
        }
    }

    # 5. Check .logs directory
    $logsDir = Join-Path $RootDir ".logs"
    $hasLogsDir = Test-Path $logsDir
    if ($hasLogsDir) {
        $logFiles = @(Get-ChildItem -Path $logsDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        Write-Check ".logs/ directory exists" "pass" "$($logFiles.Count) log file(s)"
    } else {
        Write-Check ".logs/ directory exists" "warn" "Will be created on first script run"
    }

    # 6. Check .installed directory
    $installedDir = Join-Path $RootDir ".installed"
    $hasInstalledDir = Test-Path $installedDir
    if ($hasInstalledDir) {
        $trackFiles = @(Get-ChildItem -Path $installedDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        Write-Check ".installed/ directory exists" "pass" "$($trackFiles.Count) tool(s) tracked"
    } else {
        Write-Check ".installed/ directory exists" "warn" "No tools tracked yet"
    }

    # 7. Check Chocolatey
    $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
    $hasChoco = $null -ne $chocoCmd
    if ($hasChoco) {
        $chocoVer = try { & choco --version 2>$null } catch { $null }
        Write-Check "Chocolatey is reachable" "pass" "v$chocoVer"
    } else {
        Write-Check "Chocolatey is reachable" "fail" "Not found in PATH"
    }

    # 8. Check admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Check "Running as Administrator" "pass"
    } else {
        Write-Check "Running as Administrator" "warn" "Some scripts require admin rights"
    }

    # 9. Check shared helpers are present
    $requiredHelpers = @("logging.ps1", "installed.ps1", "resolved.ps1", "help.ps1", "choco-utils.ps1", "path-utils.ps1", "dev-dir.ps1", "json-utils.ps1", "tool-version.ps1")
    $sharedDir = Join-Path $scriptsRoot "shared"
    $missingHelpers = @()
    foreach ($helper in $requiredHelpers) {
        $helperPath = Join-Path $sharedDir $helper
        $isHelperMissing = -not (Test-Path $helperPath)
        if ($isHelperMissing) {
            $missingHelpers += $helper
        }
    }
    $hasMissingHelpers = $missingHelpers.Count -gt 0
    if ($hasMissingHelpers) {
        Write-Check "Shared helpers present" "fail" "Missing: $($missingHelpers -join ', ')"
    } else {
        Write-Check "Shared helpers present" "pass" "$($requiredHelpers.Count) helpers found"
    }

    # 10. Check install-keywords.json
    $keywordsFile = Join-Path $sharedDir "install-keywords.json"
    $hasKeywords = Test-Path $keywordsFile
    if ($hasKeywords) {
        try {
            $kwData = Get-Content $keywordsFile -Raw | ConvertFrom-Json
            $kwCount = ($kwData.keywords.PSObject.Properties | Measure-Object).Count
            Write-Check "install-keywords.json is valid" "pass" "$kwCount keywords mapped"
        } catch {
            Write-Check "install-keywords.json is valid" "fail" "Parse error: $_"
        }
    } else {
        Write-Check "install-keywords.json is valid" "fail" "Not found"
    }

    # Summary
    Write-Host ""
    Write-Host "  Summary: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$passCount passed" -ForegroundColor Green -NoNewline
    $hasWarns = $warnCount -gt 0
    if ($hasWarns) {
        Write-Host ", $warnCount warning(s)" -ForegroundColor Yellow -NoNewline
    }
    $hasFails = $failCount -gt 0
    if ($hasFails) {
        Write-Host ", $failCount failed" -ForegroundColor Red -NoNewline
    }
    Write-Host ""

    if ($hasFails) {
        Write-Host ""
        Write-Host "  Some checks failed. Fix the issues above for a healthy setup." -ForegroundColor Red
    } elseif ($hasWarns) {
        Write-Host ""
        Write-Host "  Project looks good with minor warnings." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "  All checks passed. Project is healthy!" -ForegroundColor Green
    }
    Write-Host ""
}

# ── Doctor --self-check (deep audit, v0.46.1+) ──────────────────────
function Invoke-DoctorSelfCheck {
    <#
    .SYNOPSIS
        Deep self-audit of the project. Verifies internal consistency:
          (a) every claimed feature in changelog.md exists on disk
          (b) version.json matches the latest changelog header
          (c) every category in scripts/os/helpers/clean.ps1 catalog has a matching helper file
          (d) every keyword in install-keywords.json points to a real script ID / valid os:/profile: action
              / a remote.* entry whose URL responds 200 (or whose 'path' resolves to a real file)
          (e) every pinned remote.<key>.sha256 still matches the live upstream body
              -- full GET, hashed identically to run.ps1 (UTF-8 bytes of decoded string),
                 expected vs actual printed on mismatch. Empty pins skipped.
                 Path-based remotes are hashed from disk (not the network).
        Sections (d) and (e) require network access. Pass -SkipNetwork to skip both
        (e.g. on an air-gapped CI runner or when offline). Sections (a)-(c) always run.
        Prints a green/red table per row + per-section summaries + final tally.
    #>
    param([switch]$SkipNetwork)

    Write-Host ""
    Write-Host "  Doctor -- Self-Check (deep audit)" -ForegroundColor Cyan
    Write-Host "  =================================" -ForegroundColor DarkGray
    if ($SkipNetwork) {
        Write-Host "  [ INFO ] " -ForegroundColor Cyan -NoNewline
        Write-Host "--skip-network: sections (d) and (e) will be skipped (offline mode)"
    }
    Write-Host ""

    $script:scPass = 0
    $script:scFail = 0

    function Write-SCRow {
        param([string]$Section, [string]$Item, [bool]$Ok, [string]$Detail = "")
        if ($Ok) {
            Write-Host "    [ OK ] " -ForegroundColor Green -NoNewline
            $script:scPass++
        } else {
            Write-Host "    [FAIL] " -ForegroundColor Red -NoNewline
            $script:scFail++
        }
        $line = "{0,-10} {1,-40}" -f $Section, $Item
        Write-Host $line -NoNewline
        if ($Detail) { Write-Host " $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
    }

    function Write-SCHeader {
        param([string]$Title)
        Write-Host ""
        Write-Host "  -- $Title" -ForegroundColor Yellow
    }

    $scriptsRoot = Join-Path $RootDir "scripts"
    $sharedDir   = Join-Path $scriptsRoot "shared"

    # ============================================================
    # (a) Claimed features in changelog.md exist on disk
    # ============================================================
    Write-SCHeader "(a) Claimed files in changelog.md exist on disk"
    $changelogPath = Join-Path $RootDir "changelog.md"
    $hasChangelog = Test-Path $changelogPath
    if (-not $hasChangelog) {
        Write-SCRow "changelog" "changelog.md" $false "Missing at: $changelogPath"
    } else {
        $clText = Get-Content $changelogPath -Raw
        # Extract backticked paths that look like real files (contain / or \ and an extension OR end in .ps1/.json/.md)
        $regex = [regex]'`([A-Za-z0-9_./\\-]+\.(ps1|json|md|psm1|psd1))`'
        $matches = $regex.Matches($clText)
        $uniquePaths = @{}
        foreach ($m in $matches) {
            $p = $m.Groups[1].Value
            # Skip obvious externals (URL fragments, backslash-only Windows paths starting with %)
            if ($p.StartsWith("%") -or $p.StartsWith("~") -or $p.StartsWith("http")) { continue }
            $uniquePaths[$p] = $true
        }
        $checked = 0
        foreach ($rel in ($uniquePaths.Keys | Sort-Object)) {
            $checked++
            $abs = Join-Path $RootDir ($rel -replace '/', '\')
            $exists = Test-Path -LiteralPath $abs
            $detail = if ($exists) { "" } else { "Expected: $abs" }
            Write-SCRow "changelog" $rel $exists $detail
        }
        if ($checked -eq 0) {
            Write-SCRow "changelog" "(no `path.ext` references found)" $true ""
        }
    }

    # ============================================================
    # (b) version.json matches latest changelog header
    # ============================================================
    Write-SCHeader "(b) version.json matches latest changelog header"
    $versionFile = Join-Path $scriptsRoot "version.json"
    $hasVF = Test-Path $versionFile
    $hasCL = Test-Path $changelogPath
    if (-not $hasVF) {
        Write-SCRow "version" "scripts/version.json" $false "Missing at: $versionFile"
    } elseif (-not $hasCL) {
        Write-SCRow "version" "changelog.md" $false "Missing at: $changelogPath"
    } else {
        try {
            $vData = Get-Content $versionFile -Raw | ConvertFrom-Json
            $vJson = $vData.version
        } catch {
            $vJson = $null
            Write-SCRow "version" "version.json parse" $false "Parse error: $_  (path: $versionFile)"
        }
        if ($vJson) {
            $clRaw = Get-Content $changelogPath -Raw
            $headerMatch = [regex]::Match($clRaw, '(?m)^##\s*\[?v?(\d+\.\d+\.\d+)\]?')
            if (-not $headerMatch.Success) {
                Write-SCRow "version" "latest changelog header" $false "No '## [vX.Y.Z]' header found in $changelogPath"
            } else {
                $vCL = $headerMatch.Groups[1].Value
                $matches = ($vJson -eq $vCL)
                $detail = "version.json=v$vJson  changelog=v$vCL"
                Write-SCRow "version" "monotonic match" $matches $detail
            }
        }
    }

    # ============================================================
    # (c) Every os clean catalog category has a matching helper file
    # ============================================================
    Write-SCHeader "(c) os clean-categories: catalog vs helper files"
    $cleanDispatcher = Join-Path $scriptsRoot "os\helpers\clean.ps1"
    $catDir          = Join-Path $scriptsRoot "os\helpers\clean-categories"
    $hasCD = Test-Path $cleanDispatcher
    $hasCatDir = Test-Path $catDir
    if (-not $hasCD) {
        Write-SCRow "clean" "clean.ps1 dispatcher" $false "Missing at: $cleanDispatcher"
    } elseif (-not $hasCatDir) {
        Write-SCRow "clean" "clean-categories/ dir" $false "Missing at: $catDir"
    } else {
        # Parse @{ Cat = "name"; Bucket = "X"; Helper = "name.ps1" } lines
        $cdText = Get-Content $cleanDispatcher -Raw
        $catRegex = [regex]'@\{\s*Cat\s*=\s*"([^"]+)"\s*;\s*Bucket\s*=\s*"([^"]+)"\s*;\s*Helper\s*=\s*"([^"]+)"\s*\}'
        $catMatches = $catRegex.Matches($cdText)
        if ($catMatches.Count -eq 0) {
            Write-SCRow "clean" "catalog parse" $false "No catalog entries matched in: $cleanDispatcher"
        } else {
            foreach ($m in $catMatches) {
                $cat    = $m.Groups[1].Value
                $bucket = $m.Groups[2].Value
                $helper = $m.Groups[3].Value
                $helperPath = Join-Path $catDir $helper
                $exists = Test-Path -LiteralPath $helperPath
                $detail = if ($exists) { "[$bucket] $helper" } else { "[$bucket] MISSING: $helperPath" }
                Write-SCRow "clean" $cat $exists $detail
            }
        }
    }

    # ============================================================
    # (d) install-keywords.json: every keyword resolves
    # ============================================================
    Write-SCHeader "(d) install-keywords.json: keyword resolution"
    if ($SkipNetwork) {
        Write-SCRow "keywords" "(skipped -- --skip-network)" $true "Section (d) requires HEAD probes to remote URLs; skipped per flag."
    } else {
    $kwFile = Join-Path $sharedDir "install-keywords.json"
    $regFile = Join-Path $scriptsRoot "registry.json"
    if (-not (Test-Path $kwFile)) {
        Write-SCRow "keywords" "install-keywords.json" $false "Missing at: $kwFile"
    } elseif (-not (Test-Path $regFile)) {
        Write-SCRow "keywords" "registry.json" $false "Missing at: $regFile"
    } else {
        try {
            $kwData  = Get-Content $kwFile  -Raw | ConvertFrom-Json
            $regData = Get-Content $regFile -Raw | ConvertFrom-Json
        } catch {
            Write-SCRow "keywords" "json parse" $false "Parse error: $_"
            $kwData = $null
        }
        if ($null -ne $kwData) {
            # Build registry ID set
            $validIds = @{}
            foreach ($prop in $regData.scripts.PSObject.Properties) {
                $validIds[$prop.Name] = $true
            }

            # Probe remote URLs ONCE and cache. Path-based remotes (v0.47.1+)
            # skip HTTP probing and instead validate the local file exists.
            $remoteCache = @{}
            if ($null -ne $kwData.remote) {
                foreach ($rprop in $kwData.remote.PSObject.Properties) {
                    $rkey = $rprop.Name
                    $rval = $rprop.Value
                    $hasRPath = $rval.PSObject.Properties['path'] -and -not [string]::IsNullOrWhiteSpace("$($rval.path)")
                    $hasRUrl  = $rval.PSObject.Properties['url']  -and -not [string]::IsNullOrWhiteSpace("$($rval.url)")
                    if ($hasRPath) {
                        $relPath = "$($rval.path)".Trim()
                        $absPath = Join-Path $RootDir $relPath
                        $existsLocal = Test-Path -LiteralPath $absPath
                        $remoteCache[$rkey] = @{
                            Url   = "file:///$($absPath -replace '\\','/')"
                            Code  = if ($existsLocal) { 200 } else { 404 }
                            Ok    = $existsLocal
                            Kind  = "path"
                            Path  = $absPath
                        }
                    } elseif ($hasRUrl) {
                        $rurl = "$($rval.url)".Trim()
                        $code = -1
                        try {
                            $resp = Invoke-WebRequest -Uri $rurl -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                            $code = [int]$resp.StatusCode
                        } catch {
                            if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                                $code = [int]$_.Exception.Response.StatusCode
                            }
                        }
                        $remoteCache[$rkey] = @{ Url = $rurl; Code = $code; Ok = ($code -eq 200); Kind = "url" }
                    } else {
                        $remoteCache[$rkey] = @{ Url = "(none)"; Code = 0; Ok = $false; Kind = "missing" }
                    }
                }
            }

            # Walk every keyword
            foreach ($kprop in $kwData.keywords.PSObject.Properties) {
                $kw = $kprop.Name
                $targets = $kprop.Value
                $allOk = $true
                $details = New-Object System.Collections.ArrayList

                foreach ($t in $targets) {
                    $tStr = "$t"
                    # Three resolution kinds: remote:<key>, os:<action>, profile:<name>, or numeric script ID
                    if ($tStr -match '^remote:(.+)$') {
                        $rk = $Matches[1]
                        if (-not $remoteCache.ContainsKey($rk)) {
                            $allOk = $false
                            [void]$details.Add("remote:$rk -> NOT in remote.* (path: $kwFile)")
                        } else {
                            $rc = $remoteCache[$rk]
                            if (-not $rc.Ok) {
                                $allOk = $false
                                if ($rc.Kind -eq "path") {
                                    [void]$details.Add("remote:$rk -> local file MISSING: $($rc.Path)")
                                } elseif ($rc.Kind -eq "missing") {
                                    [void]$details.Add("remote:$rk -> entry has neither 'url' nor 'path'")
                                } else {
                                    [void]$details.Add("remote:$rk -> HTTP $($rc.Code) for $($rc.Url)")
                                }
                            } else {
                                if ($rc.Kind -eq "path") {
                                    [void]$details.Add("remote:$rk local-OK")
                                } else {
                                    [void]$details.Add("remote:$rk 200")
                                }
                            }
                        }
                    } elseif ($tStr -match '^os:(.+)$') {
                        # Accept any os:<action> as valid (os dispatcher resolves at runtime)
                        [void]$details.Add("os:$($Matches[1])")
                    } elseif ($tStr -match '^profile:(.+)$') {
                        [void]$details.Add("profile:$($Matches[1])")
                    } elseif ($tStr -match '^\d+$') {
                        if (-not $validIds.ContainsKey($tStr)) {
                            $allOk = $false
                            [void]$details.Add("id $tStr -> NOT in registry.json")
                        } else {
                            [void]$details.Add("id $tStr")
                        }
                    } else {
                        $allOk = $false
                        [void]$details.Add("unknown target form: '$tStr'")
                    }
                }

                Write-SCRow "keyword" $kw $allOk ($details -join ", ")
            }
        }
    }
    } # end if (-not $SkipNetwork) for section (d)

    # ============================================================
    # (e) install-keywords.json: pinned remote.<key>.sha256 still matches live body
    # ============================================================
    Write-SCHeader "(e) remote SHA256 pins still match upstream body"
    if ($SkipNetwork) {
        Write-SCRow "sha256" "(skipped -- --skip-network)" $true "Section (e) requires full GET of every remote URL; skipped per flag."
    } else {
        $kwFileE = Join-Path $sharedDir "install-keywords.json"
        if (-not (Test-Path $kwFileE)) {
            Write-SCRow "sha256" "install-keywords.json" $false "Missing at: $kwFileE"
        } else {
            try {
                $kwDataE = Get-Content $kwFileE -Raw | ConvertFrom-Json
            } catch {
                Write-SCRow "sha256" "json parse" $false "Parse error at ${kwFileE}: $($_.Exception.Message)"
                $kwDataE = $null
            }
            if ($null -ne $kwDataE -and $null -ne $kwDataE.remote) {
                $remoteCount = 0
                foreach ($rprop in $kwDataE.remote.PSObject.Properties) {
                    $rkey = $rprop.Name
                    $rval = $rprop.Value
                    $remoteCount++

                    # Pull pinned sha256 (skip if absent or empty)
                    $pinned = $null
                    if ($rval.PSObject.Properties['sha256']) {
                        $rawPin = "$($rval.sha256)".Trim()
                        if (-not [string]::IsNullOrWhiteSpace($rawPin)) { $pinned = $rawPin.ToLowerInvariant() }
                    }
                    if ($null -eq $pinned) {
                        Write-SCRow "sha256" "remote:$rkey" $true "(unpinned -- skipped, no sha256 to verify)"
                        continue
                    }

                    # Resolve source: 'path' (repo-local) or 'url' (HTTP)
                    $hasRPath = $rval.PSObject.Properties['path'] -and -not [string]::IsNullOrWhiteSpace("$($rval.path)")
                    $hasRUrl  = $rval.PSObject.Properties['url']  -and -not [string]::IsNullOrWhiteSpace("$($rval.url)")
                    $body = $null
                    $sourceLabel = $null
                    $fetchError = $null

                    if ($hasRPath) {
                        $relPath = "$($rval.path)".Trim()
                        $absPath = Join-Path $RootDir $relPath
                        $sourceLabel = "local: $absPath"
                        if (-not (Test-Path -LiteralPath $absPath)) {
                            $fetchError = "Local wrapper not found: $absPath  (referenced by remote.$rkey.path in $kwFileE)"
                        } else {
                            try {
                                $body = Get-Content -LiteralPath $absPath -Raw -ErrorAction Stop
                            } catch {
                                $fetchError = "Read failed for $absPath -- $($_.Exception.Message)"
                            }
                        }
                    } elseif ($hasRUrl) {
                        $rurl = "$($rval.url)".Trim()
                        $sourceLabel = $rurl
                        try {
                            # Mirror run.ps1 dispatcher: Invoke-RestMethod returns the decoded string body.
                            $body = Invoke-RestMethod -Uri $rurl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                        } catch {
                            $code = ""
                            if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                                $code = " (HTTP $([int]$_.Exception.Response.StatusCode))"
                            }
                            $fetchError = "GET failed for ${rurl}${code} -- $($_.Exception.Message)"
                        }
                    } else {
                        Write-SCRow "sha256" "remote:$rkey" $false "Entry has neither 'url' nor 'path' (path: $kwFileE)"
                        continue
                    }

                    if ($null -ne $fetchError) {
                        Write-SCRow "sha256" "remote:$rkey" $false $fetchError
                        continue
                    }
                    if ([string]::IsNullOrWhiteSpace($body)) {
                        Write-SCRow "sha256" "remote:$rkey" $false "Empty body from $sourceLabel  (pin source: remote.$rkey.sha256 in $kwFileE)"
                        continue
                    }

                    # Compute SHA256 IDENTICALLY to run.ps1 dispatcher: UTF-8 bytes of the decoded string.
                    try {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$body")
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        $hashBytes = $sha.ComputeHash($bytes)
                        $sha.Dispose()
                        $actual = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
                    } catch {
                        Write-SCRow "sha256" "remote:$rkey" $false "SHA256 computation failed for $sourceLabel -- $($_.Exception.Message)"
                        continue
                    }

                    $isMatch = $actual -eq $pinned
                    if ($isMatch) {
                        Write-SCRow "sha256" "remote:$rkey" $true "pinned=$pinned  source=$sourceLabel  ($([Math]::Round(([System.Text.Encoding]::UTF8.GetBytes($body)).Length / 1KB, 2)) KB)"
                    } else {
                        $detail = "MISMATCH  expected=$pinned  actual=$actual  source=$sourceLabel  pin=remote.$rkey.sha256 in $kwFileE"
                        Write-SCRow "sha256" "remote:$rkey" $false $detail
                    }
                }
                if ($remoteCount -eq 0) {
                    Write-SCRow "sha256" "remote.* entries" $true "(no entries to check -- remote.* is empty)"
                }
            } elseif ($null -ne $kwDataE) {
                Write-SCRow "sha256" "remote.* section" $true "(no remote.* section in $kwFileE -- nothing to verify)"
            }
        }
    }

    # ============================================================
    # Summary
    # ============================================================
    $total = $script:scPass + $script:scFail
    Write-Host ""
    Write-Host "  Self-Check Summary: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($script:scPass)/$total OK" -ForegroundColor Green -NoNewline
    if ($script:scFail -gt 0) {
        Write-Host ", $($script:scFail) FAIL" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Self-check found inconsistencies. Fix the rows marked [FAIL] above." -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host ""
        Write-Host "  All self-check rows green. Project is internally consistent." -ForegroundColor Green
    }
    Write-Host ""
}

function Invoke-PathCommand {
    param([string[]]$Args)

    # Load dev-dir helper
    $devDirHelper = Join-Path $RootDir "scripts\shared\dev-dir.ps1"
    $isHelperMissing = -not (Test-Path $devDirHelper)
    if ($isHelperMissing) {
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Shared helper not found: $devDirHelper"
        return
    }
    . $devDirHelper

    $firstArg = if ($Args -and $Args.Count -gt 0) { $Args[0].Trim() } else { "" }
    $isReset = $firstArg -eq "--reset" -or $firstArg -eq "reset"
    $isShowOnly = [string]::IsNullOrWhiteSpace($firstArg)

    if ($isReset) {
        Remove-SavedDevPath
        Write-Host ""
        Write-Host "  [  OK  ] " -ForegroundColor Green -NoNewline
        Write-Host "Saved dev directory cleared. Smart detection will be used."
        Write-Host ""
        return
    }

    if ($isShowOnly) {
        $savedPath = Get-SavedDevPath
        $hasSavedPath = $null -ne $savedPath
        Write-Host ""
        if ($hasSavedPath) {
            Write-Host "  Current dev directory: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$savedPath" -ForegroundColor White
        } else {
            Write-Host "  No saved dev directory. Using smart detection (E:\dev-tool > D:\dev-tool > best drive)." -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Usage:" -ForegroundColor Yellow
        Write-Host "    .\run.ps1 path D:\devtools          " -NoNewline; Write-Host "Set default dev directory" -ForegroundColor DarkGray
        Write-Host "    .\run.ps1 path                      " -NoNewline; Write-Host "Show current dev directory" -ForegroundColor DarkGray
        Write-Host "    .\run.ps1 path --reset              " -NoNewline; Write-Host "Clear saved path, use smart detection" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    # Validate the path
    $targetPath = $firstArg
    $isValidFormat = $targetPath -match '^[A-Za-z]:\\'
    if (-not $isValidFormat) {
        Write-Host ""
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Invalid path format. Use a full path like D:\devtools or F:\dev-tool"
        Write-Host ""
        return
    }

    Set-SavedDevPath -Path $targetPath
    Write-Host ""
    Write-Host "  [  OK  ] " -ForegroundColor Green -NoNewline
    Write-Host "Default dev directory set to: $targetPath"
    Write-Host ""
    Write-Host "  All scripts will now use this path. Use '.\run.ps1 path --reset' to revert to smart detection." -ForegroundColor DarkGray
    Write-Host ""
}

# ── Normalize positional command mode ────────────────────────────────
# Supports:  .\run.ps1 install alldev,mysql
#             .\run.ps1 install alldev mysql
#             .\run.ps1 -Install alldev,mysql
#             .\run.ps1 update
#             .\run.ps1 path D:\devtools
$normalizedCommand = ""
$hasCommand = -not [string]::IsNullOrWhiteSpace($Command)
if ($hasCommand) {
    $normalizedCommand = $Command.Trim().ToLower()

    # ── --version / version / -V short-circuit ────────────────────────
    # Print version + git SHA + readme link, then exit. No git pull, no dispatch.
    # Note: -v is reserved for VS Code (script 01); we match capital -V via $MyInvocation.Line.
    $isVersionCommand = $normalizedCommand -in @("--version", "-version", "version")
    $isCapitalVFlag   = $MyInvocation.Line -cmatch '(^|\s)-V(\s|$)'
    if ($isVersionCommand -or $isCapitalVFlag) {
        $ver = Get-ScriptVersion
        $shortSha = "unknown"
        $longSha  = "unknown"
        $branch   = "unknown"
        $isDirty  = $false
        try {
            Push-Location $RootDir
            $shortSha = (& git rev-parse --short HEAD 2>$null) -join ""
            $longSha  = (& git rev-parse HEAD 2>$null) -join ""
            $branch   = (& git rev-parse --abbrev-ref HEAD 2>$null) -join ""
            $porcelain = & git status --porcelain 2>$null
            $isDirty   = -not [string]::IsNullOrWhiteSpace(($porcelain -join ""))
            Pop-Location
        } catch {
            try { Pop-Location -ErrorAction SilentlyContinue } catch {}
        }
        $hasShort = -not [string]::IsNullOrWhiteSpace($shortSha)
        if (-not $hasShort) { $shortSha = "no-git" }
        $dirtyTag = if ($isDirty) { " (dirty)" } else { "" }

        Write-Host ""
        Write-Host "  scripts-fixer v$ver" -ForegroundColor Magenta
        Write-Host "  ===============================================" -ForegroundColor DarkGray
        Write-Host ("  Commit  : {0}{1}" -f $shortSha, $dirtyTag) -ForegroundColor Cyan
        Write-Host ("  Full SHA: {0}" -f $longSha)               -ForegroundColor DarkGray
        Write-Host ("  Branch  : {0}" -f $branch)                -ForegroundColor Cyan
        Write-Host ("  Root    : {0}" -f $RootDir)               -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Readme  : https://github.com/alimtvnetwork/gitmap-v6/blob/main/readme.md" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Disclaimer: This project is provided AS IS, no warranty." -ForegroundColor DarkYellow
        Write-Host "  Made for fun to save time on OS setup. You are responsible" -ForegroundColor DarkYellow
        Write-Host "  for anything it changes on your machine." -ForegroundColor DarkYellow
        Write-Host ""
        exit 0
    }


    # ── logs subcommand short-circuit ─────────────────────────────────
    # .\run.ps1 logs [--tail N] [--grep <pattern>] [--since <duration>] [--errors] [--case-sensitive]
    # Prints events from .logs/*.json grouped by invokedFrom, with projectVersion.
    # Exits before any git pull / dispatch -- safe in restricted shells.
    $isLogsCommand = $normalizedCommand -eq "logs"
    if ($isLogsCommand) {
        $logsArgs = @($Install)
        $tailN = 20
        $isTailRequested = $false
        $grepPattern = $null
        $isCaseSensitive = $false
        $sinceCutoff = $null
        $sinceLabel  = $null
        $isErrorsOnly = $false

        function Convert-DurationToSpan {
            param([string]$Raw)
            if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
            $r = $Raw.Trim().ToLower()
            if ($r -match '^(\d+)\s*(s|sec|secs|second|seconds)$')          { return [TimeSpan]::FromSeconds([int]$Matches[1]) }
            if ($r -match '^(\d+)\s*(m|min|mins|minute|minutes)$')          { return [TimeSpan]::FromMinutes([int]$Matches[1]) }
            if ($r -match '^(\d+)\s*(h|hr|hrs|hour|hours)$')                { return [TimeSpan]::FromHours([int]$Matches[1]) }
            if ($r -match '^(\d+)\s*(d|day|days)$')                         { return [TimeSpan]::FromDays([int]$Matches[1]) }
            if ($r -match '^(\d+)\s*(w|wk|wks|week|weeks)$')                { return [TimeSpan]::FromDays([int]$Matches[1] * 7) }
            return $null
        }

        for ($i = 0; $i -lt $logsArgs.Count; $i++) {
            $a = "$($logsArgs[$i])".Trim()
            $aLower = $a.ToLower()

            $isTailFlag = $aLower -in @("--tail", "-tail", "tail")
            if ($isTailFlag) {
                $isTailRequested = $true
                $hasInlineN = ($i + 1) -lt $logsArgs.Count
                if ($hasInlineN) {
                    $parsed = 0
                    if ([int]::TryParse("$($logsArgs[$i + 1])", [ref]$parsed) -and $parsed -gt 0) {
                        $tailN = $parsed
                    }
                }
                continue
            }

            if ($aLower -match '^--tail=(\d+)$') {
                $isTailRequested = $true
                $tailN = [int]$Matches[1]
                continue
            }

            $isGrepFlag = $aLower -in @("--grep", "-grep", "grep")
            if ($isGrepFlag -and ($i + 1) -lt $logsArgs.Count) {
                $grepPattern = "$($logsArgs[$i + 1])"
                continue
            }
            if ($a -match '^--grep=(.+)$') {
                $grepPattern = $Matches[1]
                continue
            }

            $isSinceFlag = $aLower -in @("--since", "-since", "since")
            if ($isSinceFlag -and ($i + 1) -lt $logsArgs.Count) {
                $sinceLabel = "$($logsArgs[$i + 1])"
                continue
            }
            if ($a -match '^--since=(.+)$') {
                $sinceLabel = $Matches[1]
                continue
            }

            if ($aLower -in @("--errors", "-errors", "errors", "--errors-only")) { $isErrorsOnly = $true; continue }
            if ($aLower -in @("--case-sensitive", "-case-sensitive", "--case", "-case")) { $isCaseSensitive = $true; continue }

            $isHelp = $aLower -in @("--help", "-h", "help")
            if ($isHelp) {
                Write-Host ""
                Write-Host "  Usage: .\run.ps1 logs [--tail N] [--grep <pattern>] [--since <duration>] [--errors] [--case-sensitive]" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Flags:" -ForegroundColor Yellow
                Write-Host "    --tail N            Last N events (default 20)" -ForegroundColor DarkGray
                Write-Host "    --grep <pattern>    Filter events whose .message matches regex (case-insensitive by default)" -ForegroundColor DarkGray
                Write-Host "    --since <duration>  Only events newer than the window. Examples: 30m, 1h, 2d, 1w" -ForegroundColor DarkGray
                Write-Host "    --errors            Only level=fail and level=warn (also reads .logs/*-error.json)" -ForegroundColor DarkGray
                Write-Host "    --case-sensitive    Make --grep case-sensitive" -ForegroundColor DarkGray
                Write-Host "    --help              Show this help and exit" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  All filters compose. Output is grouped by invokedFrom and color-coded by level." -ForegroundColor DarkGray
                Write-Host ""
                exit 0
            }
        }

        # Resolve --since cutoff
        if ($null -ne $sinceLabel) {
            $span = Convert-DurationToSpan -Raw $sinceLabel
            $isSpanInvalid = $null -eq $span
            if ($isSpanInvalid) {
                Write-Host ""
                Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
                Write-Host "--since '$sinceLabel' is not a recognised duration. Use formats like 30m, 1h, 2d, 1w."
                exit 1
            }
            $sinceCutoff = (Get-Date).Subtract($span)
        }

        # Validate --grep regex up front (so we fail fast, not per-event)
        $grepRegex = $null
        if ($null -ne $grepPattern) {
            try {
                $opts = if ($isCaseSensitive) { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
                $grepRegex = New-Object System.Text.RegularExpressions.Regex($grepPattern, $opts)
            } catch {
                Write-Host ""
                Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
                Write-Host "--grep '$grepPattern' is not a valid regex: $($_.Exception.Message)"
                exit 1
            }
        }

        $logsDir = Join-Path $RootDir ".logs"
        $isLogsDirMissing = -not (Test-Path -LiteralPath $logsDir)
        if ($isLogsDirMissing) {
            Write-Host ""
            Write-Host "  [ INFO ] " -ForegroundColor Cyan -NoNewline
            Write-Host "No .logs/ directory found at: $logsDir"
            Write-Host "  Run any script first to generate logs." -ForegroundColor DarkGray
            Write-Host ""
            exit 0
        }

        # Collect events. Default: skip *-error.json (duplicates).
        # When --errors is on: ALSO read *-error.json so dedicated error logs are surfaced.
        $allEvents = New-Object System.Collections.ArrayList
        $logFiles = Get-ChildItem -LiteralPath $logsDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                    Where-Object { $isErrorsOnly -or ($_.Name -notlike "*-error.json") }
        $hasNoLogFiles = $logFiles.Count -eq 0
        if ($hasNoLogFiles) {
            Write-Host ""
            Write-Host "  [ INFO ] " -ForegroundColor Cyan -NoNewline
            Write-Host "No .logs/*.json files found in: $logsDir"
            Write-Host ""
            exit 0
        }

        foreach ($lf in $logFiles) {
            try {
                $payload = Get-Content -LiteralPath $lf.FullName -Raw | ConvertFrom-Json
            } catch {
                Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
                Write-Host "Could not parse log file: $($lf.FullName) -- Reason: $($_.Exception.Message)"
                continue
            }
            $fileVer    = if ($payload.PSObject.Properties['projectVersion']) { "$($payload.projectVersion)" } else { "unknown" }
            $fileInvoke = if ($payload.PSObject.Properties['invokedFrom'])    { "$($payload.invokedFrom)"    } else { "unknown" }
            $fileScript = if ($payload.PSObject.Properties['scriptName'])     { "$($payload.scriptName)"     } else { ($lf.BaseName) }

            # Pull from events[], errors[], warnings[] -- whichever the file has.
            $sources = @()
            if ($payload.PSObject.Properties['events']   -and $payload.events)   { $sources += ,@($payload.events) }
            if ($payload.PSObject.Properties['errors']   -and $payload.errors)   { $sources += ,@($payload.errors) }
            if ($payload.PSObject.Properties['warnings'] -and $payload.warnings) { $sources += ,@($payload.warnings) }

            foreach ($arr in $sources) {
                foreach ($ev in $arr) {
                    $ts = if ($ev.PSObject.Properties['timestamp']) { "$($ev.timestamp)" } else { "" }
                    $lv = if ($ev.PSObject.Properties['level'])     { "$($ev.level)"     } else { "info" }
                    $ms = if ($ev.PSObject.Properties['message'])   { "$($ev.message)"   } else { "" }
                    $pv = if ($ev.PSObject.Properties['projectVersion']) { "$($ev.projectVersion)" } else { $fileVer }
                    $iv = if ($ev.PSObject.Properties['invokedFrom'])    { "$($ev.invokedFrom)"    } else { $fileInvoke }
                    $sn = if ($ev.PSObject.Properties['scriptName'])     { "$($ev.scriptName)"     } else { $fileScript }
                    $sortKey = $lf.LastWriteTime
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($ts, [ref]$parsedDate)) { $sortKey = $parsedDate }

                    # ---- filter: --errors ---------------------------------------------
                    if ($isErrorsOnly) {
                        $isErrorLevel = $lv -in @("fail", "warn", "error")
                        if (-not $isErrorLevel) { continue }
                    }

                    # ---- filter: --since ----------------------------------------------
                    if ($null -ne $sinceCutoff) {
                        $isStale = $sortKey -lt $sinceCutoff
                        if ($isStale) { continue }
                    }

                    # ---- filter: --grep -----------------------------------------------
                    if ($null -ne $grepRegex) {
                        $isMatch = $grepRegex.IsMatch($ms)
                        if (-not $isMatch) { continue }
                    }

                    $allEvents.Add([pscustomobject]@{
                        SortKey        = $sortKey
                        Timestamp      = $ts
                        Level          = $lv
                        Message        = $ms
                        ProjectVersion = $pv
                        InvokedFrom    = $iv
                        ScriptName     = $sn
                        SourceFile     = $lf.Name
                    }) | Out-Null
                }
            }
        }

        $totalEvents = $allEvents.Count
        if ($totalEvents -eq 0) {
            Write-Host ""
            Write-Host "  [ INFO ] " -ForegroundColor Cyan -NoNewline
            $reason = "Found $($logFiles.Count) log file(s) but zero events match the active filters."
            Write-Host $reason
            $appliedFilters = @()
            if ($isErrorsOnly)        { $appliedFilters += "--errors" }
            if ($null -ne $grepRegex) { $appliedFilters += "--grep '$grepPattern'" }
            if ($null -ne $sinceCutoff) { $appliedFilters += "--since $sinceLabel" }
            if ($appliedFilters.Count -gt 0) {
                Write-Host "  Active filters: $($appliedFilters -join ', ')" -ForegroundColor DarkGray
            }
            Write-Host ""
            exit 0
        }

        $tail = $allEvents | Sort-Object SortKey | Select-Object -Last $tailN
        $groups = $tail | Group-Object InvokedFrom | Sort-Object { ($_.Group | Measure-Object SortKey -Maximum).Maximum }

        $headerParts = @()
        if ($isTailRequested) { $headerParts += "--tail $tailN" } else { $headerParts += "(default tail $tailN)" }
        if ($isErrorsOnly)        { $headerParts += "--errors" }
        if ($null -ne $grepRegex) { $headerParts += "--grep '$grepPattern'$(if ($isCaseSensitive) {' (case-sensitive)'} else {''})" }
        if ($null -ne $sinceCutoff) { $headerParts += "--since $sinceLabel" }
        $headerLabel = "logs " + ($headerParts -join " ")

        Write-Host ""
        Write-Host "  $headerLabel  --  showing $($tail.Count) of $totalEvents event(s) across $($logFiles.Count) file(s)" -ForegroundColor Magenta
        Write-Host "  ===============================================================" -ForegroundColor DarkGray

        $levelColors = @{ ok = "Green"; fail = "Red"; warn = "Yellow"; error = "Red"; skip = "DarkGray"; info = "Cyan" }
        foreach ($g in $groups) {
            $groupVersions = $g.Group | Select-Object -ExpandProperty ProjectVersion -Unique
            $primaryVersion = ($g.Group | Sort-Object SortKey | Select-Object -Last 1).ProjectVersion
            $versionLabel = if ($groupVersions.Count -gt 1) {
                "v$primaryVersion (mixed: $($groupVersions -join ', '))"
            } else {
                "v$primaryVersion"
            }
            Write-Host ""
            Write-Host "  invokedFrom: $($g.Name)  [$versionLabel]  --  $($g.Group.Count) event(s)" -ForegroundColor Yellow
            $sorted = $g.Group | Sort-Object SortKey
            foreach ($e in $sorted) {
                $color = if ($levelColors.ContainsKey($e.Level)) { $levelColors[$e.Level] } else { "Gray" }
                $shortTs = $e.Timestamp
                if ($shortTs.Length -ge 19) { $shortTs = $shortTs.Substring(0, 19) }
                $line = "    {0}  [{1,-5}]  {2}" -f $shortTs, $e.Level, $e.Message
                Write-Host $line -ForegroundColor $color
            }
        }

        Write-Host ""
        Write-Host "  Source files scanned:" -ForegroundColor DarkGray
        foreach ($lf in ($logFiles | Sort-Object Name)) {
            Write-Host "    - $($lf.Name)" -ForegroundColor DarkGray
        }
        Write-Host ""
        exit 0
    }

    $isBareInstallCommand = $normalizedCommand -eq "install"
    $isBareUpdateCommand  = $normalizedCommand -eq "update" -or $normalizedCommand -eq "choco-update" -or $normalizedCommand -eq "upgrade"
    $isBarePathCommand    = $normalizedCommand -eq "path"
    $isBareScanCommand    = $normalizedCommand -eq "scan"
    $isBareExportCommand  = $normalizedCommand -eq "export"
    $isBareStatusCommand  = $normalizedCommand -eq "status"
    $isBareDoctorCommand  = $normalizedCommand -eq "doctor"
    $isBareModelsCommand  = $normalizedCommand -eq "models" -or $normalizedCommand -eq "model"
    $isBareOsCommand      = $normalizedCommand -eq "os"
    $isBareVscodeFolderCommand = $normalizedCommand -in @("vscode-folder", "vscode-folder-repair", "vscodefolder", "vscodefolderrepair")
    $isBareProfileCommand = $normalizedCommand -eq "profile" -or $normalizedCommand -eq "profiles"
    $isBareGitToolsCommand = $normalizedCommand -eq "git-tools" -or $normalizedCommand -eq "gittools"
    $isBareGsaCommand     = $normalizedCommand -eq "gsa" -or $normalizedCommand -eq "git-safe-all" -or $normalizedCommand -eq "gitsafeall"
    $isBareScriptId = $normalizedCommand -match '^\d+$'

    if ($isBareOsCommand) {
        Show-VersionHeader
        $osScript = Join-Path $RootDir "scripts\os\run.ps1"
        $isOsScriptPresent = Test-Path $osScript
        if (-not $isOsScriptPresent) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "OS dispatcher missing at: $osScript"
            exit 1
        }
        & $osScript @Install
        exit $LASTEXITCODE
    }

    if ($isBareVscodeFolderCommand) {
        Show-VersionHeader
        $vscodeFolderScript = Join-Path $RootDir "scripts\52-vscode-folder-repair\run.ps1"
        $isVscodeFolderScriptPresent = Test-Path $vscodeFolderScript
        if (-not $isVscodeFolderScriptPresent) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "VS Code folder repair dispatcher missing at: $vscodeFolderScript"
            exit 1
        }
        & $vscodeFolderScript @Install
        exit $LASTEXITCODE
    }

    if ($isBareProfileCommand) {
        Show-VersionHeader
        $profileScript = Join-Path $RootDir "scripts\profile\run.ps1"
        $isProfileScriptPresent = Test-Path $profileScript
        if (-not $isProfileScriptPresent) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "Profile dispatcher missing at: $profileScript"
            exit 1
        }
        & $profileScript @Install
        exit $LASTEXITCODE
    }

    if ($isBareGitToolsCommand) {
        Show-VersionHeader
        $gitToolsScript = Join-Path $RootDir "scripts\git-tools\run.ps1"
        $isGitToolsScriptPresent = Test-Path $gitToolsScript
        if (-not $isGitToolsScriptPresent) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "Git-tools dispatcher missing at: $gitToolsScript"
            exit 1
        }
        & $gitToolsScript @Install
        exit $LASTEXITCODE
    }

    if ($isBareGsaCommand) {
        # Shortcut: route directly to safe-all action.
        Show-VersionHeader
        $gitToolsScript = Join-Path $RootDir "scripts\git-tools\run.ps1"
        $isGitToolsScriptPresent = Test-Path $gitToolsScript
        if (-not $isGitToolsScriptPresent) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "Git-tools dispatcher missing at: $gitToolsScript"
            exit 1
        }
        & $gitToolsScript "safe-all" @Install
        exit $LASTEXITCODE
    }


    if ($isBareInstallCommand) {
        # Merge positional remaining args into $Install
        $hasRemainingArgs = $null -ne $Install -and $Install.Count -gt 0
        $isNoRemainingArgs = -not $hasRemainingArgs
        if ($isNoRemainingArgs) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "No keywords provided after 'install'. Usage: .\run.ps1 install <keywords>"
            Write-Host ""
            Write-Host "  Run .\run.ps1 -Help to see all available keywords" -ForegroundColor Cyan
            exit 1
        }
    } elseif ($isBareExportCommand) {
        Show-VersionHeader
        Invoke-ExportCommand -Args $Install
        exit 0
    } elseif ($isBareStatusCommand) {
        Show-VersionHeader
        Invoke-StatusCommand -Args $Install
        exit 0
    } elseif ($isBarePathCommand) {
        Show-VersionHeader
        Invoke-PathCommand -Args $Install
        exit 0
    } elseif ($isBareScanCommand) {
        Show-VersionHeader
        $scanScript = Join-Path $RootDir "scripts\scan\run.ps1"
        $isScanScriptPresent = Test-Path $scanScript
        if (-not $isScanScriptPresent) {
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "Scan dispatcher missing at: $scanScript"
            exit 1
        }
        & $scanScript @Install
        exit $LASTEXITCODE
        Show-VersionHeader
        # Detect --self-check flag in remaining args
        $isSelfCheck = $false
        $isSkipNetwork = $false
        if ($null -ne $Install -and $Install.Count -gt 0) {
            foreach ($a in $Install) {
                $low = "$a".Trim().ToLower()
                if ($low -in @("--self-check", "-self-check", "selfcheck", "--selfcheck", "self-check")) {
                    $isSelfCheck = $true
                }
                if ($low -in @("--skip-network", "-skip-network", "skipnetwork", "--skipnetwork", "skip-network", "--offline", "-offline", "offline")) {
                    $isSkipNetwork = $true
                }
            }
        }
        if ($isSelfCheck) {
            Invoke-DoctorSelfCheck -SkipNetwork:$isSkipNetwork
        } else {
            Invoke-DoctorCommand
        }
        exit 0
    } elseif ($isBareModelsCommand) {
        Show-VersionHeader
        $modelsScript = Join-Path $RootDir "scripts\models\run.ps1"
        & $modelsScript @Install
        exit 0
    } elseif ($isBareUpdateCommand) {
        Show-VersionHeader

        # Self-update: pull latest script changes first
        Remove-Item Env:\SCRIPTS_ROOT_RUN -ErrorAction SilentlyContinue
        $sharedGitPull = Join-Path $RootDir "scripts\shared\git-pull.ps1"
        $isHelperAvailable = Test-Path $sharedGitPull
        if ($isHelperAvailable) {
            . $sharedGitPull
            Invoke-GitPull -RepoRoot $RootDir
        }

        # Parse update arguments from $Install (remaining positional args)
        $updateArgs = @{}
        $updatePackages = @()
        $updateExclude  = @()
        $isCheckOnly    = $false
        $isAutoConfirm  = $false

        if ($null -ne $Install -and $Install.Count -gt 0) {
            foreach ($arg in $Install) {
                $argLower = $arg.Trim().ToLower()

                $isCheckFlag = $argLower -eq "--check" -or $argLower -eq "-check"
                if ($isCheckFlag) { $isCheckOnly = $true; continue }

                $isYesFlag = $argLower -eq "-y" -or $argLower -eq "--yes"
                if ($isYesFlag) { $isAutoConfirm = $true; continue }

                $isExcludeFlag = $argLower.StartsWith("--exclude")
                if ($isExcludeFlag) {
                    # Handle --exclude pkg1,pkg2 or --exclude=pkg1,pkg2
                    $excludeValue = ""
                    $hasEquals = $argLower.Contains("=")
                    if ($hasEquals) {
                        $excludeValue = $arg.Substring($arg.IndexOf("=") + 1)
                    }
                    $hasExcludeValue = $excludeValue.Length -gt 0
                    if ($hasExcludeValue) {
                        $updateExclude += $excludeValue -split ','
                    }
                    continue
                }

                # Otherwise treat as package name(s)
                $pkgTokens = $arg -split '[,\s]+' | Where-Object { $_.Length -gt 0 }
                $updatePackages += $pkgTokens
            }
        }

        # Also check if -Y switch was passed at root level
        if ($Y) { $isAutoConfirm = $true }

        $updateArgs["Packages"]    = $updatePackages
        $updateArgs["Exclude"]     = $updateExclude
        if ($isCheckOnly)   { $updateArgs["CheckOnly"]   = $true }
        if ($isAutoConfirm) { $updateArgs["AutoConfirm"] = $true }

        Invoke-ChocoUpdate @updateArgs
        exit 0
    } elseif ($isBareScriptId) {
        $I = [int]$normalizedCommand
    } else {
        # Treat unknown bare command as a keyword (e.g. .\run.ps1 vscode)
        $Install = @($normalizedCommand) + @($Install | Where-Object { $_ })
    }
}

# ── No params = git pull + help ──────────────────────────────────────
$hasInstallKeywords = $null -ne $Install -and $Install.Count -gt 0
$hasNoParams = -not $hasCommand -and -not $I -and -not $hasInstallKeywords -and -not $d -and -not $a -and -not $h -and -not $v -and -not $w -and -not $t -and -not $M -and -not $Help -and -not $List -and -not $CleanOnly -and -not $Clean -and -not $Defaults
if ($hasNoParams) {
    Remove-Item Env:\SCRIPTS_ROOT_RUN -ErrorAction SilentlyContinue
    $sharedGitPull = Join-Path $RootDir "scripts\shared\git-pull.ps1"
    $isHelperAvailable = Test-Path $sharedGitPull
    if ($isHelperAvailable) {
        . $sharedGitPull
        Invoke-GitPull -RepoRoot $RootDir
    }
    Show-RootHelp
    exit 0
}

# ── List (keyword table only) ────────────────────────────────────────
if ($List) {
    Show-KeywordTable
    exit 0
}

# ── Help ─────────────────────────────────────────────────────────────
if ($Help) {
    Show-RootHelp
    exit 0
}

# ── Handle -CleanOnly (no -I required) ───────────────────────────────
if ($CleanOnly) {
    $resolvedDir = Join-Path $RootDir ".resolved"
    if (Test-Path $resolvedDir) {
        Get-ChildItem -Path $resolvedDir -Recurse -Force | Remove-Item -Recurse -Force
        Write-Host "  [ CLEAN ] " -ForegroundColor Green -NoNewline
        Write-Host "All .resolved/ data wiped"
    } else {
        Write-Host "  [ SKIP  ] " -ForegroundColor DarkGray -NoNewline
        Write-Host "Nothing to clean -- .resolved/ does not exist"
    }
    exit 0
}

# ── Handle -Clean ────────────────────────────────────────────────────
if ($Clean) {
    $resolvedDir = Join-Path $RootDir ".resolved"
    if (Test-Path $resolvedDir) {
        Get-ChildItem -Path $resolvedDir -Recurse -Force | Remove-Item -Recurse -Force
        Write-Host "  [ CLEAN ] " -ForegroundColor Green -NoNewline
        Write-Host "All .resolved/ data wiped -- fresh detection will run"
    } else {
        Write-Host "  [ SKIP  ] " -ForegroundColor DarkGray -NoNewline
        Write-Host "Nothing to clean -- .resolved/ does not exist"
    }
    Write-Host ""
}

# ── Load shared git-pull helper ──────────────────────────────────────
$sharedGitPull = Join-Path $RootDir "scripts\shared\git-pull.ps1"
$isHelperMissing = -not (Test-Path $sharedGitPull)
if ($isHelperMissing) {
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "Shared helper not found: $sharedGitPull"
    exit 1
}
. $sharedGitPull

# ── Git Pull ─────────────────────────────────────────────────────────
Invoke-GitPull -RepoRoot $RootDir

# ── Set flag so child scripts skip git pull ──────────────────────────
$env:SCRIPTS_ROOT_RUN = "1"

# ── Handle install keyword mode (bare or named) ─────────────────────
$hasInstallKeywords = $null -ne $Install -and $Install.Count -gt 0
if ($hasInstallKeywords) {
    $resolvedEntries = Resolve-InstallKeywords -Keywords $Install

    $isResolveFailed = $null -eq $resolvedEntries
    if ($isResolveFailed) { exit 1 }

    $totalSteps = @($resolvedEntries).Count
    $idList = ($resolvedEntries | ForEach-Object {
        $isSubcommand = $_.Kind -eq "subcommand"
        $isRemote     = $_.Kind -eq "remote"
        if ($isSubcommand) {
            "$($_.Dispatcher):$($_.Action)"
        } elseif ($isRemote) {
            "remote:$($_.Key)"
        } else {
            $label = "$($_.Id)"
            $hasMode = -not [string]::IsNullOrWhiteSpace($_.Mode)
            if ($hasMode) {
                $shortMode = ($_.Mode -replace '^group ', '')
                $label = "$label[$shortMode]"
            }
            $label
        }
    }) -join ', '
    Write-Host ""
    Write-Host "  [ INFO ] " -ForegroundColor Cyan -NoNewline
    Write-Host "Installing $totalSteps tool(s): $idList"
    Write-Host ""

    $successCount = 0
    $failCount    = 0

    # Map script IDs to their mode env var names
    $modeEnvVars = @{
        33 = "NPP_MODE"
        16 = "PHP_MODE"
        36 = "OBS_MODE"
        37 = "WT_MODE"
        32 = "DBEAVER_MODE"
        38 = "FLUTTER_MODE"
        39 = "DOTNET_MODE"
        40 = "JAVA_MODE"
        41 = "PYTHON_LIBS_MODE"
        48 = "CONEMU_MODE"
        50 = "ONENOTE_MODE"
    }

    foreach ($entry in $resolvedEntries) {
        $isSubcommand = $entry.Kind -eq "subcommand"
        if ($isSubcommand) {
            # Dispatch e.g. "os clean" or "profile minimal" via root run.ps1 sub-dispatcher
            $dispatcherScript = Join-Path $RootDir "scripts\$($entry.Dispatcher)\run.ps1"
            $isDispatcherPresent = Test-Path $dispatcherScript
            if (-not $isDispatcherPresent) {
                Write-Host ""
                Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
                Write-Host "Subcommand dispatcher not found: $dispatcherScript"
                $failCount++
                continue
            }
            Write-Host ""
            Write-Host "  ----- Subcommand: $($entry.Dispatcher) $($entry.Action) -----" -ForegroundColor Cyan
            $actionParts = $entry.Action -split '\s+' | Where-Object { $_.Length -gt 0 }
            & $dispatcherScript @actionParts
            $code = $LASTEXITCODE
            if ($code -eq 0 -or $null -eq $code) { $successCount++ } else { $failCount++ }
            Refresh-EnvPath
            continue
        }

        $isRemote = $entry.Kind -eq "remote"
        if ($isRemote) {
            # Stream a remote PowerShell installer via 'Invoke-RestMethod | Invoke-Expression'
            # OR (v0.47.1+) read a repo-local wrapper script from disk when 'path' is set.
            $url       = $entry.Url
            $localPath = $entry.LocalPath
            $hasLocal  = -not [string]::IsNullOrWhiteSpace($localPath)
            $hasUrl    = -not [string]::IsNullOrWhiteSpace($url)
            $label     = $entry.Label
            $expectedSha = $entry.Sha256
            $hasExpectedSha = -not [string]::IsNullOrWhiteSpace($expectedSha)
            $hasLabel = -not [string]::IsNullOrWhiteSpace($label)
            $displayLabel = if ($hasLabel) { $label } else { $entry.Key }

            $sourceDescription = if ($hasLocal) { "local: $localPath" } else { $url }
            $commandHint       = if ($hasLocal) { "Get-Content '$localPath' -Raw | iex" } else { "irm $url | iex" }

            Write-Host ""
            Write-Host "  ----- Remote: $($entry.Key) -----" -ForegroundColor Cyan
            Write-Host "  $displayLabel" -ForegroundColor DarkGray
            Write-Host "  Source : $sourceDescription" -ForegroundColor DarkGray
            Write-Host "  Command: $commandHint" -ForegroundColor DarkGray
            if ($hasExpectedSha) {
                Write-Host "  SHA256 : $expectedSha (pinned -- verified before exec)" -ForegroundColor DarkGray
            } else {
                Write-Host "  SHA256 : (not pinned -- add 'sha256' to remote.$($entry.Key) in install-keywords.json to enable integrity check)" -ForegroundColor DarkYellow
            }
            Write-Host ""

            $remoteFailed = $false
            $remoteError  = $null
            try {
                if ($hasLocal) {
                    $isLocalMissing = -not (Test-Path -LiteralPath $localPath)
                    if ($isLocalMissing) {
                        $remoteFailed = $true
                        $remoteError  = "Local wrapper not found on disk. Path: $localPath  (referenced by install-keywords.json -> remote.$($entry.Key).path)"
                        $script = $null
                    } else {
                        $script = Get-Content -LiteralPath $localPath -Raw -ErrorAction Stop
                    }
                } else {
                    $script = Invoke-RestMethod -Uri $url -UseBasicParsing -ErrorAction Stop
                }
                if (-not $remoteFailed) {
                    $isScriptEmpty = [string]::IsNullOrWhiteSpace($script)
                    if ($isScriptEmpty) {
                        $remoteFailed = $true
                        $remoteError  = if ($hasLocal) { "Local wrapper is empty: $localPath" } else { "Remote URL returned an empty body" }
                    } else {
                        # ── SHA256 integrity check (CODE RED: never exec unverified body) ──
                        $isHashMismatch = $false
                        if ($hasExpectedSha) {
                            try {
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes("$script")
                                $sha = [System.Security.Cryptography.SHA256]::Create()
                                $hashBytes = $sha.ComputeHash($bytes)
                                $sha.Dispose()
                                $actualSha = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
                            } catch {
                                $remoteFailed = $true
                                $remoteError  = "SHA256 computation failed: $($_.Exception.Message)"
                                $isHashMismatch = $true
                            }
                            if (-not $remoteFailed) {
                                $isMatch = $actualSha -eq $expectedSha
                                if (-not $isMatch) {
                                    $isHashMismatch = $true
                                    $remoteFailed = $true
                                    $pinSrc = "install-keywords.json -> remote.$($entry.Key).sha256"
                                    $remoteError  = "SHA256 mismatch -- refusing to execute unverified body. Expected: $expectedSha  Actual: $actualSha  Source: $sourceDescription  Pin source: $pinSrc"
                                } else {
                                    Write-Host "  [  OK  ] " -ForegroundColor Green -NoNewline
                                    Write-Host "SHA256 verified ($actualSha)"
                                }
                            }
                        }

                        if (-not $isHashMismatch) {
                            Invoke-Expression $script
                            $code = $LASTEXITCODE
                            if ($null -ne $code -and $code -ne 0) {
                                $remoteFailed = $true
                                $remoteError  = "Remote installer exited with code $code"
                            }
                        }
                    }
                }
            } catch {
                $remoteFailed = $true
                $remoteError  = $_.Exception.Message
            }

            if ($remoteFailed) {
                Write-Host ""
                Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
                Write-Host "Remote installer '$($entry.Key)' failed."
                Write-Host "          Source : $sourceDescription" -ForegroundColor DarkGray
                Write-Host "          Reason : $remoteError" -ForegroundColor DarkGray
                $failCount++
            } else {
                Write-Host ""
                Write-Host "  [  OK  ] " -ForegroundColor Green -NoNewline
                Write-Host "Remote installer '$($entry.Key)' completed."
                $successCount++
            }
            Refresh-EnvPath
            continue
        }

        $id      = $entry.Id
        $modeKey = $entry.Mode
        $hasModeOverride = -not [string]::IsNullOrWhiteSpace($modeKey)
        $envVarName = $modeEnvVars[$id]
        $hasEnvVar  = $null -ne $envVarName
        if ($hasModeOverride -and $hasEnvVar) {
            Set-Item "Env:\$envVarName" $modeKey
        }
        $result = Invoke-ScriptById -ScriptId $id
        if ($hasModeOverride -and $hasEnvVar) {
            Remove-Item "Env:\$envVarName" -ErrorAction SilentlyContinue
        }
        if ($result) { $successCount++ } else { $failCount++ }

        # Refresh PATH between chained scripts so newly installed tools are discoverable
        Refresh-EnvPath
    }

    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor DarkGray
    Write-Host "  [ DONE ] " -ForegroundColor Green -NoNewline
    Write-Host "$successCount of $totalSteps completed successfully"
    if ($failCount -gt 0) {
        Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
        Write-Host "$failCount script(s) failed"
    }

    Remove-Item Env:\SCRIPTS_ROOT_RUN -ErrorAction SilentlyContinue
    exit 0
}

# ── -M shortcut: dispatch to models orchestrator ─────────────────────
if ($M) {
    Show-VersionHeader
    $modelsScript = Join-Path $RootDir "scripts\models\run.ps1"
    & $modelsScript @Install
    exit 0
}

# ── Expand shortcuts ──────────────────────────────────────────────────
if ($d) { $I = 12 }
if ($a) { $I = 13 }
if ($v) { $I = 1 }
if ($w) { $I = 14 }
if ($t) { $I = 15 }
if ($h) { $I = 13; $scriptArgs = @{ "Report" = $true } }
# -Defaults without -I defaults to all-dev (script 12)
if ($Defaults -and -not $I) { $I = 12 }

# ── Validate -I is provided ──────────────────────────────────────────
$isMissingParam = -not $I
if ($isMissingParam) {
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "Missing -I parameter. Usage: .\run.ps1 -I <number>"
    Write-Host ""
    Write-Host "  Run .\run.ps1 -Help to see all available scripts" -ForegroundColor Cyan
    exit 1
}

# ── Delegate to single script ────────────────────────────────────────
$isScriptArgsUndefined = -not (Test-Path variable:scriptArgs) -or $null -eq $scriptArgs
if ($isScriptArgsUndefined) { $scriptArgs = @{} }
if ($Merge) { $scriptArgs["Merge"] = $true }
if ($Defaults) { $scriptArgs["Defaults"] = $true }

# ── -Defaults -Y confirmation logic ──────────────────────────────────
if ($Defaults -and -not $Y) {
    Write-Host ""
    Write-Host "  Defaults Mode" -ForegroundColor Cyan
    Write-Host "  =============" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Dev directory     : " -NoNewline -ForegroundColor DarkGray; Write-Host "auto (E:\dev-tool -- smart detection)" -ForegroundColor White
    Write-Host "    VS Code edition   : " -NoNewline -ForegroundColor DarkGray; Write-Host "Stable" -ForegroundColor White
    Write-Host "    Settings sync     : " -NoNewline -ForegroundColor DarkGray; Write-Host "Overwrite" -ForegroundColor White
    Write-Host ""
    $confirm = Read-Host "  Proceed with these defaults? [Y/n]"
    $isAborted = $confirm.Trim().ToUpper() -eq "N"
    if ($isAborted) {
        Write-Host "  [ SKIP ] Aborted by user." -ForegroundColor Yellow
        exit 0
    }
}

$result = Invoke-ScriptById -ScriptId $I -ExtraArgs $scriptArgs

$isScriptFailed = -not $result
if ($isScriptFailed) { exit 1 }

# ── Clean up env flag ────────────────────────────────────────────────
Remove-Item Env:\SCRIPTS_ROOT_RUN -ErrorAction SilentlyContinue
