# Suggestion 01 — Model Catalog Auto-Update

**Status:** Spec ready, implementation pending
**Target file:** `scripts/43-install-llama-cpp/models-catalog.json`
**New helper:** `scripts/43-install-llama-cpp/helpers/catalog-update.ps1`

## Goal

Periodically check Hugging Face for **new GGUF releases** of the
model families already in the catalog (Qwen, Llama, Gemma, Phi, etc.)
and propose additions without auto-merging.

## Behavior

1. Read `models-catalog.json` and group existing entries by `family`.
2. For each family, hit the Hugging Face API:
   `https://huggingface.co/api/models?search=<family>+gguf&sort=lastModified&limit=20`
3. For each repo returned, list `*.gguf` files in the repo's tree.
4. Filter out entries whose `id` already exists in the catalog (by
   matching `huggingfacePage` host+path prefix).
5. Build a **proposal list** (do not modify the catalog directly).
6. Write `scripts/43-install-llama-cpp/.proposed/catalog-additions-<date>.json`
   with each proposal pre-filled (id placeholder, downloadUrl,
   fileName, sha256: "", rating placeholders).
7. Print a colorized summary to console.

## Invocation

```powershell
.\run.ps1 -I 43 -- --check-updates
# or
.\run.ps1 install llama-cpp --check-updates
```

- `--apply` flag merges proposals into the catalog after manual review.
- `--family <name>` limits to one family per run.

## Rate limiting

- Cache HF API responses for 6 hours under
  `scripts/43-install-llama-cpp/.cache/hf-<family>.json`.
- Hit at most 10 families per run.

## Logging

| Prefix | When |
|--------|------|
| `[CHECK]` | Family being scanned |
| `[NEW]` | New GGUF found |
| `[CACHED]` | Result served from cache |
| `[PROPOSE]` | Wrote proposal file |

## Out of scope

- Automatic merging into the catalog.
- Rating estimation (humans must fill ratings).
- SHA256 population — see `02-sha256-population.md`.