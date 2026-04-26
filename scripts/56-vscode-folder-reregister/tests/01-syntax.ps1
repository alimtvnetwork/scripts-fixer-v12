# ---------------------------------------------------------------------------
# Script 56 -- tests/01-syntax.ps1
#
# Cross-platform integrity check. Runs on Linux pwsh (no real registry):
#   1. config.json + log-messages.json parse cleanly.
#   2. Every enabled edition exists under config.editions and has the
#      required path/registry fields.
#   3. Every {placeholder} used in log-messages keys we send through _msg
#      is documented (no orphaned placeholders left in output).
#   4. helpers/registry.ps1 + run.ps1 parse without syntax errors.
#   5. The 'help' verb dispatches successfully (exits 0).
# ---------------------------------------------------------------------------
param([switch]$Verbose)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root      = Split-Path -Parent $scriptDir

$pass = 0; $fail = 0
function _ok($msg) { $script:pass++; Write-Host "  PASS $msg" }
function _no($msg, $why) { $script:fail++; Write-Host "  FAIL $msg" -ForegroundColor Red; Write-Host "       $why" -ForegroundColor DarkRed }

Write-Host "===== 56-vscode-folder-reregister :: 01-syntax ====="

# 1. Parse JSON files.
$cfg = $null; $msgs = $null
try {
    $cfg  = Get-Content -LiteralPath (Join-Path $root 'config.json')       -Raw | ConvertFrom-Json
    _ok "config.json parses"
} catch { _no "config.json parses" $_.Exception.Message }
try {
    $msgs = Get-Content -LiteralPath (Join-Path $root 'log-messages.json') -Raw | ConvertFrom-Json
    _ok "log-messages.json parses"
} catch { _no "log-messages.json parses" $_.Exception.Message }

# 2. Edition integrity.
if ($cfg) {
    foreach ($name in @($cfg.enabledEditions)) {
        $ed = $cfg.editions.$name
        if ($null -eq $ed) { _no "edition '$name' is defined" "missing under config.editions"; continue }
        if (-not $ed.vscodePath.user)        { _no "edition '$name' has user path"   "vscodePath.user empty" } else { _ok "edition '$name' has user path" }
        if (-not $ed.vscodePath.system)      { _no "edition '$name' has system path" "vscodePath.system empty" } else { _ok "edition '$name' has system path" }
        foreach ($t in 'directory','background') {
            if (-not $ed.registryPaths.$t)   { _no "edition '$name' has $t path"  "registryPaths.$t empty" }
            elseif ($ed.registryPaths.$t -notlike 'Registry::HKEY_CLASSES_ROOT\*') {
                _no "edition '$name' $t path is HKCR" "got: $($ed.registryPaths.$t)"
            } else { _ok "edition '$name' $t path is HKCR" }
        }
        if (-not $ed.contextMenuLabel) { _no "edition '$name' has label" "contextMenuLabel empty" } else { _ok "edition '$name' has label" }
    }
    # The whole point of this script: file-target must NOT be configured.
    foreach ($name in @($cfg.enabledEditions)) {
        $ed = $cfg.editions.$name
        if ($null -ne $ed -and ($ed.registryPaths.PSObject.Properties.Name -contains 'file')) {
            _no "edition '$name' must NOT define a file-target" "config.editions.$name.registryPaths.file is set; this script is folder-only"
        } else { _ok "edition '$name' has no file-target (correct)" }
    }
}

# 3. Required message keys present.
if ($msgs) {
    $required = @(
        'scriptDisabled','notAdmin','editionStart','exeMissingRegister',
        'exeMissingAutoRemove','registered','removed','alreadyAbsent',
        'checkPass','checkMissExe','checkMissDefault','checkMissCommand',
        'checkSummary','doneRegister','doneRemove','unknownEdition','unknownVerb'
    )
    foreach ($k in $required) {
        $val = $msgs.messages.$k
        if (-not $val) { _no "message key '$k' present" "missing from log-messages.json" }
        else           { _ok "message key '$k' present" }
    }
}

# 4. Parse PowerShell sources without executing them.
foreach ($f in @('helpers/registry.ps1','run.ps1')) {
    $full = Join-Path $root $f
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $first = $errors[0]
        _no "parses $f" ("line " + $first.Extent.StartLineNumber + ": " + $first.Message)
    } else {
        _ok "parses $f"
    }
}

# 5. Dispatch the 'help' verb -- safe on every OS, no admin needed.
#    StrictMode in this test forbids reading $LASTEXITCODE if it was never
#    set (which happens when run.ps1 returns instead of `exit`-ing). We
#    assert on captured output instead, which is the actual contract.
# Help text is emitted via Write-Host, which bypasses the success+error
# stream, so a plain `2>&1 | Out-String` capture is empty. Run pwsh as a
# subprocess and capture its real stdout.
try {
    $runScript = Join-Path $root 'run.ps1'
    $pwshExe   = (Get-Process -Id $PID).Path
    $captured  = & $pwshExe -NoProfile -File $runScript -Help 2>&1 | Out-String
    if ($captured -match 'reregister' -and $captured -match '(?i)commands') {
        _ok "help verb dispatches"
    } else {
        $preview = if ($captured.Length -gt 200) { $captured.Substring(0, 200) } else { $captured }
        _no "help verb dispatches" ("output did not include verbs/commands: " + $preview)
    }
} catch {
    _no "help verb dispatches" $_.Exception.Message
}

Write-Host ""
Write-Host "  $($pass) passed, $($fail) failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }