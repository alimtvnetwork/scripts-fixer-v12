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
