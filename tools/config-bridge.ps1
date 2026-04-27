# --------------------------------------------------------------------------
#  Config Bridge -- tiny localhost HTTP server that lets the Lovable
#  Settings page (/settings) save scripts/52-vscode-folder-repair/config.json
#  on this machine. Run this in a PowerShell window while you use the UI.
#
#  Usage:
#    .\config-bridge.ps1                      # default: 127.0.0.1:7531
#    .\config-bridge.ps1 -Port 8080
#    .\config-bridge.ps1 -Token "my-secret"   # require X-Bridge-Token header
#
#  Endpoints:
#    GET   /health                   -> { ok: true, root: "<repo>" }
#    GET   /config?script=52         -> current config.json contents
#    POST  /config?script=52         -> overwrite config.json (body = full JSON)
#    PATCH /config?script=52         -> deep-merge partial options into the
#                                       stored config and return updated JSON
#                                       (also reachable as POST /config/options)
#
#  Security:
#    - Binds to 127.0.0.1 only (never reachable from the network)
#    - Optional -Token enforces an X-Bridge-Token header on writes
#    - Whitelists which script folders may be written via $allowedScripts
# --------------------------------------------------------------------------
param(
    [int]$Port = 7531,
    [string]$Token = "",
    [string]$AllowOrigin = "*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Whitelist: script id -> relative config path. Add entries here to expose more.
$allowedScripts = @{
    "52" = "scripts\52-vscode-folder-repair\config.json"
    "31" = "scripts\31-pwsh-context-menu\config.json"
}

function Write-FileError {
    param([string]$Path, [string]$Reason)
    # CODE RED: every file/path error must include exact path + reason
    Write-Host "  [FAIL] path: $Path -- reason: $Reason" -ForegroundColor Red
}

function Merge-Config {
    # Deep-merge $patch into $base. Objects merge key-by-key; arrays and
    # scalars from $patch replace whatever was in $base. Returns merged object.
    param($Base, $Patch)
    if ($null -eq $Base)  { return $Patch }
    if ($null -eq $Patch) { return $Base }

    $isBaseObj  = $Base  -is [psobject] -and -not ($Base  -is [Array])
    $isPatchObj = $Patch -is [psobject] -and -not ($Patch -is [Array])
    if (-not ($isBaseObj -and $isPatchObj)) { return $Patch }

    $result = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties)  { $result[$p.Name] = $p.Value }
    foreach ($p in $Patch.PSObject.Properties) {
        if ($result.Contains($p.Name)) {
            $result[$p.Name] = Merge-Config -Base $result[$p.Name] -Patch $p.Value
        } else {
            $result[$p.Name] = $p.Value
        }
    }
    return [pscustomobject]$result
}

function Save-ConfigJson {
    param([string]$Path, [string]$Json)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path) {
        $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
        Copy-Item -LiteralPath $Path -Destination "$Path.$stamp.bak" -Force
    }
    Set-Content -LiteralPath $Path -Value $Json -Encoding UTF8 -NoNewline
}

function Send-Json {
    param($Response, [int]$Status, $Payload)
    $json = if ($Payload -is [string]) { $Payload } else { $Payload | ConvertTo-Json -Depth 32 }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $Status
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.Headers.Add("Access-Control-Allow-Origin",  $AllowOrigin)
    $Response.Headers.Add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
    $Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-Bridge-Token")
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Resolve-ConfigPath {
    param([string]$ScriptId)
    if (-not $allowedScripts.ContainsKey($ScriptId)) { return $null }
    return Join-Path $repoRoot $allowedScripts[$ScriptId]
}

# ---- Start listener ---------------------------------------------------------
$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-FileError -Path $prefix -Reason $_.Exception.Message
    Write-Host "  Tip: try a different -Port or run as Administrator if URL ACL blocks the prefix." -ForegroundColor Yellow
    return
}

