# 12 -- Profile-Based Installations

**Type**: new dispatcher + 5 profile recipes
**Folder**: `scripts/profile/`
**Invocation**: BOTH (per locked decision):
- Keywords: `.\run.ps1 install profile-base`, `.\run.ps1 install profile-advance`, etc.
- Subcommand: `.\run.ps1 profile base`, `.\run.ps1 profile list`, `.\run.ps1 profile advance --dry-run`

## The 6 profiles

### 0. Minimal Bootstrap (`profile minimal`)
For a quick fresh-Windows bootstrap -- the absolute essentials plus the
Windows 11 classic right-click menu restore.

| Step | Action |
|------|--------|
| 1 | choco install (script 02) -- ensures package manager exists |
| 2 | Git (script 07) -- OS-dir |
| 3 | `choco install 7zip.install -y` (OS-dir) |
| 4 | `choco install googlechrome -y` (OS-dir) |
| 5 | Inline `Restore-Win11ClassicContext` -- writes HKCU CLSID `{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` (default = empty) on Win11 (build >= 22000); no-op on Win10 / Server. Idempotent. |

Use case: brand-new Windows machine where you only need a browser, an
archiver, git, and a package manager to bootstrap further work manually --
plus a usable right-click menu on Win11.

### 1. Base Windows Setup (`profile base`)
| Step | Action |
|------|--------|
| 1 | choco install (script 02) -- ensures package manager exists |
| 2 | Git (script 07) -- OS-dir |
| 3 | `choco install vlc -y` (OS-dir) |
| 4 | `choco install 7zip.install -y` (OS-dir) |
| 5 | `choco install winrar -y` (OS-dir) |
| 6 | Ubuntu Font (script 47) |
| 7 | `choco install xmind -y` (OS-dir) |
| 8 | Notepad++ + settings (script 33, mode `install+settings`) |
| 9 | `choco install googlechrome -y` (OS-dir) |
| 10 | ConEmu + settings (script 48, mode `install+settings`) |
| 11 | `powercfg.exe /hibernate off` (calls `os hib-off` helper) |
| 12 | `Install-Module PSReadLine -Force` (subdoc 11) |

### 2. Git Compact Install (`profile git-compact`)
| Step | Action |
|------|--------|
| 1 | Git (script 07) -- includes git-lfs in its config |
| 2 | GitHub Desktop (script 08) |
| 3 | SSH key prompt: ask user for an existing private key file path OR offer `ssh-keygen -t ed25519 -C "<email>"`. Place at `$HOME\.ssh\id_ed25519`. Print public key to console with copy hint. |
| 4 | Default GitHub dir prompt: default = `$HOME\GitHub`. Create if missing. Offer to scan it and clone-into GitHub Desktop (just creates the directory and prints instructions -- GitHub Desktop has no public CLI to add repos). |
| 5 | Apply default git config (see "Default git config" below) |

### 3. Advance Setup (`profile advance`)
- Includes everything from `profile base` + `profile git-compact`
- Additional: `choco install wordweb-free -y`, `choco install beyondcompare -y`
- OBS + settings (script 36, `install+settings`)
- WhatsApp (script 49)
- VSCode + Settings (scripts 01 + 11)

### 4. C++ + DirectX (`profile cpp-dx`)
- `choco install vcredist-all -y`
- `choco install directx -y`
- `choco install directx-sdk -y`
- All OS-dir.

### 5. Small Dev (`profile small-dev`)
- Includes everything from `profile advance`
- Adds:
  - Golang (script 06) -- default dir
  - Python (script 05) -- default dir
  - NodeJS (script 03) -- default dir
  - pnpm (script 04) -- default dir

## Default git config (applied during git-compact)

Save as `scripts/git-tools/templates/default-gitconfig.ini` and merge into `~\.gitconfig`:

