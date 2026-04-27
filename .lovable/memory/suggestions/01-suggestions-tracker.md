---
name: Suggestions tracker
description: Consolidated tracker of all suggestions -- implemented and pending
type: feature
---

# Suggestions Tracker

## Completed Suggestions

### Model Picker & Catalog
- [x] Interactive numbered model selection with range/mixed syntax
- [x] 81-model GGUF catalog with rich metadata (params, quant, size, RAM, capabilities)
- [x] Capability filter (coding, reasoning, writing, chat, voice, multilingual)
- [x] RAM-based filter with auto-detection via WMI
- [x] Download size filter (5 tiers: Tiny to XLarge)
- [x] Speed tier column (instant/fast/moderate/slow based on fileSizeGB)
- [x] Speed-based filter with multi-select support
- [x] 4-filter chain: RAM -> Size -> Speed -> Capability
- [x] aria2c accelerated downloads with Invoke-DownloadWithRetry fallback
- [x] .installed/ tracking for model downloads
- [x] Starred models (recommended) grouped first with color-coded ratings

### Hardware Detection
- [x] CUDA GPU detection (nvidia-smi, nvcc, WMI) for executable variant filtering
- [x] AVX2 CPU support detection for CPU-only fallback variants
- [x] Incompatible variants skipped with clear logging

### New Models Added (v0.26.0)
- [x] Gemma 3 (1B, 4B, 12B) from Google
- [x] Llama 3.2 (1B, 3B) from Meta
- [x] SmolLM2 1.7B from HuggingFace
- [x] Phi-4 Mini 3.8B and Phi-4 14B from Microsoft
- [x] Granite 3.1 (2B, 8B) from IBM
- [x] Qwen3 1.7B from Alibaba
- [x] Functionary Small v3.1 8B from MeetKai

## Pending Suggestions

### High Priority
- [x] Model catalog auto-update -- helper shipped at `scripts/43-install-llama-cpp/helpers/catalog-update.ps1` (spec `spec/2025-batch/suggestions/01-catalog-auto-update.md`); invoke via `.\run.ps1 -CheckUpdates [-Family Qwen] [-Apply]` (v0.76.0)
- [~] SHA256 checksums in catalog -- verification logic shipped; spec for population helper at `spec/2025-batch/suggestions/02-sha256-population.md`; data fill pending
- [x] Parallel model downloads (aria2c batch) -- shipped at `scripts/shared/aria2c-batch.ps1`; wired into `Install-SelectedModels` with per-file fallback to sequential on failure. Tunables in `config.json -> download`. Spec `spec/2025-batch/suggestions/03-parallel-downloads.md` (v0.77.0)

### Medium Priority
- [ ] GUI/TUI interface for model picker (curses or Windows Forms)
- [ ] Model benchmarking -- run a quick inference test after download
- [ ] Model size estimation from parameter count (when fileSizeGB unknown)
- [ ] Export/import model selections as preset files

### Low Priority
- [ ] Cross-machine settings sync via cloud storage
- [ ] Linux/macOS support for scripts
- [ ] Docker, Rust script additions
- [ ] Model catalog web viewer (React page in the project)

## Script 01 — MIME cleanup (added v0.165.0)

- **Snap user-namespace mimeapps**: Snap installs of VS Code keep a
  per-revision `~/snap/code/current/.config/mimeapps.list` that survives
  `snap remove`. Add it to `mimeCleanup.userFiles[]` with a glob
  expansion step (current shell expansion only handles `${HOME}`).
- **xdg-mime re-default**: After scrubbing, optionally call
  `xdg-mime default <fallback>.desktop <mimetype>` to point each scrubbed
  MIME at a sensible runner-up (e.g. `gedit.desktop` for `text/plain`).
  Needs an opinionated fallback table -- defer until a user asks.
- **Dry-run flag**: Add `verb_uninstall --dry-run` that reports which
  lines WOULD be scrubbed without writing. Useful for ops review.
- **Backup retention**: `.bak-01-<timestamp>` files accumulate over
  repeat uninstalls. Add a 30-day reaper or keep-last-N policy.

## Script 01 — .desktop entry scrub (added v0.166.0)

- **Reverse-cleanup mode for partial reinstalls**: After scrubbing, the
  next `apt-get install code` re-writes the original `MimeType=`/`Actions=`
  lines unmodified. Add `verb_install --no-mime-claim` that re-runs
  `_clean_vscode_desktop_entries` post-install for users who want to
  keep VS Code on disk but stop it claiming MIME ownership.
- **`X-Desktop-File-Install-Version` audit**: Some distros (Solus,
  openSUSE) inject `X-Desktop-File-Install-Version=...` lines that may
  contain MIME-claim metadata in custom keys. Add a vendor-extension
  audit pass that warns (but does not strip) unknown `X-*` keys.
- **Per-extension cleanup**: Some VS Code extensions (e.g. PlatformIO,
  Quarto) write THEIR OWN `.desktop` files into
  `~/.config/Code/User/globalStorage/<ext-id>/`. Deferred until a user
  reports it; would need an extension-driven allow-list rather than a
  static list.