Write-Host ""
Write-Host "  Config Bridge listening on $prefix" -ForegroundColor Cyan
Write-Host "  Repo root : $repoRoot" -ForegroundColor DarkGray
Write-Host "  Scripts   : $($allowedScripts.Keys -join ', ')" -ForegroundColor DarkGray
$hasToken = -not [string]::IsNullOrWhiteSpace($Token)
if ($hasToken) {
    Write-Host "  Auth      : X-Bridge-Token required on POST" -ForegroundColor DarkGray
} else {
    Write-Host "  Auth      : none (localhost only). Pass -Token to require a header." -ForegroundColor Yellow
}
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($listener.IsListening) {
        $ctx  = $listener.GetContext()
        $req  = $ctx.Request
        $res  = $ctx.Response
        $path = $req.Url.AbsolutePath.TrimEnd('/')
        $method = $req.HttpMethod.ToUpper()

        Write-Host ("  [{0}] {1} {2}" -f (Get-Date -Format HH:mm:ss), $method, $req.Url.PathAndQuery) -ForegroundColor DarkGray

        # CORS preflight
        if ($method -eq "OPTIONS") { Send-Json $res 204 ""; continue }

        # Health
        if ($method -eq "GET" -and ($path -eq "/health" -or $path -eq "")) {
            Send-Json $res 200 @{ ok = $true; root = $repoRoot; scripts = @($allowedScripts.Keys) }
            continue
        }

        $isOptionsRoute = ($path -eq "/config/options")
        if ($path -ne "/config" -and -not $isOptionsRoute) {
            Send-Json $res 404 @{ error = "not found"; path = $path }
            continue
        }

        $scriptId = $req.QueryString["script"]
        if ([string]::IsNullOrWhiteSpace($scriptId)) {
            Send-Json $res 400 @{ error = "missing ?script=<id>" }
            continue
        }

        $configPath = Resolve-ConfigPath -ScriptId $scriptId
        if ($null -eq $configPath) {
            Send-Json $res 403 @{ error = "script not allowed"; script = $scriptId; allowed = @($allowedScripts.Keys) }
            continue
        }

        # GET current config
        if ($method -eq "GET") {
            if (-not (Test-Path -LiteralPath $configPath)) {
                Write-FileError -Path $configPath -Reason "file does not exist"
                Send-Json $res 404 @{ error = "config not found"; path = $configPath; reason = "file does not exist" }
                continue
            }
            try {
                $content = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
                Send-Json $res 200 $content
            } catch {
                Write-FileError -Path $configPath -Reason $_.Exception.Message
                Send-Json $res 500 @{ error = "read failed"; path = $configPath; reason = $_.Exception.Message }
            }
            continue
        }

        # POST overwrite
        if ($method -eq "POST") {
            if ($hasToken) {
                $sent = $req.Headers["X-Bridge-Token"]
                if ($sent -ne $Token) {
                    Send-Json $res 401 @{ error = "invalid X-Bridge-Token" }
                    continue
                }
            }

            $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
            $body   = $reader.ReadToEnd()
            $reader.Close()

            # Validate JSON before writing
            try {
                $parsed = $body | ConvertFrom-Json -ErrorAction Stop
                $null   = $parsed
            } catch {
                Send-Json $res 400 @{ error = "invalid JSON body"; reason = $_.Exception.Message }
                continue
            }

            # Backup existing file alongside
            try {
                if (Test-Path -LiteralPath $configPath) {
                    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
                    $backup = "$configPath.$stamp.bak"
                    Copy-Item -LiteralPath $configPath -Destination $backup -Force
                }
            } catch {
                Write-FileError -Path $configPath -Reason ("backup failed: " + $_.Exception.Message)
                Send-Json $res 500 @{ error = "backup failed"; path = $configPath; reason = $_.Exception.Message }
                continue
            }

            try {
                $dir = Split-Path -Parent $configPath
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                Set-Content -LiteralPath $configPath -Value $body -Encoding UTF8 -NoNewline
                Write-Host ("    [OK] wrote {0} ({1} bytes)" -f $configPath, $body.Length) -ForegroundColor Green
                Send-Json $res 200 @{ ok = $true; path = $configPath; bytes = $body.Length }
            } catch {
                Write-FileError -Path $configPath -Reason $_.Exception.Message
                Send-Json $res 500 @{ error = "write failed"; path = $configPath; reason = $_.Exception.Message }
            }
            continue
        }

        # PATCH /config?script=ID            -> deep-merge partial options
        # POST  /config/options?script=ID    -> same, friendly alias
        $isMerge = ($method -eq "PATCH") -or ($method -eq "POST" -and $isOptionsRoute)
        if ($isMerge) {
            if ($hasToken) {
                $sent = $req.Headers["X-Bridge-Token"]
                if ($sent -ne $Token) {
                    Send-Json $res 401 @{ error = "invalid X-Bridge-Token" }
                    continue
                }
            }

            $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
            $body   = $reader.ReadToEnd()
            $reader.Close()

            if ([string]::IsNullOrWhiteSpace($body)) {
                Send-Json $res 400 @{ error = "empty body"; reason = "expected JSON object of options to merge" }
                continue
            }

            try {
                $patch = $body | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Send-Json $res 400 @{ error = "invalid JSON body"; reason = $_.Exception.Message }
                continue
            }

            if (-not ($patch -is [psobject]) -or ($patch -is [Array])) {
                Send-Json $res 400 @{ error = "patch must be a JSON object" }
                continue
            }

            # Load existing config (or start empty if missing)
            $current = $null
            if (Test-Path -LiteralPath $configPath) {
                try {
                    $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $current = $raw | ConvertFrom-Json -ErrorAction Stop
                    }
                } catch {
                    Write-FileError -Path $configPath -Reason ("read/parse failed: " + $_.Exception.Message)
                    Send-Json $res 500 @{ error = "stored config unreadable"; path = $configPath; reason = $_.Exception.Message }
                    continue
                }
            }
            if ($null -eq $current) { $current = [pscustomobject]@{} }

            $merged     = Merge-Config -Base $current -Patch $patch
            $mergedJson = $merged | ConvertTo-Json -Depth 32

            try {
                Save-ConfigJson -Path $configPath -Json $mergedJson
                Write-Host ("    [OK] merged options into {0} ({1} bytes)" -f $configPath, $mergedJson.Length) -ForegroundColor Green
                Send-Json $res 200 @{
                    ok     = $true
                    path   = $configPath
                    bytes  = $mergedJson.Length
                    config = $merged
                }
            } catch {
                Write-FileError -Path $configPath -Reason $_.Exception.Message
                Send-Json $res 500 @{ error = "write failed"; path = $configPath; reason = $_.Exception.Message }
            }
            continue
        }

        Send-Json $res 405 @{ error = "method not allowed"; method = $method }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
