# Project Plan -- Dev Tools Setup

## Current Version: v0.94.0
## Last Updated: 2026-04-26

---

## 🔄 In Progress

### README profile UX overhaul (v0.92.0)
- [x] Per-profile H3 sections in root `readme.md` with: what installs, install-location matrix (C:\ vs E:\dev-tool), copy-paste one-liner, animated demo
- [x] **XMind** dedicated section -- explains `choco install xmind` lands in `C:\Program Files (x86)\XMind`, not E:
- [x] **Multi-tool comma install** section with big animated typewriter demo (`install vscode,git,nodejs,pnpm`)
- [x] **Win11 classic right-click menu** restore inline helper (`Restore-Win11ClassicContext`), wired into `profile minimal` (HKCU CLSID `{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` empty default)
- [x] Updated `spec/2025-batch/12-profiles.md` with new minimal step + per-profile install location matrix
- [x] Saved memory file `mem://features/02-profile-install-locations` so future README/spec edits keep the C:\ vs E:\ matrix consistent

### README profile totals follow-up (v0.93.0)
- [x] Added explicit profile total summary table (`steps`, `C:\`, `E:\dev-tool`, user-profile writes, registry/system changes)
- [x] Expanded `advance` / `small-dev` README sections to show exact totals instead of only extras
- [x] Added dedicated animated demos for `profile base` and `profile cpp-dx`
- [x] Tightened memory/spec rule so future profile docs always include a total summary, not just location rows

### 2025 Batch
- [x] **Group A complete** -- scripts 47-51 (ubuntu-font, conemu+settings, whatsapp, onenote+tray+onedrive, lightshot+tweaks). v0.39.1.
- [x] **Group B complete** -- `os` dispatcher with `clean`, `hib-off`/`hib-on`, `flp`, `add-user`. Self-elevation + 15 keywords. v0.39.2.
- [x] **Group C complete** -- `git-tools` dispatcher: `gsa` (wildcard + `--scan` + `--list` + `--remove` + `--prune` + `--dry-run`), 4 helpers (safe-all, list-safe, remove-safe, prune-safe), root-dispatcher wiring at run.ps1:2183/2239, spec at `spec/2025-batch/05-git-safe-all.md`, config.json filled in. v0.94.0.
- [x] **Group D complete** -- `profile` dispatcher + 6 declarative profiles (minimal, base, git-compact, advance, cpp-dx, small-dev) with recursive expansion + cycle detection + 5 step kinds (script/choco/subcommand/inline/profile). Extended `Resolve-InstallKeywords` to parse the `["dispatcher:action"]` array convention so `os:` and `profile:` keywords route end-to-end. 11 new profile-* keywords. Inline helpers: PSReadLine latest, SSH ed25519, default GitHub dir, default git config (LFS + safe.directory + gitlab rewrite). v0.39.4.
- [ ] **Group E** -- polish: default git config update in `scripts/07-install-git/` (extract LFS/safe/url blocks now that `Apply-DefaultGitConfig` covers them), root dispatcher help text refresh for the new `os` / `profile` commands, bump to v0.40.0

## ⏳ Pending / Next Steps

### Generic Install-Script Spec (NEW — blocked on user confirmation)
- [ ] **Awaiting** user reply on 15-item checklist (naming, v1..v20 range, probe mechanism, strict-mode triggers, file layout)
- [ ] Write `spec/00-generic-install-script-behavior/readme.md` (overview + index)
- [ ] Write `01-release-tag-mode.md` — strict mode, no fallback, no vN hopping
- [ ] Write `02-main-branch-mode.md` — default when no tag
- [ ] Write `03-versioned-discovery.md` — `<prefix>-v1..v20` parallel probe (lowercase)
- [ ] Write `04-failure-handling.md` — hard-fail rules for strict mode
- [ ] Write `05-acceptance-criteria.md`
- [ ] Write `06-implementation-plan.md` — per-repo migration steps
- [ ] Re-point `spec/install-bootstrap/readme.md` as a concrete instance of the generic spec
- [ ] Update `mem://features/install-bootstrap` once spec lands
- [ ] Tracking: `.lovable/pending-issues/01-generic-install-spec-awaiting-confirmation.md`

### Bootstrap follow-ups
- [ ] End-to-end verify install.ps1 from D:\, C:\Users\X, C:\Windows\System32 (fallback), and inside an existing checkout
- [ ] End-to-end verify install.sh from /tmp, $HOME, /etc (fallback), and inside an existing checkout
- [ ] Add audit script that runs `install.ps1 -DryRun` + `install.sh --dry-run` across the test matrix

### Documentation & Quality
- [ ] Verify `-Version` flag end-to-end on real Windows + Linux shells
- [ ] Verify auto-discovery redirect with a real `vN+1` sibling repo
- [ ] Update changelog v0.26.0 entry to include speed filter (added after version bump)
- [ ] Verify 4-filter chain re-indexing works correctly end-to-end
- [ ] Verify catalog column alignment with Speed column across all 81 models

### Future Features (Not Started)
- [ ] GUI/TUI for the interactive menu
- [ ] Cross-machine settings sync via cloud storage
- [ ] Linux/macOS support for the actual install scripts (bootstrap already cross-platform)
- [ ] New tool scripts (Docker, Rust)
- [ ] Model catalog auto-update from Hugging Face trending
- [ ] Parallel model downloads (aria2c batch mode)
- [ ] Model integrity verification (SHA256 checksums in catalog)

---

## ✅ Completed

### v0.38.1 (2026-04-19)
- [x] `install.sh` mirrors CWD-aware target resolution (4-step decision tree, `test_cwd_is_safe`, `resolve_target_folder`)
- [x] `install.sh` `--dry-run` flag with `[DRYRUN] ... (skipped)` lines for every mutating step
- [x] `install.sh` final action: `pwsh ./run.ps1` (no `-d`), matching PowerShell

### v0.38.0 (2026-04-19)
- [x] `install.ps1` CWD-aware target resolution (CWD\scripts-fixer when safe, sibling reuse, USERPROFILE fallback for protected dirs/drive roots)
- [x] `install.ps1` final action changed: launches `.\run.ps1` with no args (was `-d` straight into Install All Dev Tools)
- [x] New helpers `Test-CwdIsSafe` + `Resolve-TargetFolder` with reason-tagged `[LOCATE]` logging

### v0.37.1 (2026-04-19)
- [x] `-DryRun` flag for `install.ps1` — magenta `[DRYRUN] ... (skipped)` lines for every mutating step

### v0.37.0 (2026-04-19)
- [x] `install.ps1` + `install.sh` self-relocation flow (cd-out, TEMP staging fallback, `[GIT]` URL log)
- [x] Stderr-noise fix (no more red `NativeCommandError` on successful clones)

### v0.36.0 (2026-04-18)
- [x] `-Version` / `--version` diagnostic flag for `install.ps1` + `install.sh`
- [x] Bumped default probe range from current+20 → current+30 in installers and spec

### v0.35.0 (2026-04-18)
- [x] Bootstrap installers always wipe and fresh-clone `scripts-fixer` (Windows + Unix)
- [x] CODE RED file-path errors on remove/clone failures with recovery hints

### v0.34.0 / v0.34.1 (2026-04-17)
- [x] `models search <query>` — live Ollama Hub search with x-test-* regex parser
- [x] `models uninstall` — multi-backend (llama.cpp + Ollama) with multi-select + confirm
- [x] `-Force` flag for `models uninstall` (CI-friendly, skips yes/no gate)

### v0.31.0 - v0.33.0 (2026-04-17)
- [x] `spec/install-bootstrap/readme.md` documenting parallel-probe auto-discovery
- [x] Auto-discovery in `install.ps1` (Start-ThreadJob, sequential PS 5.1 fallback)
- [x] Auto-discovery in `install.sh` (`xargs -P 20` parallel HEAD probes)
- [x] `scripts/models/` orchestrator with `picker.ps1` + env-var handoff contract
- [x] Non-interactive CSV installs end-to-end across both backends

### v0.27.0 - v0.30.1
- [x] AI onboarding protocol (`.lovable/prompts/01-read-prompt.md`)
- [x] `overview.md`, `strictly-avoid.md`, `suggestions.md`, `prompt.md`
- [x] Dynamic dev-dir banner in `run.ps1`

### v0.23.x - v0.26.0
- [x] Scripts 42 (Ollama) + 43 (llama.cpp) with CUDA/AVX2 detection
- [x] 81-model GGUF catalog with 4-filter chain (RAM → Size → Speed → Capability)
- [x] `aria2c` accelerated downloads with fallback
- [x] `.installed/` tracking for models

### v0.16.x - v0.22.x
- [x] Audit, Status, Doctor commands
- [x] Scripts 37-41 (WT, Flutter, .NET, Java, Python libs)
- [x] Settings export system (NPP, OBS, WT, DBeaver)
- [x] Combo shortcuts (backend, full-stack, data-dev, mobile-dev)

---

## 🚫 Avoid / Skipped

| Item | Reason |
|------|--------|
| Split `spec/install-bootstrap/readme.md` into sub-files | Suggested but not approved by user — keep as single 224-line file |
| Modify `.gitmap/release/` folder | Hard rule from `strictly-avoid.md` #7 |

---

## Architecture Notes

- 43 PowerShell scripts in `scripts/` folder
- Shared helpers in `scripts/shared/` (logging, path-utils, choco-utils, etc.)
- External JSON configs per script (`config.json`, `log-messages.json`)
- `.installed/` tracking for idempotent installs
- `.resolved/` for runtime state persistence
- `settings/` folder for app config sync (NPP, OBS, WT, DBeaver)
- Spec docs in `spec/` folder per script
- Bootstrap installers (`install.ps1`, `install.sh`) auto-discover newer `scripts-fixer-vN` repos
