<#
.SYNOPSIS
    OS subcommand dispatcher. Routes 'os <action>' to the right helper.

.DESCRIPTION
    Static actions: clean, temp-clean, hib-off/on, flp, add-user, help.
    Dynamic actions: every clean-<name> resolves to clean-categories\<name>.ps1
    (36 categories, see `os --help`).

.EXAMPLES
    .\run.ps1 os clean
    .\run.ps1 os clean --dry-run
    .\run.ps1 os clean --bucket D
    .\run.ps1 os clean --skip recycle,ms-search
    .\run.ps1 os clean-chrome
    .\run.ps1 os clean-recycle --yes
    .\run.ps1 os clean-obs-recordings --days 7 --dry-run
#>
param(
    [Parameter(Position = 0)]
    [string]$Action,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"
$categoriesDir = Join-Path $scriptDir "helpers\clean-categories"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $sharedDir "registry-trace.ps1")

# --summary-json is a global os-level flag: strip it from $Rest before
# splatting (child helpers reject unknown args) and propagate to children
# via env so Close-RegistryTrace emits a JSON summary line at run end.
if (Test-SummaryJsonSwitch -Argv $Rest) {
    $Rest = Remove-SummaryJsonSwitch -Argv $Rest
    $env:REGTRACE_SUMMARY_JSON = "1"
    Set-RegistryTraceSummaryJson -Enabled $true
}

# --summary-tail N: same propagation pattern. Default tail is 20; override
# with any non-negative integer (0 = totals only). Invalid value is ignored
# (default kept). Strip both the flag and its value from $Rest.
# --summary-tail-warn (opt-in): when set, an invalid --summary-tail value
# triggers a yellow [ WARN ] line instead of being silently dropped.
# --summary-tail-quiet (override): when set ALONGSIDE --summary-tail-warn,
# suppresses the warning while keeping the silent fallback. No-op when warn
# is absent (default behavior is already silent).
$wantsTailWarn  = Test-SummaryTailWarnSwitch  -Argv $Rest
$wantsTailQuiet = Test-SummaryTailQuietSwitch -Argv $Rest
if ($wantsTailWarn)  { $Rest = Remove-SummaryTailWarnSwitch  -Argv $Rest }
if ($wantsTailQuiet) { $Rest = Remove-SummaryTailQuietSwitch -Argv $Rest }
# Quiet wins when both flags are present.
$emitTailWarn = $wantsTailWarn -and -not $wantsTailQuiet
$summaryTailArg = Get-SummaryTailArg -Argv $Rest
if ($null -ne $summaryTailArg) {
    $Rest = Remove-SummaryTailArg -Argv $Rest
    $env:REGTRACE_SUMMARY_TAIL = "$summaryTailArg"
} elseif ($emitTailWarn) {
    # Invalid (or absent). Only warn if the flag was actually present.
    $tailRaw = Get-SummaryTailRaw -Argv $Rest
    if ($null -ne $tailRaw -and $tailRaw.Present) {
        Write-SummaryTailWarning -RawInfo $tailRaw
        $Rest = Remove-SummaryTailArg -Argv $Rest
    }
}

$logMessages = $null
$logMessagesPath = Join-Path $scriptDir "log-messages.json"
if (Test-Path $logMessagesPath) {
    $logMessages = Import-JsonConfig $logMessagesPath
}

