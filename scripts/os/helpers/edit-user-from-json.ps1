<#
.SYNOPSIS
    os edit-user-json -- Bulk-edit local Windows users from a JSON file.

.DESCRIPTION
    Mirrors scripts-linux/68-user-mgmt/edit-user-from-json.sh. Each record
    is applied IN-PROCESS via Invoke-UserModify (defined in helpers/_common.ps1)
    rather than forking edit-user.ps1 per row -- this drops ~200ms of PS
    startup per record and keeps a single Save-LogFile roll-up at the end.

    Shapes (auto-detected):
      1. Single object:   { "name": "alice", "rename": "alyssa", ... }
      2. Array:           [ { ... }, { ... } ]
      3. Wrapped:         { "users": [ ... ] }

    Per-record schema (verbatim from readme.md "Bulk edit / remove";
    every field optional except 'name'):
      name          string    REQUIRED -- account to edit
      rename        string    --rename <newName>
      password      string    --reset-password (visible in process listing)
      passwordFile  string    --password-file (mode 0600 or stricter; ignored on Windows)
      promote       bool      --promote (add to sudo/admin -- 'Administrators' on Windows)
      demote        bool      --demote (remove from sudo/admin -- 'Administrators' on Windows)
      addGroups     string[]  --add-group (one per array entry)
      removeGroups  string[]  --remove-group (one per array entry)
      shell         string    --shell <PATH> (accepted but no-op on Windows; logged info)
      comment       string    --comment "..." (may be empty string to clear GECOS / FullName)
      enable        bool      --enable (unlock the account)
      disable       bool      --disable (lock the account)

    Mutually-exclusive intents (e.g. promote+demote, enable+disable) are
    rejected up front so a half-applied batch is impossible.

    JSON examples (each record below would pass schema validation):
      // 1) minimal single object (rename only)
      { "name": "alice", "rename": "alyssa" }

      // 2) array exercising most fields (no mutex violations)
      [
        { "name": "alice", "rename": "alyssa", "comment": "Alyssa P. Hacker" },
        { "name": "bob",   "promote": true,
          "addGroups":    ["docker","dev"],
          "removeGroups": ["video"] },
        { "name": "carol", "demote": true,  "disable": true },
        { "name": "dave",  "passwordFile": "C:\\secrets\\dave.pw", "enable": true }
      ]

      // 3) wrapped (legal at the top level only)
      { "users": [ { "name": "alice", "rename": "alyssa" } ] }

      // 4) REJECTED -- mutex violation (promote + demote both true)
      { "name": "eve", "promote": true, "demote": true }

    Removing a missing user / no-op records produce a [WARN] line but do not
    fail the batch. Exit 0 if every record succeeded, 1 if any failed.

    Usage:
      .\run.ps1 os edit-user-json <file.json> [--dry-run]

    Dry-run effect per JSON field (with --dry-run, every record is
    validated + planned but no host mutation occurs. Each field maps to
    a single Invoke-UserModify call which logs "[dry-run] <command>"
    with the resolved arguments. Schema validation -- including mutex
    checks -- ALWAYS runs.):
      name          would resolve the account; missing user -> [FAIL] +
                    record marked failed; loader continues with the next row
      rename        would call Rename-LocalUser -Name <name> -NewName
                    <newName>; applied LAST so other ops still target the
                    original name
      password      would call Set-LocalUser -Password <masked>; value
                    NEVER logged
      passwordFile  IGNORED on Windows (Linux/macOS only; no log line)
      promote       would call Add-LocalGroupMember -Group Administrators
      demote        would call Remove-LocalGroupMember -Group Administrators
      addGroups     one Add-LocalGroupMember call per array entry
      removeGroups  one Remove-LocalGroupMember call per array entry
      shell         no-op on Windows; logged at INFO ("would set shell
                    PATH (no Windows equivalent)")
      comment       would call net.exe user <name> /comment:"..."; empty
                    string CLEARS the field
      enable        would call Enable-LocalUser -Name <name>
      disable       would call Disable-LocalUser -Name <name>

    Loader-level dry-run notes:
      - Mutex violations (promote+demote, enable+disable) are rejected by
        the validator BEFORE any record runs, so a half-applied batch is
        impossible.
      - Records with zero applicable changes log [WARN] and are skipped;
        the loader still exits 0 if every other record was ok.
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv = @())

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $helpersDir "_common.ps1")