- **Action-block whitelist**: Right now we drop ALL `[Desktop Action *]`
  blocks. A user might want to keep `[Desktop Action new-empty-window]`
  (it's harmless and useful) and only drop the MIME-related ones. Add
  `mimeCleanup.preserveActions[]` to keep named blocks.

## Script 01 — context menu cleanup (added v0.167.0)

- **Glob-aware fileNames**: Right now fileNames[] is exact basename
  match. Add support for `glob:open-with-code-*.sh` patterns for
  distros (e.g. Solus) that suffix locale into the script name.
- **Thunar uca.xml.d XML-aware edit**: Thunar uses a single
  `~/.config/Thunar/uca.xml` (NOT a directory of files) listing all
  user-defined actions. Add XML-aware xmlstarlet pass that strips only
  `<action><name>Open with Code</name>...</action>` blocks.
- **KDE ServiceMenus**: Dolphin's "Open with Code" lives in
  `~/.local/share/kio/servicemenus/openwithcode.desktop` and
  `~/.local/share/kservices5/ServiceMenus/`. Add a fourth allow-list
  pair when a KDE user reports it.
- **MATE / LXDE / XFCE custom-actions**: Each desktop env has its own
  side-channel. Defer until we get a bug report -- premature abstraction
  otherwise.
- **Restore command**: Add `verb_restore` that walks `.bak-01ctx-*`,
  `.bak-01-*`, and `.bak-01de-*` files and copies them back over the
  current path. Useful if cleanup was too aggressive.

## Script 01 — scoped cleanup (added v0.168.0)

- **`--force` flag** to override empty-scope REPORT-ONLY mode without
  setting env vars (cleaner CLI than `VSCODE_CLEAN_METHODS=...`).
- **Multi-method fingerprints**: Today fingerprint stores ONE method.
  If a user runs install twice (apt then snap fallback succeeded), only
  the last one is tracked. Append to a methods array instead.
- **Version-pin scope**: fingerprint already captures version; add a
  `--require-version <X.Y.Z>` guard so uninstall refuses if the
  installed binary version doesn't match the fingerprint (prevents
  scrubbing a manually-upgraded install we didn't track).
- **Per-method post-install hooks**: snap installs need
  `snap connect code:removable-media` etc. Add a `postInstallHooks`
  block keyed by method.

## Script 01 — verification (added v0.169.0)

- **JSON output mode** (`./run.sh verify --json`) so other scripts
  (Lovable Cloud function, dashboard tile) can consume the snapshot.
- **Persist snapshots** to `.installed/01.verify-<timestamp>.tsv` so
  multiple uninstall runs can be compared longitudinally.
- **Exit codes**: today `verb_verify` always returns 0; switch to
  exit 1 when residue is found, exit 2 on probe error. Lets CI gate on it.
- **`xdg-mime query` for ALL registered text mimes** instead of the
  curated 11-entry list — use `xdg-mime query` with the output of
  `awk -F= '/MimeType=/' code.desktop` to be exhaustive.
- **Probe KDE Plasma** (`~/.local/share/kservices5/ServiceMenus/`,
  `~/.config/kdeglobals` `[General]Keyboard` defaults).
- **Probe Plasma activity-aware MIME defaults** in
  `~/.config/plasma-org.kde.plasma.desktop-appletsrc`.

## Script 68 -- strict schema (added v0.170.0)

- **Cross-record duplicate detection**: today two records with the same
  `name` both run; second one hits "user exists" and is a no-op. Catch
  duplicates pre-flight and warn.
- **`uid` reservation conflict**: validate that two records don't request
  the same explicit `uid`.
- **`--strict-unknown` flag** to escalate `schemaUnknownField` warnings
  into rejections (today they are warnings only).
- **Fail-fast mode (`--fail-fast`)**: stop processing the batch on first
  rejected record instead of continuing.
- **Schema doc generator**: emit `schema.json` (JSON Schema draft-07)
  from the same allow-list so external tools (VS Code JSON validation,
  Ansible templates, CI) can validate at edit time.
- **Apply same validator to add-group-from-json.sh** -- it has the same
  silent-skip bug for `members[]`.

## Script 68 -- sshKeyUrls (added v0.171.0)

- **Pin host fingerprints**: today the host allowlist trusts the system
  CA bundle. For zero-trust setups, allow `sshKeyUrlPin: "sha256/abc..."`
  (curl `--pinnedpubkey`).
- **TTL/refresh mode**: re-fetch URL keys on a schedule (cron) so a
  rotated GitHub key propagates without re-running the JSON apply.
- **gpg-verified URL**: support `https://example.com/keys.asc` plus a
  pinned signing key, only install if signature verifies.
- **Per-URL allowlist override** in the URL itself (e.g. trailing
  `#allow=keys.example.com`) so one bad URL can't open the gate for
  others in the same record.
- **Negative caching**: remember failed URL fetches for N minutes so a
  flaky DNS or 503 doesn't burn the timeout budget on every batch run.
- **Audit trail**: append every (url, http_code, bytes, fingerprint, ts)
  to `.installed/68.url-fetch.log` so post-incident review can see
  exactly which keys came from where and when.