# Catalog rendered in help (also the source of truth for valid clean-<name>)
$script:CleanCatalog = @(
    @{ B = "A"; Cat = "chkdsk";              Desc = "C:\found.*\*.chk fragments" },
    @{ B = "A"; Cat = "dns";                 Desc = "ipconfig /flushdns" },
    @{ B = "A"; Cat = "recycle";             Desc = "Empty Recycle Bin (DESTRUCTIVE -- consent)" },
    @{ B = "A"; Cat = "delivery-opt";        Desc = "WU Delivery Optimization cache" },
    @{ B = "A"; Cat = "error-reports";       Desc = "Windows Error Reports (WER)" },
    @{ B = "A"; Cat = "event-logs";          Desc = "All Windows event logs (wevtutil cl)" },
    @{ B = "A"; Cat = "etl";                 Desc = "ETW trace files (*.etl)" },
    @{ B = "A"; Cat = "windows-logs";        Desc = "CBS / DISM / WindowsUpdate logs" },
    @{ B = "B"; Cat = "notifications";       Desc = "Windows Notifications (wpndatabase)" },
    @{ B = "B"; Cat = "explorer-mru";        Desc = "Run/RecentDocs/TypedPaths registry" },
    @{ B = "B"; Cat = "recent-docs";         Desc = "Quick Access recent files" },
    @{ B = "B"; Cat = "jumplist";            Desc = "Taskbar jump-lists" },
    @{ B = "B"; Cat = "thumbnails";          Desc = "Thumbnail + icon cache" },
    @{ B = "B"; Cat = "ms-search";           Desc = "Windows Search index (DESTRUCTIVE -- consent)" },
    @{ B = "C"; Cat = "dx-shader";           Desc = "DirectX/NVIDIA/AMD shader caches" },
    @{ B = "C"; Cat = "web-cache";           Desc = "Legacy IE/Edge INetCache" },
    @{ B = "C"; Cat = "font-cache";          Desc = "Windows font cache" },
    @{ B = "D"; Cat = "chrome";              Desc = "Chrome cache (cookies/history SAFE)" },
    @{ B = "D"; Cat = "edge";                Desc = "Edge cache (cookies/history SAFE)" },
    @{ B = "D"; Cat = "firefox";             Desc = "Firefox cache (cookies/history SAFE)" },
    @{ B = "D"; Cat = "brave";               Desc = "Brave cache (cookies/history SAFE)" },
    @{ B = "E"; Cat = "clipchamp";           Desc = "Clipchamp cache (drafts SAFE)" },
    @{ B = "E"; Cat = "vlc";                 Desc = "VLC art + media library cache" },
    @{ B = "E"; Cat = "discord";             Desc = "Discord cache (login SAFE)" },
    @{ B = "E"; Cat = "spotify";             Desc = "Spotify cache (offline downloads SAFE)" },
    @{ B = "E"; Cat = "office";              Desc = "MS Office cache (documents SAFE)" },
    @{ B = "E"; Cat = "whatsapp";            Desc = "WhatsApp cache (chats + login SAFE)" },
    @{ B = "E"; Cat = "telegram";            Desc = "Telegram cache (chats + login SAFE)" },
    @{ B = "E"; Cat = "zoom";                Desc = "Zoom cache (recordings + chats SAFE)" },
    @{ B = "E"; Cat = "slack";               Desc = "Slack cache (login + history SAFE)" },
    @{ B = "E"; Cat = "teams";               Desc = "Teams cache Classic+New (auth + chat SAFE)" },
    @{ B = "E"; Cat = "onedrive-cache";      Desc = "OneDrive client cache (synced files SAFE)" },
    @{ B = "F"; Cat = "vscode-cache";        Desc = "VS Code cache + logs (workspaces SAFE)" },
    @{ B = "F"; Cat = "vscode-extensions-cache"; Desc = "VS Code per-extension cache+logs (extensions SAFE)" },
    @{ B = "F"; Cat = "jetbrains-cache";     Desc = "JetBrains IDE caches+logs (settings+projects SAFE)" },
    @{ B = "F"; Cat = "android-studio-cache";Desc = "Android Studio caches + AVD snapshots (SDK SAFE)" },
    @{ B = "F"; Cat = "gradle-cache";        Desc = "Gradle ~/.gradle caches + daemon (wrappers SAFE)" },
    @{ B = "F"; Cat = "yarn-cache";          Desc = "Yarn global cache v1 + Berry (projects SAFE)" },
    @{ B = "F"; Cat = "bun-cache";           Desc = "Bun install/module cache (.bun/bin runtime SAFE)" },
    @{ B = "F"; Cat = "cargo-registry";      Desc = "Cargo registry cache + git checkouts (.cargo/bin SAFE)" },
    @{ B = "F"; Cat = "go-buildcache";       Desc = "Go build cache + module downloads (~/go/bin SAFE)" },
    @{ B = "F"; Cat = "maven-repo";          Desc = "Maven ~/.m2/repository + wrapper dists (settings SAFE)" },
    @{ B = "F"; Cat = "conda-pkgs";          Desc = "Conda pkgs cache (anaconda3 + miniconda3 + .conda; envs SAFE)" },
    @{ B = "F"; Cat = "poetry-cache";        Desc = "Poetry pkg + venv cache (pyproject + .venv SAFE)" },
    @{ B = "F"; Cat = "pnpm-store";          Desc = "pnpm CAS store (.pnpm-store + LOCALAPPDATA pnpm; runtime SAFE)" },
    @{ B = "F"; Cat = "deno-cache";          Desc = "Deno DENO_DIR (deps/gen/npm/registries; runtime SAFE)" },
    @{ B = "F"; Cat = "rustup-toolchains";   Desc = "Stale rustup toolchains >--days N (active + pinned SAFE)" },
    @{ B = "F"; Cat = "pyenv-cache";         Desc = "pyenv-win download cache + per-version pip caches (interpreters SAFE)" },
    @{ B = "F"; Cat = "nvm-cache";           Desc = "nvm-windows tmp + per-version npm caches (Node versions SAFE)" },
    @{ B = "F"; Cat = "volta-cache";         Desc = "Volta installer + tarball cache (pinned tools SAFE)" },
    @{ B = "F"; Cat = "asdf-cache";          Desc = "asdf downloads + stale installs >--days N (active SAFE)" },
    @{ B = "F"; Cat = "mise-cache";          Desc = "mise cache + downloads (installed tools + shims SAFE)" },
    @{ B = "F"; Cat = "npm-cache";           Desc = "npm cache clean --force" },
    @{ B = "F"; Cat = "pip-cache";           Desc = "pip cache purge" },
    @{ B = "F"; Cat = "docker-dangling";     Desc = "docker system prune -f" },
    @{ B = "F"; Cat = "wsl";                 Desc = "WSL /tmp + apt cache + ~/.cache (rootfs SAFE)" },
    @{ B = "G"; Cat = "obs-recordings";      Desc = "~/Videos *.mkv|*.mp4 >N days (DESTRUCTIVE -- consent)" },
    @{ B = "G"; Cat = "steam-shader";        Desc = "Steam shader cache (all libraries)" },
    @{ B = "G"; Cat = "windows-update-old";  Desc = "DISM ResetBase (DESTRUCTIVE -- consent)" }
)