$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages
Initialize-Logging -ScriptName "Edit User (JSON)"

# ---- Parse args ----
$jsonPath = $null; $hasDryRun = $false
foreach ($a in $Argv) {
    if ($a -eq "--dry-run") { $hasDryRun = $true; continue }
    if ($a -like "--*") {
        Write-Log "Unknown flag: '$a'" -Level "fail"; Save-LogFile -Status "fail"; exit 64
    }
    if (-not $jsonPath) { $jsonPath = $a }
}

if (-not $jsonPath) {
    Write-Log "Missing <file.json>. Usage: .\run.ps1 os edit-user-json <file.json> [--dry-run]" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}
if (-not (Test-Path -LiteralPath $jsonPath)) {
    Write-Log "JSON file not found. Path: $jsonPath. Reason: file does not exist or is not accessible." -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$raw = $null
try { $raw = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop }
catch {
    Write-Log "Failed to read JSON. Path: $jsonPath. Reason: $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

$parsed = $null
try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop }
catch {
    Write-Log "Invalid JSON. Path: $jsonPath. Reason: $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

# Normalise shapes -> array of records.
$entries = @()
if ($parsed -is [System.Array]) {
    $entries = @($parsed)
} elseif ($parsed.PSObject.Properties.Name -contains "users") {
    $entries = @($parsed.users)
} elseif ($parsed.PSObject.Properties.Name -contains "name") {
    $entries = @($parsed)
} else {
    Write-Log "Unknown JSON shape. Path: $jsonPath. Reason: must be a single object, an array, or { users: [...] }." -Level "fail"
    Save-LogFile -Status "fail"; exit 2
}

if ($entries.Count -eq 0) {
    Write-Log "No edit records found in '$jsonPath'." -Level "warn"
    Save-LogFile -Status "ok"; exit 0
}

# ---- Admin elevation (skip in dry-run; no host mutation) ----
if (-not $hasDryRun) {
    $forwardArgs = @($jsonPath)
    $isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
    if (-not $isAdminOk) { Save-LogFile -Status "fail"; exit 1 }
}

Write-Host ""
Write-Host "  Bulk edit-user from: $jsonPath  ($($entries.Count) records)" -ForegroundColor Cyan
if ($hasDryRun) { Write-Host "  Mode: DRY-RUN (no host mutation)" -ForegroundColor Yellow }
Write-Host ""

function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $names = @()
    try { $names = $Obj.PSObject.Properties.Name } catch { return $null }
    if ($names -contains $Name) { return $Obj.$Name }
    return $null
}

$failCount = 0; $okCount = 0
$idx = 0
foreach ($e in $entries) {
    $idx++
    $name = Get-Prop $e "name"
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Log "Record #${idx}: missing 'name' (skipped). Path: $jsonPath" -Level "fail"
        $failCount++
        continue
    }

    $rename       = Get-Prop $e "rename"
    $password     = Get-Prop $e "password"
    $promote      = [bool](Get-Prop $e "promote")
    $demote       = [bool](Get-Prop $e "demote")
    $isEnable     = [bool](Get-Prop $e "enable")
    $isDisable    = [bool](Get-Prop $e "disable")
    $shellVal     = Get-Prop $e "shell"
    $hasComment   = ($null -ne (Get-Prop $e "comment")) -or (($e.PSObject.Properties.Name) -contains "comment")
    $commentVal   = if ($hasComment) { [string](Get-Prop $e "comment") } else { $null }
    $addGroups    = @()
    $removeGroups = @()
    $ag = Get-Prop $e "addGroups";    if ($ag) { $addGroups = @($ag) }
    $rg = Get-Prop $e "removeGroups"; if ($rg) { $removeGroups = @($rg) }

    if ($promote -and $demote) {
        Write-Log "Record #${idx} '$name': both promote+demote set (skipped, mutually exclusive)" -Level "fail"
        $failCount++; continue
    }
    if ($isEnable -and $isDisable) {
        Write-Log "Record #${idx} '$name': both enable+disable set (skipped, mutually exclusive)" -Level "fail"
        $failCount++; continue
    }
    if ($promote) { $addGroups    += "Administrators" }
    if ($demote)  { $removeGroups += "Administrators" }

    # Plan banner (mirrors edit-user.ps1 wording).
    $planLines = @()
    if ($rename)           { $planLines += "rename '$name' -> '$rename'" }
    if ($password)         { $planLines += "reset password (masked: $(Mask-Password -Pw $password))" }
    if ($promote)          { $planLines += "promote (add to Administrators)" }
    if ($demote)           { $planLines += "demote (remove from Administrators)" }
    if ($addGroups.Count)  { $planLines += "add groups: $($addGroups -join ', ')" }
    if ($removeGroups.Count){ $planLines += "remove groups: $($removeGroups -join ', ')" }
    if ($shellVal)         { $planLines += "set shell: $shellVal (no-op on Windows)" }
    if ($hasComment)       { $planLines += "set comment: '$commentVal'" }
    if ($isEnable)         { $planLines += "enable account" }
    if ($isDisable)        { $planLines += "disable account" }

    if (-not $planLines.Count) {
        Write-Log "Record #${idx} '$name': no changes requested -- skipping (only 'name' present)" -Level "warn"
        continue
    }

    Write-Host "  --- Record ${idx}/$($entries.Count): edit '$name' ---" -ForegroundColor DarkCyan
    foreach ($p in $planLines) { Write-Host "    - $p" -ForegroundColor Gray }

    # Existence probe (skipped in dry-run because elevation is also skipped
    # and the JSON loader is allowed to dry-plan accounts that don't exist yet).
    if (-not $hasDryRun) {
        $exists = $null
        try { $exists = Get-LocalUser -Name $name -ErrorAction Stop } catch {}
        if (-not $exists) {
            Write-Log "Record #${idx} '$name': user does not exist -- nothing to edit (failure: create with add-user first). Path: HKLM:\SAM (local users)" -Level "fail"
            $failCount++; continue
        }
    }

    $recFailed = 0
    if ($password)     { if (-not (Invoke-UserModify -Name $name -Op 'password' -Value $password -DryRun:$hasDryRun)) { $recFailed++ } }
    if ($shellVal)     { if (-not (Invoke-UserModify -Name $name -Op 'shell'    -Value $shellVal -DryRun:$hasDryRun)) { $recFailed++ } }
    if ($hasComment)   { if (-not (Invoke-UserModify -Name $name -Op 'comment'  -Value $commentVal -DryRun:$hasDryRun)) { $recFailed++ } }
    if ($isEnable)     { if (-not (Invoke-UserModify -Name $name -Op 'enable'   -DryRun:$hasDryRun)) { $recFailed++ } }
    if ($isDisable)    { if (-not (Invoke-UserModify -Name $name -Op 'disable'  -DryRun:$hasDryRun)) { $recFailed++ } }

    foreach ($g in ($addGroups | Where-Object { $_ })) {
        if (-not (Invoke-UserModify -Name $name -Op 'add-group' -Value ([string]$g) -DryRun:$hasDryRun)) { $recFailed++ }
    }
    foreach ($g in ($removeGroups | Where-Object { $_ })) {
        if (-not (Invoke-UserModify -Name $name -Op 'rm-group' -Value ([string]$g) -DryRun:$hasDryRun)) { $recFailed++ }
    }

    # Rename LAST so all prior ops referenced the original name.
    if ($rename) {
        if (-not (Invoke-UserModify -Name $name -Op 'rename' -Value $rename -DryRun:$hasDryRun)) { $recFailed++ }
    }

    if ($recFailed -eq 0) { $okCount++ } else { $failCount++ }
}

Write-Host ""
Write-Host "  Bulk edit-user summary: $okCount ok, $failCount fail (of $($entries.Count))" -ForegroundColor Cyan
Write-Host ""
$status = if ($failCount -eq 0) { "ok" } else { "fail" }
Save-LogFile -Status $status
if ($failCount -eq 0) { exit 0 } else { exit 1 }