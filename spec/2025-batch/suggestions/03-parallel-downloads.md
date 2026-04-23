# Suggestion 03 - Parallel Model Downloads via aria2c Batch Input

**Status:** Implemented in v0.77.0
**Helper:** `scripts/shared/aria2c-batch.ps1` (`Invoke-Aria2BatchDownload`)
**Caller:** `scripts/43-install-llama-cpp/helpers/model-picker.ps1` (`Install-SelectedModels`)
**Config:** `scripts/43-install-llama-cpp/config.json` -> `download` block

## Goal

When the user picks multiple models in one session, download them
concurrently using aria2c's batch input file feature instead of one
at a time.

## Current behavior (to preserve as fallback)

`model-picker.ps1` loops over selections and calls
`Invoke-Aria2Download` once per model. Sequential, simple, robust.

## New behavior

1. After the user confirms selections, build an aria2c **input file**:
   ```
   <url1>
     out=<filename1>
     dir=<install-dir>
   <url2>
     out=<filename2>
     dir=<install-dir>
   ```
   (Note: continuation lines must be indented with at least one space.)
2. Write to a temp path: `$env:TEMP\aria2c-batch-<timestamp>.txt`.
3. Run:
   ```
   aria2c --input-file=<temp> --max-concurrent-downloads=3 `
          --max-connection-per-server=8 --split=8 --continue=true `
          --auto-file-renaming=false --console-log-level=warn `
          --summary-interval=5
   ```
4. After exit, walk the selection list and verify each `outputPath`
   exists + matches `sha256` (reuse the existing verification block).
5. On any single-file failure, fall back to the sequential path **for
   that file only** (do not re-download files that already succeeded).

## Tunables (config.json)

Add to `scripts/43-install-llama-cpp/config.json`:
```json
"download": {
  "parallelEnabled": true,
  "maxConcurrent": 3,
  "connectionsPerServer": 8,
  "splitsPerFile": 8
}
```

## Disk-space precheck

Before launching the batch, sum `fileSizeGB` of all selections and
compare to free space on the target drive. If insufficient, prompt
user to deselect some, **do not start** the batch.

## Logging

| Prefix | When |
|--------|------|
| `[BATCH]` | Wrote batch input file with N entries |
| `[PARALLEL]` | aria2c started with concurrency K |
| `[VERIFY]` | Per-file post-download SHA256 check |
| `[FALLBACK]` | Reverting to sequential for file X |

## Edge cases

- **User picks 1 model:** skip batch mode, use sequential (no benefit).
- **aria2c missing:** existing fallback to `Invoke-DownloadWithRetry`
  must run sequentially (no parallel HTTP/2 multiplexing in fallback).
- **Resume after Ctrl-C:** aria2c writes `.aria2` control files; on
  re-run, the batch resumes any partials transparently.
- **CODE RED:** any failure logs the exact target path via
  `Write-FileError`.

## Verification

```powershell
# Pick 3 small models, expect roughly 3x throughput vs sequential
.\run.ps1 install llama-cpp
# In picker: select 3 models < 2GB each
# Confirm aria2c console shows 3 concurrent downloads
```

## Out of scope

- Cross-host load balancing (HF only).
- BitTorrent / IPFS sources.