---
name: Models catalog (90 GGUFs + leaderboard)
description: scripts/43-install-llama-cpp/models-catalog.json holds 90 models incl. open-weight OpenRouter leaderboard. models-list.md auto-generated.
type: feature
---

# Models Catalog

## Counts
- **90 unique models** across **33 families** in `scripts/43-install-llama-cpp/models-catalog.json`
- Catalog version `4.1.0` (bumped from 4.0.0 in v0.95.0)
- 9 datacenter-class (>=64 GB RAM): DeepSeek V3.2, Kimi K2.6, GLM 5.1, MiniMax M2/M2.7, Nemotron 3 Super 120B, gpt-oss-120b, Qwen 3.5 122B-A10B, DeepSeek R1 70B
- All 90 have valid `downloadUrl` (HF resolve URL); 10 have `leaderboardRank` field

## OpenRouter Leaderboard Coverage (Nov 2025)
Open-weight only - closed-source API models intentionally excluded:
- #1 MiMo-V2-Flash (Xiaomi) - using Flash since Pro has no GGUF
- #2 Qwen 3.6 27B (Alibaba)
- #3 DeepSeek V3.2 (671B MoE, datacenter)
- #5/#8 MiniMax M2 / M2.7 (230B MoE)
- #9 StepFun Step 3.5 Flash (10B VL)
- #12 NVIDIA Nemotron 3 Super 120B-A12B
- #14/#20 Z.AI GLM 5.1 (covers GLM 5 and GLM 5 Turbo)
- #15 Moonshot Kimi K2.6 (1T MoE, datacenter)
- #17 OpenAI gpt-oss-120b

## Capability Flags
`isCoding`, `isReasoning`, `isWriting`, `isVoice`, `isMultilingual`, `isChat`, plus `leaderboardRank` (optional int).

## Generated Docs
`scripts/43-install-llama-cpp/models-list.md` is auto-generated from the catalog. Run `python3 /tmp/gen_models_list.py` to regenerate after catalog edits (script lives in /tmp during dev).

## Root README Section
"Local AI Models - 90 GGUFs + Ollama" section + AI Models badge link to models-list.md.

## Known Pre-existing Issue (FIXED in v0.95.0)
Old catalog had duplicate `phi-4-14b` id at indexes 12 and 76. Deduped during the leaderboard import.
