# 10 - install.ps1 / install.sh: --version + --help parity

**Spec reference:** "Verify and implement a working --version flag across
the Windows install.ps1 and the Linux install.sh bootstrappers with
consistent version reporting."

## Findings (verification)

- Both bootstrappers already had a `--version` / `-Version` flag, but it
  reported only the bootstrap repo number (`v8`) - not the payload
  semver from `scripts/version.json`. That is a partial answer at best.
- Neither had a `--help` / `-Help` flag.
- Output formatting and label wording differed slightly.

## Inference used (Option B)

Made both implementations report **identical** information in the same
order, with the same label widths:

```
[VERSION] Bootstrap repo : scripts-fixer-v8
[VERSION] Payload semver : 0.148.0
[SCAN]    Probing v9..vN for newer releases (parallel)...
[FOUND]   Newer repo     : scripts-fixer-vN
[FOUND]   Newer semver   : X.Y.Z
[RESOLVED] Would redirect to scripts-fixer-vN
```

- Added a best-effort `Get-PayloadSemver` (PS) / `fetch_payload_semver`
  (bash) that fetches `scripts/version.json` from the resolved repo's
  `main` branch and parses the `version` field. On any failure
  (network, missing file, malformed JSON, missing curl /
  Invoke-WebRequest) it returns `(unknown)` -- version reporting must
  never crash the bootstrap.
- Added matching `--help` / `-Help` blocks documenting `--version`,
  `--no-upgrade`, `--dry-run`, plus the env vars.
- Added `-V` short alias for `--version` in bash and `-h` for `--help`,
  matching common Unix conventions. PowerShell uses `-Version` /
  `-Help` (no aliases - PS already auto-prefixes).
- PowerShell `param(...)` now also declares `-DryRun` formally so the
  existing `$DryRun` references inside the script bind correctly.

## Verification

- `bash install.sh --help` -> prints help block, exits 0.
- `bash install.sh --version` -> fetches semver from GitHub, prints both
  current + latest repo & semver, exits 0. Confirmed against live
  scripts-fixer-v8 (semver 0.43.2) and scripts-fixer-v10 (semver
  0.95.0).
- `pwsh install.ps1 -Help` -> identical help block, returns.
- `pwsh install.ps1 -Version` -> identical output to bash side.
  Confirmed with PowerShell 7.5.4 via nix.
- `[Parser]::ParseFile('install.ps1', ...)` reports zero parse errors.

## How to revert

Revert the `Help` / `Get-PayloadSemver` blocks and the new `[VERSION]` /
`[FOUND]` print statements in both `install.ps1` and `install.sh`.