function Show-OsHelp {
    Write-Host ""
    Write-Host "  OS Subcommands" -ForegroundColor Cyan
    Write-Host "  ==============" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Usage: .\run.ps1 os <action> [args]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  PRIMARY ACTIONS" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    clean [flags]                                          Run all 59 cleanup categories" -ForegroundColor Green
    Write-Host "      --yes                Auto-consent destructive categories" -ForegroundColor DarkGray
    Write-Host "      --dry-run            Report only (no deletions, no consent file written)" -ForegroundColor DarkGray
    Write-Host "      --skip <a,b,c>       Skip listed categories" -ForegroundColor DarkGray
    Write-Host "      --only <a,b,c>       Run only listed categories" -ForegroundColor DarkGray
    Write-Host "      --bucket <A..G>      Run only one bucket (e.g. D = browsers)" -ForegroundColor DarkGray
    Write-Host "      --days <N>           Age threshold for media subcommands (default 30)" -ForegroundColor DarkGray
    Write-Host "      --consent-list       Print categories with recorded consent and exit" -ForegroundColor DarkGray
    Write-Host "      --consent-reset      Wipe .resolved/os-clean-consent.json (prompts unless --yes)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    temp-clean [flags]                                     Temp dirs only (legacy helper)" -ForegroundColor Green
    Write-Host "    hib-off | hib-on                                       Disable/enable hibernation" -ForegroundColor Green
    Write-Host "    flp                                                    Enable Win32 long-path support" -ForegroundColor Green
    Write-Host "    add-user <name> <pass> [pin] [email]                   Create local Windows user" -ForegroundColor Green
    Write-Host ""
    Write-Host "  STARTUP MANAGEMENT (cross-OS feature, Windows side)" -ForegroundColor Cyan
    Write-Host "    startup-add app <path> [--method M] [--name N] [--args ...] [--interactive] [--elevated]" -ForegroundColor Green
    Write-Host "      Methods: startup-folder (default, no admin) | hkcu-run | hklm-run [ADMIN] | task [ADMIN for HIGHEST]" -ForegroundColor DarkGray
    Write-Host "    startup-add env KEY=VALUE [--scope user|machine] [--method registry|setx]" -ForegroundColor Green
    Write-Host "      Default: HKCU Environment + WM_SETTINGCHANGE broadcast (no logoff needed)" -ForegroundColor DarkGray
    Write-Host "    startup-list [--scope user|machine|all]                Enumerate managed entries (tag: lovable-startup-*)" -ForegroundColor Green
    Write-Host "    startup-remove <name> [--method ...]                   Remove a managed entry from one or all methods" -ForegroundColor Green
    Write-Host ""
    Write-Host "  CLEAN-* SUBCOMMANDS (each accepts --dry-run / --yes / --days N)" -ForegroundColor Cyan
    $currentBucket = ""
    $bucketLabels = @{
        "A" = "Bucket A -- System"
        "B" = "Bucket B -- User shell"
        "C" = "Bucket C -- Graphics / Web"
        "D" = "Bucket D -- Browsers (cache only -- cookies/history NEVER touched)"
        "E" = "Bucket E -- Apps (cache only)"
        "F" = "Bucket F -- Dev tools"
        "G" = "Bucket G -- Media (age-gated / DISM)"
    }
    foreach ($entry in $script:CleanCatalog) {
        if ($entry.B -ne $currentBucket) {
            Write-Host ""
            Write-Host "    $($bucketLabels[$entry.B])" -ForegroundColor Yellow
            $currentBucket = $entry.B
        }
        Write-Host ("      clean-{0,-21} {1}" -f $entry.Cat, $entry.Desc) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  CONSENT" -ForegroundColor Cyan
    Write-Host "    Destructive categories (recycle, ms-search, obs-recordings, windows-update-old)" -ForegroundColor DarkGray
    Write-Host "    require typed 'yes' on first run. Persisted in .resolved/os-clean-consent.json." -ForegroundColor DarkGray
    Write-Host "    Use --yes to auto-consent, --dry-run to explore safely without consent." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  REGISTRY TRACE FLAGS (global, work with any action that touches registry)" -ForegroundColor Cyan
    Write-Host "    -Verbose                Enable per-operation registry trace logging to .logs/" -ForegroundColor DarkGray
    Write-Host "    --summary-tail <N>      End-of-run summary: show last N trace lines (default 20)" -ForegroundColor DarkGray
    Write-Host "                            Accepted forms (case-insensitive):" -ForegroundColor DarkGray
    Write-Host "                              --summary-tail 50        (space separator)" -ForegroundColor DarkGray
    Write-Host "                              --summary-tail=50        (equals separator)" -ForegroundColor DarkGray
    Write-Host "                              --summary-tail:50        (colon separator)" -ForegroundColor DarkGray
    Write-Host "                              -summary-tail 50         (single-dash variant)" -ForegroundColor DarkGray
    Write-Host "                              -SummaryTail 50          (PowerShell PascalCase)" -ForegroundColor DarkGray
    Write-Host "                              /summary-tail 50         (Windows slash style)" -ForegroundColor DarkGray
    Write-Host "                            Special: N=0 shows totals only (no tail lines)" -ForegroundColor DarkGray
    Write-Host "    --summary-json          Emit machine-readable JSON summary to stdout (for CI/piping)" -ForegroundColor DarkGray
    Write-Host "    --summary-tail-warn     Opt-in: print [ WARN ] when --summary-tail value is invalid" -ForegroundColor DarkGray
    Write-Host "                            (default behavior is silent fallback to 20 -- this flag" -ForegroundColor DarkGray
    Write-Host "                             surfaces typos so they don't get lost in CI logs)" -ForegroundColor DarkGray
    Write-Host "    --summary-tail-quiet    Override: suppress the [ WARN ] from --summary-tail-warn" -ForegroundColor DarkGray
    Write-Host "                            while keeping the silent fallback. Use when one job in a" -ForegroundColor DarkGray
    Write-Host "                            warn-enabled CI workflow legitimately passes a placeholder." -ForegroundColor DarkGray
    Write-Host "                            No-op without --summary-tail-warn (default is already silent)." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    VALID vs INVALID examples:" -ForegroundColor Cyan
    Write-Host "      VALID:  --summary-tail 50      -> 50 lines shown" -ForegroundColor DarkGray
    Write-Host "      VALID:  --summary-tail=50      -> 50 lines shown" -ForegroundColor DarkGray
    Write-Host "      VALID:  --summary-tail:50       -> 50 lines shown" -ForegroundColor DarkGray
    Write-Host "      VALID:  -summary-tail 50       -> 50 lines shown (single dash)" -ForegroundColor DarkGray
    Write-Host "      VALID:  --SUMMARY-TAIL 50       -> 50 lines shown (case insensitive)" -ForegroundColor DarkGray
    Write-Host "      VALID:  --summary-tail 0        -> 0 lines (totals only mode)" -ForegroundColor DarkGray
    Write-Host "      INVALID: --summary-tail -1      -> falls back to 20 (negative rejected)" -ForegroundColor DarkGray
    Write-Host "      INVALID: --summary-tail abc     -> falls back to 20 (non-numeric)" -ForegroundColor DarkGray
    Write-Host "      INVALID: --summary-tail 3.5    -> falls back to 20 (decimals rejected)" -ForegroundColor DarkGray
    Write-Host "      INVALID: --summary-tail          -> falls back to 20 (missing value)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Add --summary-tail-warn to any of the INVALID examples to see a yellow [ WARN ]" -ForegroundColor DarkGray
    Write-Host "    line explaining exactly why the value was dropped (negative / non-numeric / etc)." -ForegroundColor DarkGray
    Write-Host "    Add --summary-tail-quiet to silence that warning again (quiet wins over warn)." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Flag combination matrix (--summary-tail abc --summary-tail-...):" -ForegroundColor Cyan
    Write-Host "      neither flag                  -> silent fallback to 20  (default)" -ForegroundColor DarkGray
    Write-Host "      --summary-tail-warn           -> [ WARN ] printed + fallback to 20" -ForegroundColor DarkGray
    Write-Host "      --summary-tail-quiet          -> silent fallback to 20  (no-op alone)" -ForegroundColor DarkGray
    Write-Host "      both warn AND quiet           -> silent fallback to 20  (quiet wins)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Parity: human summary line count == JSON tail[] length (same formula)" -ForegroundColor DarkGray
    Write-Host "      - 0 ops recorded:    human shows 'no operations' notice; JSON tail=[]    (both 0)" -ForegroundColor DarkGray
    Write-Host "      - tail > buffer:     buffer is capped at 20; both clamp to min(N, buffer)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  TRY IT (copy-paste examples)" -ForegroundColor Cyan
    Write-Host "    # Invalid: fallback to 20 lines" -ForegroundColor DarkGray
    Write-Host '      .\run.ps1 os clean-explorer-mru -Verbose --summary-tail -1 --summary-json' -ForegroundColor Yellow
    Write-Host '      # tail[] shows 20 items (or fewer if buffer smaller)' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    # Invalid text: same fallback" -ForegroundColor DarkGray
    Write-Host '      .\run.ps1 os clean-explorer-mru -Verbose --summary-tail abc --summary-json' -ForegroundColor Yellow
    Write-Host '      # tail[] shows 20 items (or fewer if buffer smaller)' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    # Totals only: empty tail array" -ForegroundColor DarkGray
    Write-Host '      .\run.ps1 os clean-explorer-mru -Verbose --summary-tail 0 --summary-json' -ForegroundColor Yellow
    Write-Host '      # tail[] is [] (empty) -- only counts appear' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    # Large tail: clamped to buffer size" -ForegroundColor DarkGray
    Write-Host '      .\run.ps1 os clean-explorer-mru -Verbose --summary-tail 50 --summary-json' -ForegroundColor Yellow
    Write-Host '      # tail[] shows min(50, buffer.Count) items (max 20 due to buffer cap)' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  CI EXAMPLE -- catch typos in GitHub Actions" -ForegroundColor Cyan
    Write-Host "    Add --summary-tail-warn to your workflow to surface fat-fingered tail values" -ForegroundColor DarkGray
    Write-Host "    instead of letting them silently fall back to 20:" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    # .github/workflows/cleanup.yml" -ForegroundColor DarkGray
    Write-Host "    jobs:" -ForegroundColor Yellow
    Write-Host "      cleanup:" -ForegroundColor Yellow
    Write-Host "        runs-on: windows-latest" -ForegroundColor Yellow
    Write-Host "        steps:" -ForegroundColor Yellow
    Write-Host "          - uses: actions/checkout@v4" -ForegroundColor Yellow
    Write-Host "          - name: Run OS clean with summary" -ForegroundColor Yellow
    Write-Host "            shell: pwsh" -ForegroundColor Yellow
    Write-Host "            run: |" -ForegroundColor Yellow
    Write-Host "              .\run.ps1 os clean -Verbose --dry-run ``" -ForegroundColor Yellow
    Write-Host "                --summary-tail `$`{`{ vars.TAIL_LINES }`} ``" -ForegroundColor Yellow
    Write-Host "                --summary-tail-warn ``" -ForegroundColor Yellow
    Write-Host "                --summary-json | Tee-Object -FilePath summary.json" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    Why this matters:" -ForegroundColor DarkGray
    Write-Host "      * Without --summary-tail-warn: vars.TAIL_LINES = '5O' (letter O)" -ForegroundColor DarkGray
    Write-Host "        silently falls back to 20. You'd never know the var was bad." -ForegroundColor DarkGray
    Write-Host "      * With --summary-tail-warn: a yellow [ WARN ] line appears in the" -ForegroundColor DarkGray
    Write-Host "        Actions log:" -ForegroundColor DarkGray
    Write-Host "          [ WARN ] --summary-tail ignored: value '5O' is not numeric." -ForegroundColor Yellow
    Write-Host "                  Falling back to default 20." -ForegroundColor DarkGray
    Write-Host "      * Confirm with the JSON: tailSource='default' (vs 'env' when valid)." -ForegroundColor DarkGray
    Write-Host "      * Optional: grep for [ WARN ] in your job to fail-fast on bad config:" -ForegroundColor DarkGray
    Write-Host "          grep '\[ WARN \] --summary-tail' summary.json && exit 1" -ForegroundColor DarkGray
    Write-Host ""
}

$normalizedAction = ""
$hasAction = -not [string]::IsNullOrWhiteSpace($Action)
if ($hasAction) { $normalizedAction = $Action.Trim().ToLower() }

# ---- clean-<name> dynamic dispatch ----
if ($normalizedAction -match '^clean-(.+)$') {
    $cat = $Matches[1]
    $isKnown = ($script:CleanCatalog | Where-Object { $_.Cat -eq $cat }).Count -gt 0
    if (-not $isKnown) {
        Write-Host ""
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Unknown clean category: '$cat'"
        Write-Host "          Run '.\run.ps1 os --help' for the full list." -ForegroundColor DarkGray
        exit 1
    }
    & (Join-Path $scriptDir "helpers\clean-runner.ps1") -Category $cat @Rest
    exit $LASTEXITCODE
}

switch ($normalizedAction) {
    "clean" {
        & (Join-Path $scriptDir "helpers\clean.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("temp-clean", "tempclean", "temp") } {
        & (Join-Path $scriptDir "helpers\temp-clean.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("hib-off", "hibernate-off") } {
        & (Join-Path $scriptDir "helpers\hibernate.ps1") -Off @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("hib-on", "hibernate-on") } {
        & (Join-Path $scriptDir "helpers\hibernate.ps1") -On @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("flp", "fix-long-path", "longpath", "long-path") } {
        & (Join-Path $scriptDir "helpers\longpath.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("add-user", "adduser", "new-user") } {
        & (Join-Path $scriptDir "helpers\add-user.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("startup-add", "startupadd") } {
        & (Join-Path $scriptDir "helpers\startup-add.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("startup-list", "startuplist") } {
        & (Join-Path $scriptDir "helpers\startup-list.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("startup-remove", "startupremove", "startup-rm") } {
        & (Join-Path $scriptDir "helpers\startup-remove.ps1") @Rest
        exit $LASTEXITCODE
    }
    { $_ -in @("help", "--help", "-h", "") } {
        Show-OsHelp
        exit 0
    }
    default {
        Write-Host ""
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Unknown 'os' action: '$Action'"
        Show-OsHelp
        exit 1
    }
}
