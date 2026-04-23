# Suggestion 02 — Populate SHA256 Checksums

**Status:** Verification logic already shipped; only the catalog data
is missing.
**Target file:** `scripts/43-install-llama-cpp/models-catalog.json`
(81 entries, all with `"sha256": ""`)
**New helper:** `scripts/43-install-llama-cpp/helpers/sha256-fill.ps1`

## Why this is split from the verification work

`helpers/model-picker.ps1` already verifies SHA256 when present (lines
532-547). The runtime is correct; the catalog is the gap.

## Strategy

Hugging Face publishes per-file SHA256 in two places:
1. `https://huggingface.co/<repo>/raw/main/<file>` — the **`X-Linked-Etag`**
   HTTP response header on a HEAD request often equals the file's
   SHA256 (LFS-tracked files only — applies to all GGUF files).
2. The repo's `model-index.json` or `<file>.sha256` sidecar when present.

## Algorithm

1. Iterate every entry where `sha256 == ""`.
2. `HEAD <downloadUrl>` and read `X-Linked-Etag`.
3. If header present and matches `^[a-f0-9]{64}$`, set
   `entry.sha256 = <value>`.
4. If header missing, log `[MANUAL]` and skip.
5. Write the catalog atomically (temp file + rename) and print a diff.

## Invocation

```powershell
.\run.ps1 -I 43 -- --fill-sha256
# Optional: limit to specific ids
.\run.ps1 install llama-cpp --fill-sha256 --ids "qwen2.5-coder-3b,gemma-3-4b"
```

## Safety

- Make a backup copy `models-catalog.json.bak-<timestamp>` before write.
- Never overwrite a non-empty `sha256` field (idempotent).
- Validate hex format before assigning.

## Logging

| Prefix | When |
|--------|------|
| `[FETCH]` | Issuing HEAD |
| `[FILL]` | sha256 assigned |
| `[MANUAL]` | Header missing — manual entry needed |
| `[SKIP]` | Already populated |

## Verification

After running, expect:
```bash
grep -c '"sha256": "[a-f0-9]\{64\}"' models-catalog.json   # > 0
grep -c '"sha256": ""'              models-catalog.json   # decreased
```

## Out of scope

- Cryptographic signature verification (GPG / Sigstore) — separate spec.
- Automatic re-fetch when a HF repo updates a file (catalog is a
  pinned snapshot by design).