```ini
[filter "lfs"]
    clean = git-lfs clean -- %f
    smudge = git-lfs smudge -- %f
    process = git-lfs filter-process
    required = true
[user]
    name = <prompt or default 'Alim Ul Karim'>
    email = <prompt>
[safe]
    directory = *
[url "ssh://git@gitlab.com/"]
    insteadOf = https://gitlab.com/
```

This **replaces** the per-key `git config` calls currently in `scripts/07-install-git/config.json` for the LFS/safe/url sections. Existing `gitConfig.userName`, `userEmail`, `defaultBranch`, `credentialManager`, `lineEndings`, `editor` blocks remain.

## Implementation

### `scripts/profile/run.ps1` (new dispatcher)
```powershell
param(
    [Parameter(Position=0)][string]$Action,
    [Parameter(ValueFromRemainingArguments=$true)]$Rest
)
. "$PSScriptRoot\..\shared\logging.ps1"
$validProfiles = @("base", "git-compact", "advance", "cpp-dx", "small-dev")
switch -Wildcard ($Action) {
    "list"    { Show-ProfileList; return }
    {$_ -in $validProfiles} {
        & "$PSScriptRoot\helpers\$Action.ps1" @Rest
        return
    }
    default { Show-ProfileHelp }
}
```

### Per-profile helper structure (`scripts/profile/helpers/<profile>.ps1`)
Each helper:
1. Initializes logging as `"Profile: <name>"`
2. Lists steps up-front (table view)
3. Supports `-DryRun` -- prints each step as `[DRYRUN] <step> (skipped)`
4. Runs each step via `Invoke-WithTimeout` and captures pass/fail per step
5. Emits a summary table at the end (12 rows, columns = step / status / elapsed)
6. Returns non-zero exit code if any step failed (but continues through all steps)

### Step composition

A step is one of:
- `{ kind: "script", id: 47 }` -- runs `scripts/registry[47]/run.ps1`
- `{ kind: "script", id: 33, mode: "install+settings" }` -- with mode flag
- `{ kind: "choco", package: "vlc" }` -- direct choco install
- `{ kind: "subcommand", path: "os hib-off" }` -- dispatches to root run.ps1
- `{ kind: "inline", function: "Install-PSReadLineLatest" }` -- calls a helper function

Steps live in `scripts/profile/config.json` for declarative editing:
```json
{
  "profiles": {
    "minimal": [
      { "kind": "script", "id": 2 },
      { "kind": "script", "id": 7 },
      { "kind": "choco", "package": "7zip.install" },
      { "kind": "choco", "package": "googlechrome" }
    ],
    "base": [
      { "kind": "script", "id": 2 },
      { "kind": "script", "id": 7 },
      { "kind": "choco", "package": "vlc" },
      { "kind": "choco", "package": "7zip.install" },
      { "kind": "choco", "package": "winrar" },
      { "kind": "script", "id": 47 },
      { "kind": "choco", "package": "xmind" },
      { "kind": "script", "id": 33, "mode": "install+settings" },
      { "kind": "choco", "package": "googlechrome" },
      { "kind": "script", "id": 48, "mode": "install+settings" },
      { "kind": "subcommand", "path": "os hib-off" },
      { "kind": "inline", "function": "Install-PSReadLineLatest" }
    ],
    "git-compact": [
      { "kind": "script", "id": 7 },
      { "kind": "script", "id": 8 },
      { "kind": "inline", "function": "Setup-SshKey" },
      { "kind": "inline", "function": "Setup-GitHubDir" },
      { "kind": "inline", "function": "Apply-DefaultGitConfig" }
    ],
    "advance": [
      { "kind": "profile", "name": "base" },
      { "kind": "profile", "name": "git-compact" },
      { "kind": "choco", "package": "wordweb-free" },
      { "kind": "choco", "package": "beyondcompare" },
      { "kind": "script", "id": 36, "mode": "install+settings" },
      { "kind": "script", "id": 49 },
      { "kind": "script", "id": 1 },
      { "kind": "script", "id": 11 }
    ],
    "cpp-dx": [
      { "kind": "choco", "package": "vcredist-all" },
      { "kind": "choco", "package": "directx" },
      { "kind": "choco", "package": "directx-sdk" }
    ],
    "small-dev": [
      { "kind": "profile", "name": "advance" },
      { "kind": "script", "id": 6 },
      { "kind": "script", "id": 5 },
      { "kind": "script", "id": 3 },
      { "kind": "script", "id": 4 }
    ]
  }
}
```

