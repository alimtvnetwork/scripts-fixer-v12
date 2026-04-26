---
name: script 67 binary detector + resolve verb
description: Adds 'binary' install method (raw code shim with no dpkg/snap owner) plus new probe kinds (cmd-no-pkg-owner, symlink-into-roots) and a resolve verb that prints a single classification line + structured exit code.
type: feature
---
## Script 67 v0.137.0 -- binary detector + `resolve` verb

### New install method: `binary`
Hits when `code` (or `code-insiders`) is on PATH but
- NOT owned by dpkg (`dpkg -S` returns nothing for the resolved real path)
- NOT a snap (`snap list <pkg>` fails)
- NOT inside a known tarball root (configurable list)

Two new probe kinds in `helpers/detect.sh`:
- `cmd-no-pkg-owner <pkg>` -- binary on PATH, no dpkg owner, not a snap, not in tarball roots
- `symlink-into-roots <pkg>` -- `command -v <pkg>` resolves to a symlink whose ultimate target lives under one of the configured roots (the "tarball + manual `ln -s`" install style)

Both new probe kinds receive the tarball root list via env var `DETECT_PROBE_ROOTS` (colon-separated), exported by `run.sh` from the `roots` field on each probe in `config.json`.

### New verb: `resolve`
Detect-only, prints a single machine-parseable line:
```
method=<apt|snap|deb|tarball|binary|user-config|none>  edition=<stable|insiders|both>  detail='<probe detail>'
```
Exit codes:
- `0` exactly one primary method present
- `1` multiple primary methods present (still picks the most specific)
- `2` none detected
- `3` jq missing / internal error

Specificity order: `apt > snap > deb > tarball > binary > user-config` (user-config is auxiliary and never the primary classification).

Manifest at `.logs/67/<TS>/manifest.json` adds `resolved` and `edition` fields.

### New top-level shortcut in `scripts-linux/run.sh`
- `vscode-resolve-linux` (also `vscode-clean-linux-resolve`, `vscode-linux-resolve`)

### `binary` action recipe
Removes ONLY the unowned shim/binary itself + per-user `.desktop` file. Never recurses into a directory. Tarball roots are intentionally NOT touched (the `tarball` method owns those):
- `/usr/local/bin/{code,code-insiders}` (sudo)
- `/usr/bin/{code,code-insiders}` (sudo)
- `$HOME/.local/bin/{code,code-insiders}`
- `$HOME/.local/share/applications/{code,code-insiders}.desktop`

### Verified
- Empty system -> exit 2, `method=none`
- Fake binary in PATH (no dpkg owner) -> exit 0, `method=binary edition=stable`
- Symlink shim pointing into tarball root + tarball root present -> exit 1, `method=tarball` (resolver picks the more specific method, multi-method warning logged)
- `cmd-no-pkg-owner` correctly suppressed when target is inside a known tarball root (no double-classification)
- bash -n + JSON validation + shellcheck (-S warning) clean (only pre-existing SC2120)

Built: v0.137.0.
