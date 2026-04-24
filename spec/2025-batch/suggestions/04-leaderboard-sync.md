# Suggestion 04 - OpenRouter Leaderboard Sync

**Status:** Initial seeding done in v0.95.0 (10 open-weight models added).
**Target file:** `scripts/43-install-llama-cpp/models-catalog.json`
**Docs:** `scripts/43-install-llama-cpp/models-list.md` (auto-generated)

## Goal

Periodically re-scan the OpenRouter LLM leaderboard and propose
catalog additions for the **open-weight** portion only.

## Scope rules (locked in v0.95.0)

1. **Open-weight only.** Closed-source API models (Claude, GPT-5.x,
   Gemini, Grok) MUST NOT enter the catalog — they cannot be downloaded
   as GGUF files for `llama.cpp`/`Ollama`.
2. Each leaderboard entry gets a `leaderboardRank: <int>` field for
   provenance, plus `leaderboardSource: "OpenRouter LLM Leaderboard (<date>)"`.
3. XLarge models (>= 64 GB RAM) are allowed but tagged so the picker's
   RAM filter naturally hides them on commodity hardware.
4. When a leaderboard model has multiple variants (Pro/Flash/Plus),
   pick the largest variant that has a public GGUF; fall back to the
   next-best variant. Document the substitution in `notes`.

## Algorithm

1. Fetch leaderboard HTML (or JSON if available) from OpenRouter.
2. For each row, classify as `open` or `closed-api`:
   - `closed-api` if vendor is in `{anthropic, openai-non-oss, google,
     x-ai}` AND model id lacks an `oss` / `gpt-oss` suffix.
3. For `open` rows, query Hugging Face for `<vendor>/<model>-GGUF` or
   `unsloth/<model>-GGUF` or `bartowski/<model>-GGUF`.
4. If a GGUF repo exists, build a proposal entry; else log `[NO-GGUF]`.
5. Write proposals to `.proposed/leaderboard-<YYYY-MM>.json`.

## Hand-off

Generated proposals must be reviewed manually for `ramRequiredGB`,
`fileSizeGB`, and `bestFor` before merging. The catalog must always
pass:
```
python3 -c "import json; d=json.load(open('models-catalog.json')); ids=[m['id'] for m in d['models']]; assert len(ids)==len(set(ids))"
```

## Out of scope

- Auto-merging proposals.
- Tracking the closed-source half of the leaderboard.
- Removing models when they fall off the leaderboard (catalog only grows).
