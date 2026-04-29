<div align="center">

<img src="assets/icon-v1-rocket-stack.svg" alt="Dev Tools Setup Scripts" width="160" height="160"/>

# Dev Tools Setup Scripts

**Automated Windows development environment configuration**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://docs.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![Scripts](https://img.shields.io/badge/Scripts-51-22c55e?logo=files&logoColor=white)](scripts/)
[![Tools Installed](https://img.shields.io/badge/Tools-46%2B-8b5cf6?logo=tools&logoColor=white)](#what-it-does)
[![Databases](https://img.shields.io/badge/Databases-12-0ea5e9?logo=databricks&logoColor=white)](#databases-18-29)
[![License](https://img.shields.io/badge/License-MIT-eab308)](LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.219.0-f97316)](scripts/version.json)
[![AI Models](https://img.shields.io/badge/AI%20Models-90-ef4444?logo=huggingface&logoColor=white)](scripts/43-install-llama-cpp/models-list.md)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](changelog.md)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)](.github/workflows)
[![Maintained](https://img.shields.io/badge/Maintained-Yes-22c55e)](https://github.com/alimtvnetwork/scripts-fixer-v12)

*One command to set up your entire dev environment. No manual installs. No guesswork.*

</div>

---

## 🚀 Install

### 🪟 Windows · PowerShell

```powershell
irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex
```

### 🪟 Windows · PowerShell · skip latest-version probe

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1))) -NoUpgrade
```

### 🐧 macOS · Linux · Bash

```bash
curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash
```

### 🐧 macOS · Linux · Bash · skip latest-version probe

```bash
curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash -s -- --skip-latest-probe
```

If PowerShell blocks scripts, use a process-only bypass for the current shell first:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex
```

Or run the root installer inside a bypassed PowerShell process:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex"
```

After installation, use `./run.ps1 -d` on Windows or `bash scripts-linux/run.sh --list` on Unix / macOS for the toolkit menu.

---

## At a Glance

<table>
<tr>
<td width="33%" valign="top">

### 🚀 One-Liner Install
Bootstrap an entire Windows dev box with a single PowerShell or Bash command. No prior setup required.

</td>
<td width="33%" valign="top">

### 🧰 51 Modular Scripts
From VS Code, Git, Node, Python, Go, Rust, Docker and Kubernetes to 12 databases and local AI tools.

</td>
<td width="33%" valign="top">

### 🎛️ Interactive Menu
`run.ps1 -d` opens a grouped menu with CSV input, group shortcuts, and loop-back after each install.

</td>
</tr>
<tr>
<td width="33%" valign="top">

### 🔑 Keyword Install
`install nodejs,pnpm` or `install backend` — human-friendly keywords map to one or many scripts.

</td>
<td width="33%" valign="top">

### 🧠 Smart Dev Directory
Auto-detects best drive (E: > D: > most-free) and shares one `dev-tool\` root across every tool.

</td>
<td width="33%" valign="top">

### 🩹 Self-Healing
Audit mode, health checks, settings sync, context-menu repair, and CI-tested verification per script.

</td>
</tr>
</table>

---

## Demo / Showcase

> **One PowerShell entry point. Three commands. Hours of manual setup, gone.**
>
> These are real terminal sessions captured from the toolkit. From a fresh
> Windows box, you can apply a curated developer profile, stand up a full
> database server, or reclaim disk space — each with a single `run.ps1` call.
> No installer wizards, no copy-pasted Stack Overflow snippets, no version
> drift. The same script that works on your laptop works on a teammate's
> machine and on CI.

### 🎯 Apply a full developer profile

Bundles VS Code, Git, Notepad++/ConEmu/OBS with synced settings, GitHub
Desktop, WhatsApp, and a dozen more workstation tools — installed in
dependency order, idempotent, resumable. Add `dev` or `dev-advance` for
the language runtimes.

<p align="center">
  <img src="assets/demos/run-profile-advance.svg" alt="Demo: applying the 'advance' developer profile in one command" width="100%"/>
</p>

### 🗄️ Spin up a database server

Twelve databases supported (PostgreSQL, MySQL, MariaDB, MongoDB, Redis,
Cassandra, Neo4j, Elasticsearch, CouchDB, SQLite, DuckDB, LiteDB). Each
keyword resolves to a versioned installer with role/db bootstrap and a
post-install verification step.

<p align="center">
  <img src="assets/demos/run-install-postgresql.svg" alt="Demo: installing PostgreSQL with a single keyword" width="100%"/>
</p>

### 🧹 Reclaim disk space

Built-in OS toolbox cleans `%TEMP%`, the Windows update cache, and the
recycle bin in one pass — with a preview of what will be removed before
anything is deleted.

<p align="center">
  <img src="assets/demos/run-os-clean.svg" alt="Demo: running the os clean subcommand to reclaim disk space" width="100%"/>
</p>

> 💡 **Want to record your own?** The animated SVGs above are generated by
> [`assets/demos/build-demos.py`](assets/demos/build-demos.py) — edit the
> demo functions and re-run to update.

---

## 🎯 Profiles — Curated Multi-Tool Installs

Profiles are **named recipes** that bundle multiple installers into a
single command. Pick one and you get a curated environment — no script
IDs to remember, no order to figure out, no half-installed tools.

> 💡 **Where do these tools land?** Every profile's H3 section below has
> an **install location matrix** showing exactly which files end up on
> `C:\` (system installers via Chocolatey) versus `E:\dev-tool\` (dev
> runtimes that respect `$env:DEV_DIR`). Override the dev drive with
> `.\run.ps1 path D:\dev-tool` before running a profile.

### Profile cheat sheet

| Profile | One-liner | Tools | Steps | Best for |
|---------|-----------|:-----:|:-----:|---------|
| 🟢 [Minimal](#-profile-minimal) | `.\run.ps1 profile minimal -y` | 5 | 5 | Fresh Windows in 2 min |
| 🔵 [Base](#-profile-base) | `.\run.ps1 profile base -y` | 12 | 12 | Daily-driver workstation |
| 🟣 [Git-compact](#-profile-git-compact) | `.\run.ps1 profile git-compact -y` | 5 | 5 | Source-control box |
| 🟠 [Advance](#-profile-advance) | `.\run.ps1 profile advance -y` | 23 | 23 | Full creator setup (no langs) |
| 🔴 [C++ + DirectX](#-profile-cpp--directx) | `.\run.ps1 profile cpp-dx -y` | 3 | 3 | Game / native dev |
| 🟡 [Small Dev](#-profile-small-dev) | `.\run.ps1 profile small-dev -y` | 24 | 24 | advance + Go only |
| 🟢 [Dev](#-profile-dev) | `.\run.ps1 profile dev -y` | 29 | 29 | Polyglot dev box (Py/Node/pnpm/Rust/PHP) |
| 🟣 [Dev Advance](#-profile-dev-advance) | `.\run.ps1 profile dev-advance -y` | 33 | 33 | Polyglot + native (.NET + C++/DirectX) |

Source of truth: [`scripts/profile/config.json`](scripts/profile/config.json) ·
spec: [`spec/2025-batch/12-profiles.md`](spec/2025-batch/12-profiles.md).

### Profile commands (cheat sheet)

```powershell
# List every profile + its expanded steps
.\run.ps1 profile list

# Dry-run -- print expanded steps, execute nothing
.\run.ps1 profile advance  --dry-run
.\run.ps1 profile small-dev --dry-run        # expands advance -> base + git-compact + extras

# Run for real (skip per-step prompts with -y)
.\run.ps1 profile minimal     -y
.\run.ps1 profile base        -y
.\run.ps1 profile git-compact -y
.\run.ps1 profile advance     -y
.\run.ps1 profile cpp-dx      -y
.\run.ps1 profile small-dev   -y
.\run.ps1 profile dev         -y
.\run.ps1 profile dev-advance -y

# Same thing via the install keyword family
.\run.ps1 install profile-minimal
.\run.ps1 install profile-base
.\run.ps1 install profile-git              # alias for profile-git-compact
.\run.ps1 install profile-advance
.\run.ps1 install profile-cpp-dx
.\run.ps1 install profile-small-dev
.\run.ps1 install profile-dev
.\run.ps1 install profile-dev-advance
```

### Profile totals by destination

| Profile | Total steps | C:\ installs / writes | E:\dev-tool installs | User-profile writes | Registry / system changes |
|---------|:-----------:|------------------------|-----------------------|---------------------|---------------------------|
| `minimal` | 5 | Chocolatey, Git, 7-Zip, Chrome | — | — | Win11 classic context menu shim |
| `base` | 12 | Chocolatey, Git, VLC, 7-Zip, WinRAR, fonts, XMind, Notepad++, Chrome, ConEmu, PSReadLine | — | `%APPDATA%\Notepad++`, `%APPDATA%\ConEmu.xml`, `%USERPROFILE%\Documents\WindowsPowerShell\Modules\PSReadLine\` | Hibernation off |
| `git-compact` | 5 | Git | — | `%LOCALAPPDATA%\GitHubDesktop`, `%USERPROFILE%\.ssh`, `%USERPROFILE%\.gitconfig`, `%USERPROFILE%\GitHub\` | — |
| `advance` | 23 | Everything in `base` + WordWeb, Beyond Compare, OBS (**no langs**) | — | Everything in `git-compact` + `%LOCALAPPDATA%\WhatsApp`, `%LOCALAPPDATA%\Programs\Microsoft VS Code`, `%APPDATA%\Code\User`, `%APPDATA%\obs-studio\` | Inherits `base` system changes |
| `cpp-dx` | 3 | VC++ runtimes, DirectX runtime, DirectX SDK | — | — | System runtime DLL registration |
| `small-dev` | 24 | Everything in `advance` | **Go only** | Inherits `advance` | Inherits `advance` system changes |
| `dev` | 29 | Everything in `small-dev` | + Python, Node.js (+Yarn +Bun), pnpm, Rust, PHP | Inherits `small-dev` | Inherits `small-dev` |
| `dev-advance` | 33 | Everything in `dev` + VC++ runtimes, DirectX runtime, DirectX SDK, .NET SDK | Inherits `dev` | Inherits `dev` | Inherits `dev` + system runtime DLL registration |

---

### 🟢 Profile: minimal

**Fresh Windows in under two minutes.** Choco + Git + 7-Zip + Chrome,
plus the Windows 11 classic right-click menu restore (no more "Show more
options" submenu hiding VS Code, 7-Zip, etc.).

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile minimal -y
```

**What gets installed and where:**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1 | Chocolatey package manager | bootstrap | `C:\ProgramData\chocolatey\` | C:\ |
| 2 | Git + Git LFS + gh | script #07 (choco) | `C:\Program Files\Git\` | C:\ |
| 3 | 7-Zip archiver | choco `7zip.install` | `C:\Program Files\7-Zip\` | C:\ |
| 4 | Google Chrome | choco `googlechrome` | `C:\Program Files\Google\Chrome\` | C:\ |
| 5 | Win11 classic right-click menu | inline `Restore-Win11ClassicContext` | HKCU `Software\Classes\CLSID\{86ca1aa0-...}` | (registry) |

> 🪟 **Win11 only — Step 5.** The classic right-click shim is a
> well-known per-user (HKCU) registry tweak that makes Windows 11 stop
> hiding "Open with…", "Send to", VS Code, 7-Zip, etc. behind the "Show
> more options" submenu. Win10 / Server boxes simply skip this step.
> Restart Explorer afterwards: `Stop-Process -Name explorer -Force; Start-Process explorer`.

<p align="center">
  <img src="assets/demos/run-profile-minimal-classic.svg" alt="Demo: profile minimal — bootstrap + Win11 classic right-click menu restore" width="100%"/>
</p>

---

### 🔵 Profile: base

**Daily-driver Windows.** Package managers, media playback, archivers,
a fully-themed terminal, an editor, a font, XMind for mind-mapping, and
hibernation disabled to free `C:\hiberfil.sys`. Includes everything in
`minimal` plus media + ConEmu + Notepad++.

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile base -y
```

**What gets installed and where:**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1 | Chocolatey | script #02 | `C:\ProgramData\chocolatey\` | C:\ |
| 2 | Git + LFS + gh | script #07 (choco) | `C:\Program Files\Git\` | C:\ |
| 3 | VLC media player | choco `vlc` | `C:\Program Files\VideoLAN\VLC\` | C:\ |
| 4 | 7-Zip | choco `7zip.install` | `C:\Program Files\7-Zip\` | C:\ |
| 5 | WinRAR | choco `winrar` | `C:\Program Files\WinRAR\` | C:\ |
| 6 | Ubuntu font family | script #47 | `C:\Windows\Fonts\` (system) | C:\ |
| 7 | XMind | choco `xmind` | `C:\Program Files (x86)\XMind\` | C:\ |
| 8 | Notepad++ + settings | script #33 (`install+settings`) | `C:\Program Files\Notepad++\` + `%APPDATA%\Notepad++\` | C:\ |
| 9 | Google Chrome | choco `googlechrome` | `C:\Program Files\Google\Chrome\` | C:\ |
| 10 | ConEmu + settings | script #48 (`install+settings`) | `C:\Program Files\ConEmu\` + `%APPDATA%\ConEmu.xml` | C:\ |
| 11 | Disable hibernation | subcommand `os hib-off` | `powercfg /hibernate off` (frees `C:\hiberfil.sys`) | C:\ |
| 12 | PSReadLine (latest) | inline | `%USERPROFILE%\Documents\WindowsPowerShell\Modules\PSReadLine\` | C:\ |

> ℹ️ **No E:\dev-tool entries here.** `base` is purely OS hygiene + GUI
> apps. Dev runtimes (Node, Python, Go, pnpm) come in via `small-dev`.

**Total outcome after this profile finishes:**

- **12 steps applied**
- **C:\ only** for apps, fonts, and synced settings
- **0 tools on E:\dev-tool**
- **System tweaks included:** hibernation off, PSReadLine updated

<p align="center">
  <img src="assets/demos/run-profile-base.svg" alt="Demo: profile base — daily-driver Windows workstation profile" width="100%"/>
</p>

---

### 🟣 Profile: git-compact

**Source-control box.** Git + GitHub Desktop + an `ed25519` SSH key
(generated if missing) + a `~\GitHub` working directory + an opinionated
`.gitconfig` (LFS filters, `safe.directory = *`, GitLab `insteadOf`).

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile git-compact -y
```

**What gets installed and where:**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1 | Git + LFS + gh | script #07 (choco) | `C:\Program Files\Git\` | C:\ |
| 2 | GitHub Desktop | script #08 (per-user installer) | `%LOCALAPPDATA%\GitHubDesktop\` | C:\ |
| 3 | SSH key (ed25519) | inline `Setup-SshKey` | `%USERPROFILE%\.ssh\id_ed25519` | C:\ |
| 4 | Default GitHub dir | inline `Setup-GitHubDir` | `%USERPROFILE%\GitHub\` | C:\ |
| 5 | Default `.gitconfig` | inline `Apply-DefaultGitConfig` | `%USERPROFILE%\.gitconfig` | C:\ |

> 🔐 **SSH key flow.** If `~\.ssh\id_ed25519` already exists, it is
> reused (never overwritten). If not, `ssh-keygen -t ed25519` is run with
> the email pulled from `git config user.email` (fallback: `USER@HOST`).
> The public key is printed and copied to your clipboard so you can paste
> it into GitHub / GitLab / Bitbucket.

<p align="center">
  <img src="assets/demos/run-profile-git-compact.svg" alt="Demo: profile git-compact — git + ssh + GitHub dir + .gitconfig" width="100%"/>
</p>

---

### 🟠 Profile: advance

**Full creator + developer setup.** `base` + `git-compact` + WordWeb +
Beyond Compare + OBS (with synced settings) + WhatsApp Desktop + VS Code
+ VS Code settings sync. **23 steps end-to-end.**

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile advance -y
```

**What gets installed and where (full total):**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1 | Chocolatey package manager | bootstrap | `C:\ProgramData\chocolatey\` | C:\ |
| 2 | Git + Git LFS + gh | script #07 (choco) | `C:\Program Files\Git\` | C:\ |
| 3 | VLC media player | choco `vlc` | `C:\Program Files\VideoLAN\VLC\` | C:\ |
| 4 | 7-Zip archiver | choco `7zip.install` | `C:\Program Files\7-Zip\` | C:\ |
| 5 | WinRAR | choco `winrar` | `C:\Program Files\WinRAR\` | C:\ |
| 6 | Ubuntu font family | script #47 | `C:\Windows\Fonts\` | C:\ |
| 7 | XMind | choco `xmind` | `C:\Program Files (x86)\XMind\` | C:\ |
| 8 | Notepad++ + settings | script #33 (`install+settings`) | `C:\Program Files\Notepad++\` + `%APPDATA%\Notepad++\` | C:\ |
| 9 | Google Chrome | choco `googlechrome` | `C:\Program Files\Google\Chrome\` | C:\ |
| 10 | ConEmu + settings | script #48 (`install+settings`) | `C:\Program Files\ConEmu\` + `%APPDATA%\ConEmu.xml` | C:\ |
| 11 | Disable hibernation | subcommand `os hib-off` | `powercfg /hibernate off` | C:\ |
| 12 | PSReadLine (latest) | inline | `%USERPROFILE%\Documents\WindowsPowerShell\Modules\PSReadLine\` | C:\ |
| 13 | GitHub Desktop | script #08 (per-user installer) | `%LOCALAPPDATA%\GitHubDesktop\` | C:\ |
| 14 | SSH key (ed25519) | inline `Setup-SshKey` | `%USERPROFILE%\.ssh\id_ed25519` | C:\ |
| 15 | Default GitHub dir | inline `Setup-GitHubDir` | `%USERPROFILE%\GitHub\` | C:\ |
| 16 | Default `.gitconfig` | inline `Apply-DefaultGitConfig` | `%USERPROFILE%\.gitconfig` | C:\ |
| 17 | WordWeb dictionary | choco `wordweb-free` | `C:\Program Files (x86)\WordWeb\` | C:\ |
| 18 | Beyond Compare | choco `beyondcompare` | `C:\Program Files\Beyond Compare 4\` | C:\ |
| 19 | OBS Studio + settings | script #36 (`install+settings`) | `C:\Program Files\obs-studio\` + `%APPDATA%\obs-studio\` | C:\ |
| 20 | WhatsApp Desktop | script #49 | `%LOCALAPPDATA%\WhatsApp\` | C:\ |
| 21 | Visual Studio Code | script #01 | `%LOCALAPPDATA%\Programs\Microsoft VS Code\` | C:\ |
| 22 | VS Code settings sync | script #11 | `%APPDATA%\Code\User\` + extensions | C:\ |
> ✅ **Exact total:** `advance` currently applies **23 steps**, all on **C:\ / user profile paths**. It does **not** place anything in `E:\dev-tool\`.

> ℹ️ **About the classic right-click fix:** that Win11 registry tweak is part of `profile minimal`, not `base` / `advance`. If you want it too, run `profile minimal` first or expose it as a standalone helper later.

<p align="center">
  <img src="assets/demos/run-profile-advance.svg" alt="Demo: profile advance — full developer profile" width="100%"/>
</p>

---

### 🔴 Profile: cpp + directx

**Native / game dev runtime.** All Visual C++ redistributables + the
DirectX end-user runtime + the legacy DirectX SDK. Three Choco packages,
all system-drive.

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile cpp-dx -y
```

**What gets installed and where:**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1 | VC++ Redistributables (all years) | choco `vcredist-all` | `C:\Windows\System32\` (runtime DLLs) | C:\ |
| 2 | DirectX runtime | choco `directx` | `C:\Windows\System32\` (DX DLLs) | C:\ |
| 3 | DirectX SDK | choco `directx-sdk` | `C:\Program Files (x86)\Microsoft DirectX SDK\` | C:\ |

**Total outcome after this profile finishes:**

- **3 steps applied**
- **All files land on C:\ / system runtime folders**
- **0 tools on E:\dev-tool**
- Best when you need native game/runtime prerequisites without the rest of the workstation stack

<p align="center">
  <img src="assets/demos/run-profile-cpp-dx.svg" alt="Demo: profile cpp-dx — VC++ and DirectX runtime profile" width="100%"/>
</p>

---

### 🟡 Profile: small-dev

**`advance` + Go only.** A tight everyday box for someone who lives in
Go but still wants the full creator stack. Go is the **only step that
lands on E:\\dev-tool** — everything inherited from `advance` stays on
C:\\. Looking for Python / Node / pnpm / Rust / PHP too? Use
[`profile dev`](#-profile-dev) instead.

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile small-dev -y
```

**What gets installed and where (full total summary):**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1-23 | All of `profile advance` | recursive | _see full table above_ | C:\ |
| 24 | Go (Golang) | script #06 | `E:\dev-tool\go\` (GOPATH + cache) | **E:\\** |

> 🧠 **Why E: by default?** The dev-dir resolver picks the drive with
> the most free space (preferring `E:` then `D:`). If you only have `C:`,
> Go lands in `C:\dev-tool\go\` instead. Override anytime:
> `.\run.ps1 path F:\my-dev-tool` — then re-run the profile.

**Total outcome after this profile finishes:**

- **24 steps applied**
- **23 steps land on C:\ / profile folders**
- **1 runtime (Go) lands on E:\dev-tool\** by default
- Best choice when you want the full creator workstation **plus Go** without dragging in the rest of the polyglot stack

<p align="center">
  <img src="assets/demos/run-profile-small-dev.svg" alt="Demo: profile small-dev — advance + Go on E:\dev-tool" width="100%"/>
</p>

---

### 🟢 Profile: dev

**Polyglot daily-driver dev box.** `small-dev` + every runtime you
actually code in: Python + pip, Node.js (with Yarn and Bun bundled),
pnpm, Rust (rustup + cargo), PHP. **All five new runtimes land on
E:\\dev-tool** — everything inherited from `small-dev` (which already
includes `advance` + Go) stays where it was.

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile dev -y
```

**What gets installed and where (full total summary):**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1-24 | All of `profile small-dev` (= advance + Go) | recursive | _see tables above_ | C:\ + E:\dev-tool\go |
| 25 | Python + pip | script #05 | `E:\dev-tool\python\` (incl. PYTHONUSERBASE) | **E:\\** |
| 26 | Node.js + Yarn + Bun | script #03 | `E:\dev-tool\nodejs\` (npm global prefix; Yarn + Bun bundled) | **E:\\** |
| 27 | pnpm | script #04 | `E:\dev-tool\pnpm\` (pnpm store) | **E:\\** |
| 28 | Rust (rustup + cargo) | script #44 | `E:\dev-tool\rust\` (CARGO_HOME + RUSTUP_HOME) | **E:\\** |
| 29 | PHP | script #16 | `E:\dev-tool\php\` (PHP CLI + composer-ready) | **E:\\** |

> 🧠 **Why bundle Yarn + Bun with Node?** Script #03 already installs
> Yarn (via `corepack`) and Bun alongside Node — one step, three JS
> package managers (npm, yarn, bun) plus pnpm in step 27.

**Total outcome after this profile finishes:**

- **29 steps applied**
- **23 steps land on C:\ / profile folders** (everything inherited from `advance`)
- **6 runtimes land on E:\dev-tool\**: `go`, `python`, `nodejs` (+yarn+bun), `pnpm`, `rust`, `php`
- Best choice for a working polyglot dev box without native / .NET / DirectX

<p align="center">
  <img src="assets/demos/run-profile-dev.svg" alt="Demo: profile dev — polyglot daily-driver: small-dev + Python/Node/pnpm/Rust/PHP" width="100%"/>
</p>

---

### 🟣 Profile: dev-advance

**Everything-bagel dev box.** `dev` + `.NET SDK (C#)` + the entire
`cpp-dx` profile (VC++ runtimes + DirectX runtime + DirectX SDK).
Use this when you want one command that leaves you ready for **web,
systems, native, game, and .NET work** without any follow-up installs.

**Copy-paste one-liner:**

```powershell
.\run.ps1 profile dev-advance -y
```

**What gets installed and where (full total summary):**

| # | Tool | Source | Install location | Drive |
|:-:|------|--------|------------------|:-----:|
| 1-29 | All of `profile dev` (= small-dev + Py/Node/pnpm/Rust/PHP) | recursive | _see tables above_ | C:\ + E:\dev-tool\\* |
| 30 | .NET SDK (C#) | script #39 | `C:\Program Files\dotnet\` (system) | C:\ |
| 31 | VC++ Redistributables (all years) | choco `vcredist-all` | `C:\Windows\System32\` (runtime DLLs) | C:\ |
| 32 | DirectX runtime | choco `directx` | `C:\Windows\System32\` (DX DLLs) | C:\ |
| 33 | DirectX SDK | choco `directx-sdk` | `C:\Program Files (x86)\Microsoft DirectX SDK\` | C:\ |

> 🧱 **Native + managed in one shot.** Steps 30-33 are the same
> components as `profile cpp-dx` plus .NET SDK. They are appended to
> `dev` so a single command lands you with Go, Python, Node, pnpm,
> Rust, PHP, .NET, and the full VC++/DirectX stack.

**Total outcome after this profile finishes:**

- **33 steps applied**
- **6 runtimes on E:\dev-tool\** (inherited from `dev`)
- **.NET SDK + VC++ runtimes + DirectX runtime + DirectX SDK** added on C:\
- Best choice for a single one-liner that produces a "code anything tomorrow" box

<p align="center">
  <img src="assets/demos/run-profile-dev-advance.svg" alt="Demo: profile dev-advance — dev + .NET + cpp-dx, full polyglot + native stack" width="100%"/>
</p>

---

### 🧠 XMind — what happens when this toolkit installs it

XMind is **not a numbered script** — it ships as a single Choco step
inside `profile base` (and therefore `advance` / `small-dev`). It is
called out separately because it is the only commercial mind-mapper in
the bundle, and people often want to know exactly what the toolkit does
with it.

| Question | Answer |
|----------|--------|
| **Where does it install?** | `C:\Program Files (x86)\XMind\` (system drive — Choco does not honor `$env:DEV_DIR` for GUI installers) |
| **Which package?** | Chocolatey [`xmind`](https://community.chocolatey.org/packages/xmind) (the free / Zen edition) |
| **Does it auto-start?** | No. We never enable autostart. |
| **Is settings sync done?** | No. XMind has no `install+settings` mode in this toolkit. |
| **Where are user files?** | `%APPDATA%\XMind\` (project files), `%USERPROFILE%\Documents\XMind\` (default workspace) |
| **How to install just XMind?** | `choco install xmind -y` *or* `.\run.ps1 profile base -y` |
| **How to uninstall?** | `choco uninstall xmind -y` (the toolkit does not track XMind separately) |

> 🎯 **Want only XMind?** Skip the profile entirely:
> ```powershell
> choco install xmind -y
> ```
> The toolkit's profile path is only worth it if you also want the other
> 11 tools in `base`.

---

### ⌨️ Multi-tool install — comma-separated keywords

You don't have to use a profile to install several tools at once. The
`install` keyword command accepts **comma-separated names, ID ranges,
and even a mix of both** in a single line:

<p align="center">
  <img src="assets/demos/run-install-comma.svg" alt="Demo: typing one comma-separated install command and getting six tools in three minutes" width="100%"/>
</p>

**Big copy-paste one-liners — pick the row that matches your day:**

```powershell
# Front-end web dev (5 tools, ~3 min)
.\run.ps1 install vscode,git,nodejs,pnpm,npp

# Polyglot backend (7 tools, ~5 min)
.\run.ps1 install vscode,git,nodejs,python,go,php,postgresql

# 2025-batch desktop apps in one sweep (IDs 47..52)
.\run.ps1 install 47..52

# Mix & match: name + ID, in any order
.\run.ps1 install vscode,11,git,nodejs,33-settings

# Full data-science stack (Python + libs + DB + viewer)
.\run.ps1 install python+ml,jupyter+libs,postgresql,dbeaver

# All databases at once + DBeaver UI
.\run.ps1 install 18..29,dbeaver
```

Comma rules:
- **Case-insensitive** — `VSCode,GIT,NODEJS` works.
- **Space or comma** separators — both `vscode,git` and `vscode git` parse.
- **Auto-deduplicate** — `vscode,vscode,git` runs each step once.
- **Sorted execution** — runs in script-ID order, so `pnpm,nodejs` still installs Node.js first.
- **Keyword aliases** are expanded — see [`scripts/shared/install-keywords.json`](scripts/shared/install-keywords.json).

> 🧠 **Profile vs comma-install — when to use which?**
> Use a **profile** when you want a curated, opinionated environment
> (e.g. `small-dev`) with the right install order and inline helpers
> (SSH key, `.gitconfig`, etc.). Use **`install a,b,c`** when you know
> exactly the handful of tools you want and don't need the extras.

---

### 🧱 What goes where — combined drive map

Across **all** profiles, here's the global rule:

| Path | What lands here | Triggered by |
|------|------------------|--------------|
| `C:\Program Files\` | Most Choco packages (Git, VLC, 7-Zip, OBS, Beyond Compare, ConEmu, Notepad++) | `choco` steps in any profile |
| `C:\Program Files (x86)\` | XMind, WordWeb, DirectX SDK, WinRAR | `choco` steps in `base` / `advance` / `cpp-dx` |
| `C:\ProgramData\chocolatey\` | Choco itself + per-package shims | `script #02` (always step 1) |
| `%LOCALAPPDATA%\` | VS Code, GitHub Desktop, WhatsApp (per-user installers) | scripts #01, #08, #49 |
| `%APPDATA%\` | Notepad++ / OBS / ConEmu **settings** that get synced from `settings/` | `install+settings` modes |
| `%USERPROFILE%\.ssh\` | `id_ed25519` keypair (only if missing) | `git-compact` inline |
| `%USERPROFILE%\.gitconfig` | LFS filters, `safe.directory=*`, GitLab url rewrite | `git-compact` inline |
| `%USERPROFILE%\GitHub\` | Default working dir for GitHub Desktop | `git-compact` inline |
| `HKCU\Software\Classes\CLSID\{86ca1aa0-...}` | Win11 classic right-click menu shim | `minimal` inline |
| `E:\dev-tool\` (or smart-detected) | `go\`, `nodejs\`, `python\`, `pnpm\` | `small-dev` runtime steps |

Override the dev drive globally before running any profile:

```powershell
.\run.ps1 path D:\dev-tool       # set
.\run.ps1 path                   # show current
.\run.ps1 path --reset           # back to smart detection
```

> 🧠 **What's in each profile?** Open
> [`scripts/profile/config.json`](scripts/profile/config.json) — every step is
> declared as `{ kind: script|choco|subcommand|inline|profile, ... }`.
> Profiles compose other profiles (`small-dev` includes `advance` which
> includes `base` + `git-compact`), with cycle detection at runtime.

---

## 🤖 Local AI Models — 90 GGUFs + Ollama

Two backends, one orchestrator. Install local LLMs without juggling
Hugging Face URLs, RAM math, or quantization codes.

| Backend | Catalog | What it does | Entry point |
|---|---|---|---|
| **llama.cpp** | [`models-list.md`](scripts/43-install-llama-cpp/models-list.md) — **90 GGUF models, 33 families** | Hardware-aware picker. 4-filter chain (RAM → Size → Speed → Capability). Direct GGUF download + verify. | `.\run.ps1 install llama-cpp` |
| **Ollama** | [`config.json`](scripts/42-install-ollama/config.json) — daemon-managed pulls | Daemon-based pull/push. Slug install (`llama3.2`, `qwen2.5-coder`, `deepseek-r1:8b`). Auto-detects existing models on uninstall. | `.\run.ps1 install ollama` |

The catalog includes the **open-weight portion of the OpenRouter LLM
Leaderboard (Nov 2025)** — MiMo-V2-Flash, Qwen 3.6, DeepSeek V3.2,
MiniMax M2/M2.7, StepFun Step 3.5 Flash, NVIDIA Nemotron 3 Super 120B,
Z.AI GLM 5.1, Moonshot Kimi K2.6, OpenAI gpt-oss-120b. Closed-source
API models (Claude, GPT-5.4, Gemini, Grok) are intentionally excluded
because they cannot be downloaded as GGUF files.

### Quick install

```powershell
# Interactive picker — auto-detects RAM, walks 4 filters, multi-select
.\run.ps1 install llama-cpp

# Direct CSV install (skip filters, by id)
.\run.ps1 models qwen2.5-coder-3b,phi-4-mini-3.8b,gemma-3-4b-it

# Browse the full catalog without installing
.\run.ps1 models list llama

# Pick the Ollama backend instead
.\run.ps1 models -Backend ollama llama3.2,qwen2.5-coder,deepseek-r1:8b

# Search Ollama hub live
.\run.ps1 models search reasoning

# Remove installed models (works for both backends)
.\run.ps1 models uninstall llama
.\run.ps1 models uninstall ollama -Force
```

### What's in the catalog

- **90 models** across **33 families** (Qwen, Llama, Gemma, Phi, DeepSeek,
  Mistral, Granite, Codestral, StarCoder, CodeLlama, Whisper, Nemotron,
  GLM, MiniMax, Kimi, gpt-oss, MiMo, Step, …)
- **Capabilities tracked per model**: `isCoding`, `isReasoning`,
  `isWriting`, `isVoice`, `isMultilingual`, `isChat` + ratings 0-10 for
  coding / reasoning / speed / overall
- **Hardware metadata**: `fileSizeGB`, `ramRequiredGB`, `ramRecommendedGB`,
  `quantization`, `parameters`
- **9 datacenter-class models** (≥64 GB RAM) for workstation/server use:
  DeepSeek V3.2, Kimi K2.6, GLM 5.1, MiniMax M2 / M2.7, Nemotron 3 Super,
  gpt-oss-120b, Qwen 3.5 122B-A10B, DeepSeek R1 70B

👉 **Full table of every model with size, RAM, capabilities, license, and
download link**: [`scripts/43-install-llama-cpp/models-list.md`](scripts/43-install-llama-cpp/models-list.md)

---

## 🧹 OS Toolbox — Clean & Tweak Windows

The `os` subcommand family wraps Windows housekeeping tasks behind one
dispatcher: [`scripts/os/run.ps1`](scripts/os/run.ps1).

| Subcommand | What it does | Admin |
|------------|--------------|:-----:|
| `os clean` | Master cleaner: temp + Windows Update cache + chocolatey lib-bad/lib-bkp + recycle bin + event logs + PSReadLine history | 🛡️ Yes |
| `os clean --dry-run` | **Preview only** — scans every target and reports files + size, deletes nothing | 👤 No |
| `os clean-<category>` | Run a single category — 36 categories, e.g. `clean-chrome`, `clean-recycle`, `clean-obs-recordings`, `clean-chkdsk` (see `os --help`) | varies |
| `os hib-off` / `os hib-on` | `powercfg /hibernate off` (frees `C:\hiberfil.sys`, often 4-16 GB) | 🛡️ Yes |
| `os flp` | Fix long paths (`HKLM\SYSTEM\...\FileSystem\LongPathsEnabled = 1`) | 🛡️ Yes · 🔁 reboot |
| `os add-user` | Create a local Windows user account with sensible defaults | 🛡️ Yes |

### What `os clean` actually touches

All paths are declared in [`scripts/os/config.json`](scripts/os/config.json) —
nothing else is deleted.

| Target | Path | Why |
|--------|------|-----|
| User temp | `%TEMP%` | Per-user app debris, installer leftovers |
| LocalAppData temp | `%LOCALAPPDATA%\Temp` | Per-user app caches |
| Windows temp | `C:\Windows\Temp` | System-level installer/log scratch |
| Update cache | `C:\Windows\SoftwareDistribution\Download` | Already-applied Windows Update payloads |
| Choco quarantine | `C:\ProgramData\chocolatey\lib-bad`, `lib-bkp` | Failed/orphaned package backups |
| Choco temp | `%TEMP%\chocolatey` | Mid-install scratch |
| Recycle Bin | All drives | Standard empty-recycle-bin |
| Event logs | Application/System/Security | Cleared via `wevtutil cl` |
| PSReadLine history | `~\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt` | Shell command history |

<p align="center">
  <img src="assets/demos/run-os-clean-detailed.svg" alt="Demo: os clean --dry-run — preview reclaimable disk space across temp/cache/recycle folders" width="100%"/>
</p>

### OS commands

```powershell
# Always preview first
.\run.ps1 os clean --dry-run

# Real run (asks for confirmation per target)
.\run.ps1 os clean

# Skip specific categories
.\run.ps1 os clean --skip recycle,ms-search

# Single-category cleans (no prompts, scoped)
.\run.ps1 os clean-chrome
.\run.ps1 os clean-recycle --yes
.\run.ps1 os clean-obs-recordings --days 7 --dry-run

# Other os tasks
.\run.ps1 os hib-off          # disable hibernation, free hiberfil.sys
.\run.ps1 os flp              # enable Win32 long paths (HKLM, reboot recommended)
.\run.ps1 os add-user         # create a local user

# Help
.\run.ps1 os --help           # shows every action incl. the 36 clean-* categories
```

---

## 🔬 How to verify any script

Don't hand-roll registry probes per script. Every installer ships a built-in
`verify` subcommand that runs the same checks the script ran post-install
(binary on PATH, registry values, settings file present, etc.) and prints a
structured PASS/FAIL summary -- no walls of `Test-Path` / `Get-ItemProperty`
in this README.

```powershell
# Verify a single script (by ID or by keyword)
.\run.ps1 -I 47 verify
.\run.ps1 verify ubuntu-font

# Verify a batch (one row per script, non-zero exit on any FAIL)
.\run.ps1 verify 47..52
.\run.ps1 verify 2025-batch

# Verify everything that's been installed (reads .resolved/installed/)
.\run.ps1 verify --all

# Machine-readable output for CI / dashboards
.\run.ps1 verify --all --json > .resolved\verify-report.json
```

Each script owns its own check list -- never duplicated here:

- **Logic** -> `scripts/<NN>-*/helpers/<name>.ps1` exposes `Test-<Name>Install`,
  called by both `install` (post-step) and `verify` (standalone).
- **Expected values + remediation hints** -> `scripts/<NN>-*/log-messages.json`
  under `verify.checks[]` / `verify.failHints[]`.
- **Last run's evidence** -> `.resolved\logs\latest-<NN>.json` records every
  probed path/key + failure reason (CODE RED rule).

If a check fails: open the matching `latest-<NN>.json`, fix what it points
at, then re-run `.\run.ps1 -I <NN> verify`. All `verify` runs are read-only
and need no admin for HKCU / file-existence checks.

### 🛠️ VS Code folder context-menu repair

Use the root dispatcher only. The root README should document root commands,
not direct script paths or manual registry editing.

| Subcommand   | What it does                                                          |
| ------------ | --------------------------------------------------------------------- |
| *(default)*  | Folder-only repair + Explorer restart                                 |
| `dry-run`    | Preview the repair — no registry writes, no snapshots                 |
| `no-restart` | Repair but skip the `explorer.exe` restart                            |
| `trace`      | Repair with `-VerboseRegistry` registry trace                         |
| `verify`     | Dry-run + trace — verify state without writing                        |
| `restore`    | Re-import the newest `BEFORE` snapshot for the chosen edition         |
| `rollback`   | Restore the **default installer entries** on all 3 targets            |
| `refresh`    | Minimum-components shell refresh after a repair (no `explorer.exe` kill); add `--restart` for full fallback |
| `help`       | Show help and examples                                                |

Common flags accepted by every subcommand: `-Edition stable|insiders`,
`-SnapshotDir <path>`, `-RequireSignature`, `-NonInteractive`,
`-RestoreFromFile <path>` (for `restore`).

#### Edition selection (Stable vs Insiders)

The repair targets a specific VS Code build. Pick one with `-Edition`:

| Edition    | Target executable                                                | Registry key suffix | Menu label                  |
| ---------- | ---------------------------------------------------------------- | ------------------- | --------------------------- |
| `stable`   | `Code.exe` (default install)                                     | `VSCode`            | **Open with Code**          |
| `insiders` | `Code - Insiders.exe`                                            | `VSCodeInsiders`    | **Open with Code - Insiders** |

- **Auto-detect (default)**: omit `-Edition` and the script picks whichever
  edition is installed. If both are installed, **Stable wins** unless you
  pass `-Edition insiders` explicitly.
- **Force one**: `-Edition stable` or `-Edition insiders` skips detection
  and operates only on that build's three registry targets
  (`*\shell\<key>`, `Directory\shell\<key>`, `Directory\Background\shell\<key>`).
- **Both side-by-side**: run the command twice — once per edition. Each run
  writes its own `BEFORE` snapshot under `-SnapshotDir`, so `restore` /
  `rollback` stay independent per edition.
- **CI / unattended**: `-NonInteractive` defaults to `stable` when no
  edition is passed and no edition can be detected.
- **Settings page**: the React app at `/settings` lets you pick the edition
  visually and download a merged `config.json` you can drop into
  `scripts/52-vscode-folder-repair/`.


```powershell
# Default: auto-detect edition, repair, restart Explorer
.\run.ps1 vscode-folder

# Dry-run first (no writes, no snapshots)
.\run.ps1 vscode-folder dry-run

# Real run, Stable, with Authenticode signer check
.\run.ps1 vscode-folder repair -Edition stable -RequireSignature

# CI / unattended (defaults to 'stable', no prompt)
.\run.ps1 vscode-folder repair -NonInteractive

# Verbose registry trace
.\run.ps1 vscode-folder trace

# Verify final state without touching anything
.\run.ps1 vscode-folder verify

# Insiders, custom snapshot folder, skip Explorer restart
.\run.ps1 vscode-folder no-restart -Edition insiders -SnapshotDir 'D:\snapshots\vscode-menu'

# Undo the repair by re-importing the newest BEFORE snapshot
.\run.ps1 vscode-folder restore

# Restore from an explicit snapshot file
.\run.ps1 vscode-folder restore -Edition insiders `
    -RestoreFromFile 'D:\snapshots\vscode-menu\vscode-menu-insiders-BEFORE-20260422-143012.reg'

# Inverse: restore the default installer entries on all 3 targets
.\run.ps1 vscode-folder rollback

# Minimum-components shell refresh (no explorer.exe restart)
.\run.ps1 vscode-folder refresh

# Same, plus a full explorer.exe restart fallback
.\run.ps1 vscode-folder refresh --restart
```

> 🛟 **How restore works.** It picks the newest
> `vscode-menu-<edition>-BEFORE-*.reg` from `-SnapshotDir` (or the file
> you pass via `-RestoreFromFile`), wipes the three current keys for
> the edition so the import lands on a clean slate, runs
> `reg.exe import <snapshot>`, restarts Explorer (unless `-NoRestart`),
> then verifies all three targets (`*`, `Directory`, `Directory\Background`)
> are present. Run with `-WhatIf` first to see exactly which keys it would
> wipe and which file it would import — no changes are made in dry-run.

The script prints a **per-step trace** as it runs and finishes with a run
summary like:

```text
==========================================================
  Run summary
==========================================================
Edition         : stable
Code.exe        : C:\Users\you\AppData\Local\Programs\Microsoft VS Code\Code.exe
Code version    : 1.95.3
Removed keys    : 2
  - Registry::HKEY_CLASSES_ROOT\*\shell\VSCode
  - Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\VSCode
Ensured keys    : 1
  + Registry::HKEY_CLASSES_ROOT\Directory\shell\VSCode
Already absent  : 0
BEFORE snapshot : C:\Users\you\Desktop\vscode-menu-snapshots\vscode-menu-stable-BEFORE-20260422-143012.reg
AFTER  snapshot : C:\Users\you\Desktop\vscode-menu-snapshots\vscode-menu-stable-AFTER-20260422-143012.reg
Diff lines      : -10 / +0
Errors          : 0
==========================================================
```

If anything failed (validation, registry write, snapshot, verify), it
exits with code `1` and lists every error with `path=<exact> reason=<what>`
so you know precisely what to fix.

> **Log location:** every script writes a structured JSON log under
> `.resolved/logs/<script-id>-<timestamp>.json`. If a verification step
> fails, open the matching log first — the `Write-FileError` entries call
> out exact paths and reasons (CODE RED rule).

### 📜 Sample logs — what success / failure looks like

Every `run.ps1 -I <id>` produces **one JSON log per run**. Files are named
`<scriptId>-<scriptName>-<yyyyMMdd-HHmmss>.json` and live under
`.resolved/logs/`. The newest log is also symlinked / copied to
`.resolved/logs/latest-<scriptId>.json` for quick inspection.

```text
.resolved/
└── logs/
    ├── 49-install-whatsapp-20260422-141203.json   ← run #1 (success)
    ├── 49-install-whatsapp-20260422-141845.json   ← run #2 (failure)
    ├── latest-49.json                             ← copy of newest 49-* run
    ├── 50-install-onenote-20260422-142511.json
    └── latest-50.json
```

Tail the most recent log live:
```powershell
Get-Content .\.resolved\logs\latest-49.json -Wait -Tail 50
Get-Content .\.resolved\logs\latest-50.json -Wait -Tail 50
```

#### ✅ Success — `.\run.ps1 -I 49` (WhatsApp)

Console (truncated):
```text
[Install WhatsApp] 14:12:03  INFO  Chocolatey detected: v2.2.2
[Install WhatsApp] 14:12:04  INFO  Installing package 'whatsapp' (latest)...
[Install WhatsApp] 14:12:48  OK    choco install whatsapp -y → exit 0
[Install WhatsApp] 14:12:49  OK    Verified: C:\Users\alim\AppData\Local\WhatsApp\WhatsApp.exe
[Install WhatsApp] 14:12:49  DONE  Status: ok  (duration: 46.1s)
        log → .resolved\logs\49-install-whatsapp-20260422-141203.json
```

`.resolved/logs/49-install-whatsapp-20260422-141203.json`:
```json
{
  "scriptId": 49,
  "scriptName": "Install WhatsApp",
  "status": "ok",
  "startedAt": "2026-04-22T14:12:03+08:00",
  "finishedAt": "2026-04-22T14:12:49+08:00",
  "durationSec": 46.1,
  "chocoPackage": "whatsapp",
  "chocoExitCode": 0,
  "verifiedPath": "C:\\Users\\alim\\AppData\\Local\\WhatsApp\\WhatsApp.exe",
  "events": [
    { "ts": "14:12:03", "level": "info", "msg": "Chocolatey detected: v2.2.2" },
    { "ts": "14:12:48", "level": "ok",   "msg": "choco install whatsapp -y → exit 0" },
    { "ts": "14:12:49", "level": "ok",   "msg": "Verified WhatsApp.exe present" }
  ]
}
```

#### ❌ Failure — `.\run.ps1 -I 49` (Chocolatey package stale)

Console:
```text
[Install WhatsApp] 14:18:45  INFO  Installing package 'whatsapp' (latest)...
[Install WhatsApp] 14:19:31  WARN  choco reported 'whatsapp' v2.2024.6.x is older than upstream
[Install WhatsApp] 14:19:32  ERR   Verification failed
        path : C:\Users\alim\AppData\Local\WhatsApp\WhatsApp.exe
        reason: file not found after install — choco shim missing too
[Install WhatsApp] 14:19:32  DONE  Status: error  (duration: 47.3s)
        log → .resolved\logs\49-install-whatsapp-20260422-141845.json
```

`.resolved/logs/49-install-whatsapp-20260422-141845.json`:
```json
{
  "scriptId": 49,
  "status": "error",
  "errorCode": "VERIFY_PATH_MISSING",
  "errorPath": "C:\\Users\\alim\\AppData\\Local\\WhatsApp\\WhatsApp.exe",
  "errorReason": "file not found after install — choco shim missing too",
  "chocoExitCode": 0,
  "warnings": [
    "Chocolatey 'whatsapp' v2.2024.6.x is older than upstream — see spec/2025-batch/03-whatsapp.md open question"
  ]
}
```
> **Fix path:** re-run with `--force` (`.\run.ps1 -I 49 -- -Force`) or fall
> back to direct download per the open question in
> [`spec/2025-batch/03-whatsapp.md`](spec/2025-batch/03-whatsapp.md).

#### ✅ Success — `.\run.ps1 install onenote` (OneNote-only — default)

Console:
```text
[Install OneNote] 14:25:11  INFO  OneNote mode: install-only (no tweaks, OneDrive untouched)
[Install OneNote] 14:25:11  INFO  Strategy: choco first, direct-download fallback
[Install OneNote] 14:25:12  INFO  choco install onenote -y ...
[Install OneNote] 14:26:02  OK    choco exit 0 — ONENOTE.EXE found
[Install OneNote] 14:26:03  DONE  Status: ok  (duration: 52.0s)
        log → .resolved\logs\50-install-onenote-20260422-142511.json
```

To **also** disable OneDrive autostart and remove the OneNote tray icon,
use the explicit combo keyword instead — see
[OneNote install variants](#onenote-install-variants) below.

`.resolved/logs/50-install-onenote-20260422-142511.json`:
```json
{
  "scriptId": 50,
  "status": "ok",
  "mode": "install-only",
  "installStrategy": "choco",
  "verifiedPath": "C:\\Program Files\\Microsoft Office\\root\\Office16\\ONENOTE.EXE",
  "tweaks": { "removeTrayIcon": false, "disableOneDrive": false }
}
```

#### ✅ Success — `.\run.ps1 install onenote+rm-onedrive` (combo)

Console:
```text
[Install OneNote] 14:28:00  INFO  OneNote mode: install + rm-onedrive (tray + OneDrive autostart disabled)
[Install OneNote] 14:28:01  OK    choco install onenote -y → exit 0
[Install OneNote] 14:28:02  INFO  Removing OneNote tray icon (ONENOTEM.EXE)...
[Install OneNote] 14:28:02  OK    OneNote tray helper killed + Run-key removed
[Install OneNote] 14:28:02  INFO  Disabling OneDrive (process kill + scheduled tasks + autostart)
[Install OneNote] 14:28:03  OK    Removed OneDrive autostart entry from HKCU Run key
[Install OneNote] 14:28:03  DONE  Status: ok  (duration: 53.7s)
```

#### ❌ Failure — `.\run.ps1 install onenote+rm-onedrive` (HKCU registry write blocked)

Console:
```text
[Install OneNote] 14:30:09  OK    OneNote installed via choco (exit 0)
[Install OneNote] 14:30:10  ERR   Registry write failed
        path : HKCU:\Software\Microsoft\Windows\CurrentVersion\Run
        value: OneDrive
        reason: Requested registry access is not allowed (policy lock)
[Install OneNote] 14:30:10  DONE  Status: partial  (duration: 49.8s)
        log → .resolved\logs\50-install-onenote-20260422-143009.json
```

`.resolved/logs/50-install-onenote-20260422-143009.json`:
```json
{
  "scriptId": 50,
  "status": "partial",
  "installStrategy": "choco",
  "verifiedPath": "C:\\Program Files\\Microsoft Office\\root\\Office16\\ONENOTE.EXE",
  "errors": [
    {
      "code": "REGISTRY_ACCESS_DENIED",
      "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
      "value": "OneDrive",
      "reason": "Requested registry access is not allowed (policy lock)"
    }
  ]
}
```
> **Status legend:** `ok` = everything verified · `partial` = main install
> succeeded but a tweak failed (script keeps going) · `error` = main install
> failed, nothing usable. Every error entry **must** carry `path` +
> `reason` per the CODE RED rule.

---

## Quick Start

### Install this toolkit (Windows / PowerShell)

```powershell
# Run the root bootstrap installer from this repo
irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex

# Run elevated when a script needs HKCR / Program Files access
Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-Command',
    'irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex'
)
```

### Install this toolkit (Unix / macOS / Bash)

```bash
# Run the root bootstrap installer from this repo
curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash

# Run with sudo only when a script needs root access
sudo bash scripts-linux/run.sh install <keyword>
```

To open the full toolkit menu instead, use `./run.ps1 -d` on Windows or `bash scripts-linux/run.sh --list` on Unix / macOS.


### Manual clone

```powershell
git clone https://github.com/alimtvnetwork/scripts-fixer-v12.git scripts-fixer
cd scripts-fixer
```

```powershell
# Interactive menu -- pick what to install
.\run.ps1 -d

# Install everything with default answers (no prompts)
.\run.ps1 -d -D

# Install by keyword
.\run.ps1 install nodejs,pnpm
.\run.ps1 install python,git
.\run.ps1 install pylibs                # Python + all pip libraries in one go

# Install a specific tool by ID
.\run.ps1 -I 3          # Node.js + Yarn + Bun
.\run.ps1 -I 7          # Git + LFS + gh

# Shortcuts
.\run.ps1 -v             # VS Code
.\run.ps1 -a             # Audit mode
.\run.ps1 -w             # Winget
.\run.ps1 -t             # Windows tweaks

# Show all available scripts
.\run.ps1

# Show version + git commit + readme link
.\run.ps1 --version       # also: version, -V
```

---

## PowerShell execution policy

If Windows blocks the scripts with a red "running scripts is disabled on this system" error, use one of these options.

For the current shell only (no admin, resets when the shell closes):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

For a single command without changing the current shell policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex"
```




To make local scripts permanent for your user (still no admin):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

If the file came from a browser download or ZIP, unblock it before running:

```powershell
Unblock-File .\run.ps1
```

---

## Disclaimer / no warranty

This project is provided **AS IS, with no warranty of any kind**. It is shared **for fun and to save time on OS setup** -- not as a supported product. The scripts touch system-level settings (registry, services, package managers, scheduled tasks, browser caches, etc.); on rare occasions a third-party installer or a future Windows build can interact with them in unexpected ways. **You are responsible for anything these scripts change on your machine.** Always review what a category does (`.\run.ps1 os clean -h`) and use `--dry-run` first when in doubt.

The current running version is always printed by:

```powershell
.\run.ps1 --version
```

---

## What It Does

A modular collection of **46 PowerShell scripts** that automate everything from installing VS Code, Git, and databases to configuring Go, Python, Node.js, Flutter, .NET, Java, C++, Rust, Docker, Kubernetes, and local AI tools (Ollama, llama.cpp) -- all from a single root dispatcher with an interactive menu and keyword install system.

### Core Tools (01-09, 16-17, 38-46)

| ID | Script | What It Does | Admin |
|----|--------|--------------|-------|
| 01 | **Install VS Code** | Install Visual Studio Code (Stable or Insiders) | Yes |
| 02 | **Install Chocolatey** | Install and update the Chocolatey package manager | Yes |
| 03 | **Node.js + Yarn + Bun** | Install Node.js LTS, Yarn, Bun, verify npx | Yes |
| 04 | **pnpm** | Install pnpm, configure global store | No |
| 05 | **Python** | Install Python, configure pip user site | Yes |
| 06 | **Golang** | Install Go, configure GOPATH and go env | Yes |
| 07 | **Git + LFS + gh** | Install Git, Git LFS, GitHub CLI, configure settings | Yes |
| 08 | **GitHub Desktop** | Install GitHub Desktop via Chocolatey | Yes |
| 09 | **C++ (MinGW-w64)** | Install MinGW-w64 C++ compiler, verify g++/gcc/make | Yes |
| 16 | **PHP** | Install PHP via Chocolatey | Yes |
| 17 | **PowerShell (latest)** | Install latest PowerShell via Winget/Chocolatey | Yes |
| 38 | **Flutter + Dart** | Install Flutter SDK, Dart, Android toolchain | Yes |
| 39 | **.NET SDK** | Install .NET SDK (6/8/9), configure dotnet CLI | Yes |
| 40 | **Java (OpenJDK)** | Install OpenJDK via Chocolatey (17/21) | Yes |
| 41 | **Python Libraries** | Install pip packages: ML, viz, web, jupyter (by group) | No |
| 42 | **Ollama** | Install Ollama for local LLMs, configure models directory | Yes |
| 43 | **llama.cpp** | Download llama.cpp binaries (CUDA/AVX2/KoboldCPP), GGUF models | Yes |
| 44 | **Rust** | Install Rust toolchain via rustup, clippy, rustfmt, rust-analyzer | Yes |
| 45 | **Docker Desktop** | Install Docker Desktop via Chocolatey, WSL2 check, Compose v2 | Yes |
| 46 | **Kubernetes Tools** | Install kubectl, minikube, Helm via Chocolatey | Yes |

### VS Code Extras (10-11) & Context Menus

| ID | Script | What It Does | Admin |
|----|--------|--------------|-------|
| 10 | **VSCode Context Menu Fix** | Add/repair VS Code right-click context menu entries | Yes |
| 11 | **VSCode Settings Sync** | Sync VS Code settings, keybindings, and extensions | No |
| 31 | **PowerShell Context Menu** | Add "Open PowerShell Here" (normal + admin) to right-click menu | Yes |

### Databases (18-29)

| ID | Script | What It Does | Admin |
|----|--------|--------------|-------|
| 18 | **MySQL** | Install MySQL -- popular open-source relational database | Yes |
| 19 | **MariaDB** | Install MariaDB -- MySQL-compatible fork | Yes |
| 20 | **PostgreSQL** | Install PostgreSQL -- advanced relational database | Yes |
| 21 | **SQLite** | Install SQLite + DB Browser for SQLite | Yes |
| 22 | **MongoDB** | Install MongoDB -- document-oriented NoSQL database | Yes |
| 23 | **CouchDB** | Install CouchDB -- Apache document database with REST API | Yes |
| 24 | **Redis** | Install Redis -- in-memory key-value store and cache | Yes |
| 25 | **Apache Cassandra** | Install Cassandra -- wide-column distributed NoSQL | Yes |
| 26 | **Neo4j** | Install Neo4j -- graph database for connected data | Yes |
| 27 | **Elasticsearch** | Install Elasticsearch -- full-text search and analytics | Yes |
| 28 | **DuckDB** | Install DuckDB -- analytical columnar database | Yes |
| 29 | **LiteDB** | Install LiteDB -- .NET embedded NoSQL file-based database | Yes |

### Orchestrators

| ID | Script | What It Does | Admin |
|----|--------|--------------|-------|
| 12 | **Install All Dev Tools** | Interactive grouped menu with CSV input, group shortcuts, and loop-back | Yes |
| 30 | **Install Databases** | Interactive database installer menu (SQL, NoSQL, graph, search) | Yes |

### Utilities

| ID | Script | What It Does | Admin |
|----|--------|--------------|-------|
| 13 | **Audit Mode** | Scan configs, specs, and suggestions for stale IDs or references | No |
| 14 | **Install Winget** | Install/verify Winget package manager (standalone) | Yes |
| 15 | **Windows Tweaks** | Launch Chris Titus Windows Utility for system tweaks and debloating | Yes |

### Desktop Tools (32-37)

| ID | Script | What It Does | Admin |
|----|--------|--------------|-------|
| 32 | **[DBeaver Community](scripts/32-install-dbeaver/)** | Universal database visualization and management tool | Yes |
| 33 | **[Notepad++ (NPP)](scripts/33-install-notepadpp/)** | Install NPP, NPP Settings, or NPP + Settings | Yes |
| 34 | **[Simple Sticky Notes](scripts/34-install-sticky-notes/)** | Install Simple Sticky Notes via Chocolatey | Yes |
| 35 | **[GitMap](scripts/35-install-gitmap/)** | Git repository navigator CLI tool | Yes |
| 36 | **[OBS Studio](scripts/36-install-obs/)** | Install OBS, OBS Settings, or OBS + Settings | Yes |
| 37 | **[Windows Terminal](scripts/37-install-windows-terminal/)** | Install WT, WT Settings, or WT + Settings | Yes |
| 47 | **[Ubuntu Font](scripts/47-install-ubuntu-font/)** | Install Ubuntu font family system-wide | Yes |
| 48 | **[ConEmu](scripts/48-install-conemu/)** | Install ConEmu + sync `ConEmu.xml` (3 modes + export) | Yes |
| 49 | **[WhatsApp Desktop](scripts/49-install-whatsapp/)** | Install WhatsApp Desktop via Chocolatey | Yes |
| 50 | **[OneNote](scripts/50-install-onenote/)** | Install OneNote — pure (default) or `+rm-onedrive` combo | Yes |
| 51 | **[Lightshot](scripts/51-install-lightshot/)** | Install Lightshot + opinionated registry tweaks | Yes |
| 52 | **[VSCode Folder Repair](scripts/52-vscode-folder-repair/)** | Repair VSCode folder context-menu (subcommands: dry-run, restore, refresh, ...) | Yes |

---

## Root Dispatcher

The root `run.ps1` is the **single entry point** for all scripts. It handles git pull, log cleanup, environment flags, and cache management before delegating.

### Root-level Linux helpers (v0.175.0)

Two new top-level shell scripts at the repository root sit alongside
`install.sh` for the Linux side of the toolkit. Each one is a thin
dispatcher to its interactive menu and the per-service worker scripts
under `scripts-linux/`.

| Root script | Forwards to | What it does |
|-------------|-------------|--------------|
| `./change-port.sh` | `scripts-linux/91-change-port-menu/run.sh` | Change the listening port for SSH, MySQL, PostgreSQL, FTP, Redis, MongoDB, nginx, Apache, Docker, RabbitMQ. SMTP (Postfix) is read-only on purpose. |
| `./install-dns.sh` | `scripts-linux/109-install-dns-menu/run.sh` | Install BIND9, Unbound, PowerDNS Authoritative, PowerDNS Recursor, dnsmasq, Knot DNS, Knot Resolver, CoreDNS, or NSD with one command. |

Both scripts accept a friendly service name as the first argument and
forward the rest of the command line to the per-service worker. With no
arguments they open the interactive menu.

```bash
# change-port.sh — SSH on a custom port, with safe defaults
./change-port.sh                      # interactive menu
./change-port.sh ssh --port 2222      # prompt-and-confirm flow
./change-port.sh ssh --port 2222 --yes
./change-port.sh mysql --interactive
./change-port.sh smtp                 # READ-ONLY inspection of Postfix listeners
./change-port.sh --list               # show all 11 supported services

# install-dns.sh — pick a DNS server and let the script handle defaults
./install-dns.sh                      # interactive menu (defaults to install -i)
./install-dns.sh bind9                # install with config.json defaults
./install-dns.sh unbound --interactive
./install-dns.sh coredns --port 5353 --listen 0.0.0.0 --forwarders 1.1.1.1,9.9.9.9
./install-dns.sh dnsmasq check        # verify install
./install-dns.sh --list               # show all 9 supported DNS servers
```

#### Safety guarantees (change-port family)

Every per-service port-change script (`scripts-linux/80-90/`) is built on
`scripts-linux/_shared/port-change.sh`, which enforces:

1. **Backup before touch** — every targeted config file is copied to
   `<path>.bak.<timestamp>` *before* the first edit. CODE RED file-error
   logging fires with the exact path and reason if any backup fails.
2. **Service-native validation** — `sshd -t`, `nginx -t`,
   `apache2ctl configtest` etc. run *after* the edit and *before* the
   restart. Validator failure triggers automatic rollback from backup.
3. **Plan-then-confirm** — a render of every planned edit is shown to
   the operator before any change. `--yes` skips the prompt for CI;
   `--dry-run` shows the diff and changes nothing.
4. **Firewall opens new, never closes old** — `ufw allow <new>/tcp` (or
   the firewalld equivalent) is added for the new port. The old port is
   left alone with an explicit warning so you can audit clients first.
5. **SMTP is intentionally locked** — script `90-change-port-smtp/`
   refuses to mutate Postfix. Changing inbound port 25 silently breaks
   mail delivery from every other MTA, so the script only reports the
   current listener state.

#### Defaults live in JSON (DNS family)

Each `scripts-linux/100-108-install-dns-*/config.json` declares the apt
packages, optional snap/binary fallbacks, the `systemd` unit to restart,
the path to the drop-in config the installer writes, and the default
port / listen address / forwarders. Edit the JSON to change defaults
for your environment without touching shell code.

```powershell
.\run.ps1                           # Show help (after git pull)
.\run.ps1 -I <number>               # Run a specific script
.\run.ps1 -I <number> -D            # Run with all default answers (skip prompts)
.\run.ps1 -I <number> -Clean        # Wipe cache, then run
.\run.ps1 -CleanOnly                # Wipe all cached data
```

### Shortcut Flags

| Flag | Equivalent | Description |
|------|-----------|-------------|
| `-d` | `-I 12` | Interactive dev tools menu |
| `-D` | N/A | Use all default answers (skip prompts) |
| `-a` | `-I 13` | Audit mode |
| `-h` | `-I 13 -Report` | Health check |
| `-v` | `-I 1` | Install VS Code |
| `-w` | `-I 14` | Install Winget |
| `-t` | `-I 15` | Windows tweaks |

### Keyword Install

Install tools by human-friendly name instead of script ID:

```powershell
.\run.ps1 install vscode             # Install VS Code
.\run.ps1 install nodejs,pnpm        # Install Node.js + pnpm
.\run.ps1 install go,git,cpp         # Install Go, Git, C++
.\run.ps1 install python             # Install Python + pip
.\run.ps1 install pylibs             # Python + all pip libraries (numpy, pandas, jupyter, etc.)
.\run.ps1 install flutter            # Install Flutter SDK + Dart
.\run.ps1 install dotnet             # Install .NET SDK
.\run.ps1 install java               # Install OpenJDK
.\run.ps1 install databases          # Interactive database menu
.\run.ps1 install mysql,redis        # Install specific databases
.\run.ps1 install npp                # Notepad++ + Settings
.\run.ps1 install obs                # OBS Studio + Settings
.\run.ps1 install wt                 # Windows Terminal + Settings
.\run.ps1 install dbeaver            # DBeaver + Settings
.\run.ps1 -Install python,php        # Named parameter style
```

### Multi-tool install — by name (preferred) or by ID

Names compose freely with commas. IDs accept ranges and lists too. Mix
them when you want to grab a specific batch.

```powershell
# By name -- the readable way
.\run.ps1 install vscode,git,nodejs,pnpm,python
.\run.ps1 install npp,obs,wt,dbeaver,conemu       # all desktop tools at once
.\run.ps1 install whatsapp,onenote,lightshot      # 2025-batch desktop apps
.\run.ps1 install ubuntu-font,conemu              # font + terminal pair
.\run.ps1 install go,rust,cpp,dotnet,java         # all systems-language runtimes

# By ID range -- handy for sweeping the 2025-batch
.\run.ps1 install 47..52                          # Ubuntu Font -> ConEmu -> WhatsApp -> OneNote -> Lightshot -> VSCode-folder-repair
.\run.ps1 install 47..49,51                       # skip OneNote (50) but grab Lightshot (51)
.\run.ps1 install 1,7,11                          # VSCode + Git + VSCode settings sync

# Mix names and IDs
.\run.ps1 install vscode,11,git,nodejs            # name + id, in any order

# Profiles bundle dozens of tools behind one name
.\run.ps1 install profile-small-dev               # advance + Go/Py/Node/pnpm
.\run.ps1 install profile-cpp-dx                  # VC++ runtimes + DirectX
```

> 🧠 **XMind?** XMind ships as a Chocolatey step inside
> [`profile base`](scripts/profile/config.json) (and therefore `advance` /
> `small-dev`). It does not have its own numbered script. Run
> `.\run.ps1 profile base` to get it, or `choco install xmind -y` directly
> if you only want XMind.

<a id="onenote-install-variants"></a>

### OneNote install variants

Plain `onenote` does **only** OneNote. To also disable OneDrive autostart
and remove the OneNote tray icon, use the `+rm-onedrive` combo. Runs are
separate by design — install OneNote alone today, decide on OneDrive later.

| Keyword | What runs |
|---------|-----------|
| `install onenote` | Script 50 in `install` mode → OneNote only, no tweaks, OneDrive untouched |
| `install onenote+rm-onedrive` | Script 50 in `with-tweaks` mode → install + remove tray + disable OneDrive autostart + scheduled tasks |
| `install onenote+tweaks` | Alias of `onenote+rm-onedrive` |
| `-I 50 -- with-tweaks` | Same as the combo, by script ID |
| `-I 50 -- rm-onedrive` | Same as the combo, by script ID |
| `-I 50 uninstall` | Choco uninstall + tracking purge (does **not** re-enable OneDrive) |

Source: [`scripts/50-install-onenote/run.ps1`](scripts/50-install-onenote/run.ps1) ·
config: [`scripts/50-install-onenote/config.json`](scripts/50-install-onenote/config.json).

### Python & Libraries Keywords

```powershell
# Quick install
.\run.ps1 install pylibs             # Python + all libraries in one go
.\run.ps1 install python-libs        # All pip libraries only (libs without Python install)
.\run.ps1 install python+libs        # Python + all libraries (same as pylibs)

# By purpose
.\run.ps1 install data-science       # Python + data/viz libs (pandas, matplotlib, plotly)
.\run.ps1 install ai-dev             # Python + ML libs (numpy, scipy, scikit-learn, torch)
.\run.ps1 install deep-learning      # Python + ML libs (same as ai-dev)
.\run.ps1 install ai-full            # Python + ML libs + Ollama + llama.cpp (05, 41, 42, 43)

# By group (libs only, no Python install)
.\run.ps1 install jupyter+libs       # Jupyter only (jupyterlab, notebook, ipykernel)
.\run.ps1 install viz-libs           # Visualization (matplotlib, seaborn, plotly)
.\run.ps1 install web-libs           # Web frameworks (django, flask, fastapi, uvicorn)
.\run.ps1 install scraping-libs      # Scraping (requests, beautifulsoup4)
.\run.ps1 install db-libs            # Database (sqlalchemy)
.\run.ps1 install cv-libs            # Computer Vision (opencv-python)
.\run.ps1 install data-libs          # Data tools (pandas, polars)

# Python + specific group
.\run.ps1 install python+viz         # Python + visualization group
.\run.ps1 install python+web         # Python + web frameworks group
.\run.ps1 install python+scraping    # Python + scraping group
.\run.ps1 install python+db          # Python + database group
.\run.ps1 install python+cv          # Python + computer vision group
.\run.ps1 install python+data        # Python + data tools group
.\run.ps1 install python+ml          # Python + ML group
.\run.ps1 install python+jupyter     # Python + all libraries (includes Jupyter)

# Direct group invocation
.\run.ps1 -I 41 -- group ml          # ML group (numpy, scipy, scikit-learn, torch...)
.\run.ps1 -I 41 -- group jupyter     # Jupyter group
.\run.ps1 -I 41 -- group viz         # Visualization group
.\run.ps1 -I 41 -- add <pkg> <pkg>   # Install specific packages by name
.\run.ps1 -I 41 -- list              # Show all available library groups
.\run.ps1 -I 41 -- installed         # Show currently installed pip packages
.\run.ps1 -I 41 -- uninstall         # Uninstall all tracked libraries
```

### Combo Shortcuts

```powershell
.\run.ps1 install vscode+settings    # VSCode + Settings Sync (01, 11)
.\run.ps1 install vms                # VSCode + Menu Fix + Sync (01, 10, 11)
.\run.ps1 install git+desktop        # Git + GitHub Desktop (07, 08)
.\run.ps1 install node+pnpm          # Node.js + pnpm (03, 04)
.\run.ps1 install frontend           # VSCode + Node + pnpm + Sync (01, 03, 04, 11)
.\run.ps1 install backend            # Python + Go + PHP + PG + .NET + Java (05, 06, 16, 20, 39, 40)
.\run.ps1 install web-dev            # VSCode + Node + pnpm + Git + Sync (01, 03, 04, 07, 11)
.\run.ps1 install essentials         # VSCode + Choco + Node + Git + Sync (01, 02, 03, 07, 11)
.\run.ps1 install full-stack         # Everything for full-stack dev (01-09, 11, 16, 39, 40)
.\run.ps1 install mobile-dev         # Flutter mobile dev (38)
.\run.ps1 install data-dev           # Postgres + Redis + DuckDB + DBeaver (20, 24, 28, 32)
```

### Desktop Tools Install Modes

```powershell
# Notepad++
.\run.ps1 install npp                # Install + sync settings (default)
.\run.ps1 install npp+settings       # Install + sync settings (explicit)
.\run.ps1 install npp-settings       # Sync settings only
.\run.ps1 install install-npp        # Install only (no settings)

# OBS Studio
.\run.ps1 install obs                # Install + sync settings (default)
.\run.ps1 install obs-settings       # Sync settings only
.\run.ps1 install install-obs        # Install only (no settings)

# Windows Terminal
.\run.ps1 install wt                 # Install + sync settings (default)
.\run.ps1 install wt-settings        # Sync settings only
.\run.ps1 install install-wt         # Install only (no settings)

# DBeaver
.\run.ps1 install dbeaver            # Install + sync settings (default)
.\run.ps1 install dbeaver-settings   # Sync settings only
.\run.ps1 install install-dbeaver    # Install only (no settings)

# .NET SDK versions
.\run.ps1 install dotnet-6           # Install .NET 6
.\run.ps1 install dotnet-8           # Install .NET 8
.\run.ps1 install dotnet-9           # Install .NET 9

# Java versions
.\run.ps1 install jdk-17             # Install OpenJDK 17
.\run.ps1 install jdk-21             # Install OpenJDK 21

# Flutter modes
.\run.ps1 install flutter            # Install Flutter SDK
.\run.ps1 install flutter+android    # Install with Android toolchain
.\run.ps1 install flutter-extensions # Install VS Code Flutter extensions
.\run.ps1 install flutter-doctor     # Run flutter doctor

# AI Tools
.\run.ps1 install ollama             # Install Ollama for local LLMs (42)
.\run.ps1 install llama-cpp          # Download llama.cpp binaries + models (43)
.\run.ps1 install llama              # Same as llama-cpp (43)
.\run.ps1 install ai-tools           # Install both Ollama + llama.cpp (42, 43)
.\run.ps1 install local-ai           # Same as ai-tools (42, 43)
.\run.ps1 install ai-full            # Python + ML libs + Ollama + llama.cpp (05, 41, 42, 43)

# Rust, Docker, Kubernetes
.\run.ps1 install rust               # Install Rust via rustup (44)
.\run.ps1 install docker             # Install Docker Desktop (45)
.\run.ps1 install kubernetes         # Install kubectl + minikube + Helm (46)
.\run.ps1 install k8s                # Same as kubernetes (46)
.\run.ps1 install devops             # Git + Docker + Kubernetes (07, 45, 46)
.\run.ps1 install container-dev      # Docker + Kubernetes (45, 46)
.\run.ps1 install systems-dev        # C++ + Rust (09, 44)
```

Keywords are case-insensitive, support comma/space separation, auto-deduplicate, and run in sorted order. See `scripts/shared/install-keywords.json` for the full keyword map.

---

## Interactive Menu (Script 12)

When you run `./run.ps1 -d`, you get a full interactive menu with:

- **Individual selection** -- type script numbers: `1`, `3`, `7`
- **CSV input** -- type comma-separated IDs: `1,3,5,7`
- **Group shortcuts** -- press a letter to select a predefined group:

| Key | Group | Scripts |
|-----|-------|---------|
| `a` | All Core (01-09) | 01, 02, 03, 04, 05, 06, 07, 08, 09 |
| `b` | Dev Runtimes (03-08) | 03, 04, 05, 06, 07, 08 |
| `c` | JS Stack (03-04) | 03, 04 |
| `d` | Languages (05-06,16) | 05, 06, 16 |
| `e` | Git Tools (07-08) | 07, 08 |
| `f` | Web Dev (03,04,06,08,16) | 03, 04, 06, 08, 16 |
| `g` | All + Extras (01-11,16-17,31,33) | 01-11, 16, 17, 31, 33 |
| `h` | SQL DBs (18-21) | 18, 19, 20, 21 |
| `i` | NoSQL DBs (22-26) | 22, 23, 24, 25, 26 |
| `j` | All Databases (18-29) | 18-29 |
| `k` | Backend Stack | 03, 04, 06, 18-20, 24 |
| `l` | Full Stack | 03, 04, 06, 07, 16, 18, 20, 22, 24 |
| `m` | Data Engineering | 05, 20, 27, 28 |
| `n` | Everything (01-46) | All scripts |
| `o` | All Dev + MySQL | 01-09, 18 |
| `p` | All Dev + PostgreSQL | 01-09, 20 |
| `r` | All Dev + PostgreSQL + Redis | 01-09, 20, 24 |
| `s` | SQLite + DBeaver | 21, 32 |
| `t` | All DBs + DBeaver (18-29,32) | 18-29, 32 |
| `u` | AI Tools (42-43) | 42, 43 |
| `v` | AI Full Stack (05,41-43) | 05, 41, 42, 43 |
| `w` | DevOps (07,45-46) | 07, 45, 46 |
| `x` | Container Dev (44-46) | 44, 45, 46 |

- **Select All / None** -- `A` to select all, `N` to deselect all
- **Loop-back** -- after install + summary, returns to the menu
- **Quit** -- press `Q` to exit

---

## Dev Directory

Scripts install tools into a shared dev directory with **smart drive detection** (E: > D: > drive with most free space):

```
E:\dev-tool\
  go\          # GOPATH (bin, pkg/mod, cache/build)
  nodejs\      # npm global prefix
  python\      # Python install + PYTHONUSERBASE (Scripts/)
  pnpm\        # pnpm store
  llama-cpp\   # llama.cpp binaries (CUDA, AVX2, KoboldCPP)
  llama-models\# GGUF model files
  ollama\      # Ollama installer cache
```

Ollama models default to `<dev-dir>\ollama-models` (configurable via `OLLAMA_MODELS` env var).

Override with: `.\run.ps1 -I 12 -- -Path F:\dev-tool`

Manage the path:

```powershell
.\run.ps1 path                # Show current dev directory
.\run.ps1 path D:\my-tools    # Set custom dev directory
.\run.ps1 path --reset        # Clear saved path, use smart detection
```

The orchestrator (script 12) resolves this path once and passes it to all child scripts via `$env:DEV_DIR`.

---

## Versioning

All scripts read their version from `scripts/version.json` (single source of truth). Use the bump script:

```powershell
.\bump-version.ps1 -Patch            # 0.3.0 -> 0.3.1
.\bump-version.ps1 -Minor            # 0.3.0 -> 0.4.0
.\bump-version.ps1 -Major            # 0.3.0 -> 1.0.0
.\bump-version.ps1 -Set "2.0.0"     # Explicit version
```

---

## Project Structure

```
run.ps1                        # Root dispatcher (single entry point)
bump-version.ps1               # Version bump utility
scripts/
  version.json                 # Centralized version (single source of truth)
  registry.json                # Maps IDs to folder names
  shared/                      # Reusable helpers (logging, JSON, PATH, etc.)
    install-keywords.json      # Keyword-to-script-ID mapping
  01-install-vscode/           # VS Code
  02-install-package-managers/ # Chocolatey
  03-install-nodejs/           # Node.js + Yarn + Bun
  04-install-pnpm/             # pnpm
  05-install-python/           # Python
  06-install-golang/           # Go
  07-install-git/              # Git + LFS + gh
  08-install-github-desktop/   # GitHub Desktop
  09-install-cpp/              # C++ (MinGW-w64)
  10-vscode-context-menu-fix/  # VSCode context menu
  11-vscode-settings-sync/     # VSCode settings sync
  12-install-all-dev-tools/    # Orchestrator (interactive menu)
  14-install-winget/           # Winget (standalone)
  15-windows-tweaks/           # Chris Titus Windows Utility
  16-install-php/              # PHP
  17-install-powershell/       # PowerShell (latest)
  18-install-mysql/            # MySQL
  19-install-mariadb/          # MariaDB
  20-install-postgresql/       # PostgreSQL
  21-install-sqlite/           # SQLite + DB Browser
  22-install-mongodb/          # MongoDB
  23-install-couchdb/          # CouchDB
  24-install-redis/            # Redis
  25-install-cassandra/        # Apache Cassandra
  26-install-neo4j/            # Neo4j
  27-install-elasticsearch/    # Elasticsearch
  28-install-duckdb/           # DuckDB
  29-install-litedb/           # LiteDB
  databases/                   # Database orchestrator menu
  31-pwsh-context-menu/        # PowerShell context menu
  32-install-dbeaver/          # DBeaver Community
  33-install-notepadpp/        # Notepad++
  34-install-sticky-notes/     # Simple Sticky Notes
  35-install-gitmap/           # GitMap CLI
  36-install-obs/              # OBS Studio
  37-install-windows-terminal/ # Windows Terminal
  38-install-flutter/          # Flutter + Dart
  39-install-dotnet/           # .NET SDK
  40-install-java/             # Java (OpenJDK)
  41-install-python-libs/      # Python pip libraries
  42-install-ollama/           # Ollama local LLM runtime
  43-install-llama-cpp/        # llama.cpp binaries + GGUF models
  44-install-rust/             # Rust toolchain via rustup
  45-install-docker/           # Docker Desktop + Compose
  46-install-kubernetes/       # kubectl + minikube + Helm
  audit/                       # Audit scanner
spec/                          # Specifications per script
suggestions/                   # Improvement ideas
settings/                      # App settings (NPP, OBS, WT, DBeaver)
.resolved/                     # Runtime state (git-ignored)
```

### Each Script Contains

```
scripts/NN-name/
  run.ps1                  # Entry point
  config.json              # External configuration
  log-messages.json        # All display strings
  helpers/                 # Script-specific functions
  logs/                    # Auto-created (gitignored)
```

---

## Shared Helpers

Reusable utilities in `scripts/shared/`:

| File | Purpose |
|------|---------|
| `logging.ps1` | Console output with colorful status badges, auto-version from `version.json` |
| `json-utils.ps1` | File backups, hashtable conversion, deep JSON merge |
| `resolved.ps1` | Persist runtime state to `.resolved/` |
| `cleanup.ps1` | Wipe `.resolved/` contents |
| `git-pull.ps1` | Git pull with skip guard (`$env:SCRIPTS_ROOT_RUN`) |
| `help.ps1` | Formatted `-Help` output from log-messages.json |
| `path-utils.ps1` | Safe PATH manipulation with dedup |
| `choco-utils.ps1` | Chocolatey install/upgrade wrappers |
| `dev-dir.ps1` | Dev directory resolution and creation |
| `tool-version.ps1` | Version detection, PATH refresh, Python resolver |
| `installed.ps1` | `.installed/` tracking system for version persistence |
| `install-keywords.json` | Keyword-to-script-ID mapping for `install` command |
| `log-viewer.ps1` | Log file viewer utility |
| `symlink-utils.ps1` | Symlink creation and management |

---

## Adding a New Script

1. Create folder `scripts/NN-name/` with `run.ps1`, `config.json`, `log-messages.json`, and `helpers/`
2. Dot-source shared helpers from `scripts/shared/`
3. Support `-Help` flag using `Show-ScriptHelp`
4. Save state via `Save-ResolvedData`
5. Add spec in `spec/NN-name/readme.md`
6. Register in `scripts/registry.json`
7. Add keywords in `scripts/shared/install-keywords.json`
8. Add to script 12's `config.json` if it should be orchestrated

---

## Recent Changes

### v0.28.0 -- Rust, Docker, Kubernetes

- **Script 44 -- Install Rust** -- Rust toolchain via rustup + clippy/rustfmt/rust-analyzer + cargo/bin PATH
- **Script 45 -- Install Docker** -- Docker Desktop via Chocolatey + WSL2 check + daemon verify
- **Script 46 -- Install Kubernetes** -- kubectl + minikube + Helm via Chocolatey
- **New combos** -- `devops` (7+45+46), `container-dev` (45+46), `systems-dev` (9+44)

### v0.26.0 -- 4-Filter Model Picker

- **81-model catalog** -- expanded from 69 to 81 models with new small/fast entries
- **4-filter chain** -- RAM → Size → Speed → Capability with re-indexing
- **Speed filter + column** -- inference speed tier based on file size

### v0.22.1 -- Help Display Overhaul

- **Alignment fixed** -- all keyword tables use consistent PadRight columns for perfect alignment
- **Installed versions shown** -- Available Scripts section displays `[vX.Y.Z]` in green for installed tools
- **Missing scripts added** -- Flutter (38), .NET (39), Java (40), Windows Terminal (37) in help display
- **`pylibs` keyword in help** -- appears in Install by Keyword, Keywords table, and Combo Shortcuts
- **Desktop Tools category** -- renamed from Database Tools, includes all desktop apps

---

## Prerequisites

- **Windows 10/11**
- **PowerShell 5.1+** (ships with Windows)
- **Administrator privileges** (for most scripts)
- **Internet access** (for package downloads)

---

## Author

<div align="center">

### [Md. Alim Ul Karim](https://www.google.com/search?q=alim+ul+karim)

**[Creator & Lead Architect](https://alimkarim.com)** | [Chief Software Engineer](https://www.google.com/search?q=alim+ul+karim), [Riseup Asia LLC](https://riseup-asia.com)

</div>

A system architect with **20+ years** of professional software engineering experience across enterprise, fintech, and distributed systems. His technology stack spans **.NET/C# (18+ years)**, **JavaScript (10+ years)**, **TypeScript (6+ years)**, and **Golang (4+ years)**.

Recognized as a **top 1% talent at Crossover** and one of the top software architects globally. He is also the **Chief Software Engineer of [Riseup Asia LLC](https://riseup-asia.com/)** and maintains an active presence on **[Stack Overflow](https://stackoverflow.com/users/513511/md-alim-ul-karim)** (2,452+ reputation, 961K+ reached, member since 2010) and **LinkedIn** (12,500+ followers).

| | |
|---|---|
| **Website** | [alimkarim.com](https://alimkarim.com/) · [my.alimkarim.com](https://my.alimkarim.com/) |
| **LinkedIn** | [linkedin.com/in/alimkarim](https://linkedin.com/in/alimkarim) |
| **Stack Overflow** | [stackoverflow.com/users/513511/md-alim-ul-karim](https://stackoverflow.com/users/513511/md-alim-ul-karim) |
| **Google** | [Alim Ul Karim](https://www.google.com/search?q=Alim+Ul+Karim) |
| **Role** | Chief Software Engineer, [Riseup Asia LLC](https://riseup-asia.com) |

### Riseup Asia LLC — Top Software Company in Wyoming, USA

[Riseup Asia LLC](https://riseup-asia.com) is a **top-leading software company headquartered in Wyoming, USA**, specializing in building **enterprise-grade frameworks**, **research-based AI models**, and **distributed systems architecture**. The company follows a **"think before doing"** engineering philosophy — every solution is researched, validated, and architected before implementation begins.

**Core expertise includes:**

- 🏗️ **Framework Development** — Designing and shipping production-grade frameworks used across enterprise and fintech platforms
- 🧠 **Research-Based AI** — Inventing and deploying AI models grounded in rigorous research methodologies
- 🔬 **Think Before Doing** — A disciplined engineering culture where architecture, planning, and validation precede every line of code
- 🌐 **Distributed Systems** — Building scalable, resilient systems for global-scale applications

| | |
|---|---|
| **Website** | [riseup-asia.com](https://riseup-asia.com) |
| **Facebook** | [riseupasia.talent](https://www.facebook.com/riseupasia.talent/) |
| **LinkedIn** | [Riseup Asia](https://www.linkedin.com/company/105304484/) |
| **YouTube** | [@riseup-asia](https://www.youtube.com/@riseup-asia) |

---

## License

This project is licensed under the **MIT License** -- see the [LICENSE](LICENSE) file for the full text.

```
Copyright (c) 2026 Alim Ul Karim
```

You may use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, provided the copyright notice and permission notice are preserved. The software is provided "AS IS", without warranty of any kind.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

<div align="center">

*Built with clean architecture, external configs, and colorful terminal output — because dev tools setup should be effortless.*

</div>