### Profile expansion

`{ "kind": "profile", "name": "base" }` expands recursively at runtime. Cycle detection via a visited set -- abort with CODE RED log if a cycle is found.

## Keyword wiring

```json
"profile-minimal":   ["profile:minimal"],
"profile-base":      ["profile:base"],
"profile-git":       ["profile:git-compact"],
"profile-advance":   ["profile:advance"],
"profile-cpp-dx":    ["profile:cpp-dx"],
"profile-small-dev": ["profile:small-dev"]
```

`"profile:<name>"` is a new keyword convention parsed by the install dispatcher -- it routes to `scripts/profile/run.ps1 <name>` instead of resolving to a script ID.

## Root dispatcher wiring (`run.ps1`)

```powershell
if ($Command -eq "profile") {
    & "$PSScriptRoot\scripts\profile\run.ps1" @Rest
    return
}
```

## Verification

```powershell
.\run.ps1 profile list
.\run.ps1 profile base --dry-run
.\run.ps1 profile small-dev --dry-run    # should expand advance -> base + git-compact
.\run.ps1 install profile-cpp-dx
```

## Open questions

- **GitHub Desktop CLI**: there is no supported way to programmatically add repos to GitHub Desktop. The git-compact step will create the GitHub dir and clone into it (if user provides repo URLs), then print "Open GitHub Desktop -> File -> Add Local Repository -> select <dir>". Acceptable per spec ("if there are repos, clear??" interpreted as "make it clear how to add them").
- **SSH key generation prompt UX**: simple text prompt with default = `id_ed25519`, comment defaults to git userEmail. Existing key detected -> ask "use existing / overwrite / skip". Implementation detail, not spec-blocking.

---

## Per-profile install location matrix (added v0.92.0)

The root README mirrors this table per profile. Keep them in sync. See
`mem://features/02-profile-install-locations`.

### Where things land

| Profile | C:\Program Files\* | C:\Program Files (x86)\* | %LOCALAPPDATA%\* | %APPDATA%\* | %USERPROFILE%\* | E:\dev-tool\* | Registry / system |
|---------|--------------------|--------------------------|------------------|-------------|-----------------|---------------|--------------------|
| minimal     | git, 7zip, chrome | -- | -- | -- | -- | -- | HKCU CLSID `{86ca1aa0-...}` (Win11 classic ctx) |
| base        | + vlc, winrar, npp, conemu | xmind | -- | npp + conemu settings | -- | -- | `powercfg /hibernate off` |
| git-compact | git | -- | GitHubDesktop | -- | `.ssh\id_ed25519`, `.gitconfig`, `GitHub\` | -- | -- |
| advance     | base + beyondcompare, obs | + wordweb-free | + WhatsApp, VS Code | + `Code\User` | inherits git-compact | -- | inherits |
| cpp-dx      | -- | DirectX SDK; runtime DLLs in `C:\Windows\System32` | -- | -- | -- | -- | -- |
| small-dev   | inherits advance | inherits | inherits | inherits | inherits | go, nodejs, python, pnpm | inherits |

### Rule for new steps

When adding a step to `scripts/profile/config.json`, update **all three**
in the same commit:
1. `scripts/profile/config.json`
2. This spec (per-profile table + the matrix above)
3. The matching profile section + global drive map in the root `readme.md`

If the install location is non-obvious (Choco flag override, env var,
per-user installer that ignores `Program Files`), add a "Why" note in the
README's per-profile table.
