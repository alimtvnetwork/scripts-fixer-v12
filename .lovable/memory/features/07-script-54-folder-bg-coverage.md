---
name: Script 54 folder+background coverage check
description: check/verify and post-op verification confirm BOTH directory and background verbs exist under the resolved scope, list every missing sub-key (parent, \command, (Default), Icon) with the exact path
type: feature
---
## Folder + background coverage in check / verify / post-op verification

`check` and `verify` (and the post-install / post-uninstall verification
block run by install/uninstall/repair/sync) now explicitly confirm BOTH
`directory` and `background` verbs exist under the **resolved scope**,
and list every missing sub-key with its exact registry path.

### Per-target probe (`Get-VsCodeMenuEntryStatus`)
- Tracks `expectedSubkeys = ['(Default)', 'Icon', 'command', 'command\(Default)']`.
- Collects `missingSubkeys` instead of bailing on the first failure --
  the operator sees the WHOLE story per target in one pass.
- Verdict reason now appends `missing sub-keys/values: …` so the JSONL
  log + console match.

### Per-edition coverage line (`Invoke-VsCodeMenuCheck`)
- After the per-target rows, prints:
  `[OK ] folder+background coverage in <hive label>: folder=PASS, background=PASS`
  or `[GAP ]` with a follow-up `- directory verb MISSING at: <path>` /
  `- background verb MISSING at: <path>` line per failing verb.
- Hive label reflects `-Scope`:
  - AllUsers   -> `HKCR (machine-wide)`
  - CurrentUser-> `HKCU\Software\Classes (per-user)`
  - omitted    -> `HKCR (merged view)`
- Result object gains `folderPresent`, `bgPresent`, `coverageOk`.

### Post-op verification (`Invoke-PostOpVerification`)
- Install branch now requires both the parent key AND `\command` to exist
  (an empty key with no `\command` would render as a no-op menu item).
- Failure rows print one line per missing piece, e.g.
  `- missing sub-key: ...\command (failure: \\command not created -- the menu would do nothing)`.
- Per-edition `[OK ]/[GAP ]` coverage line that names the resolved scope.

### CODE RED compliance
Every missing sub-key/value is reported with the exact registry path
(`<regPath>\command`, `<regPath>  -> value: Icon`, etc.) and a failure
reason -- matches the toolkit-wide rule.

Built: v0.130.0. Backwards compatible: detail records gain new fields
(`missingSubkeys`, `missingChildren`, `folderPresent`, `bgPresent`,
`coverageOk`); existing callers ignore them.