---
name: Tool-version parser registry
description: Per-tool parsers in scripts/shared/tool-version-parsers.ps1 used by Ensure-Tool to store accurate versions
type: feature
---
Per-tool version parser registry lives at `scripts/shared/tool-version-parsers.ps1`.

`Ensure-Tool` (in `scripts/shared/ensure-tool.ps1`) auto-sources it and, when no
`-ParseScript` is supplied, looks up a parser by `-Name` so the
`.installed/<name>.json` ledger stores a clean version string.

Built-ins: git, node/nodejs, python, go, java, dotnet, rustc, pnpm, choco.
Fallback: first dotted semver-ish token, then trimmed raw text.

Add new tools at runtime with:
```powershell
Register-ToolVersionParser -Name "kubectl" -Parser { param($raw) ... }
```

Explicit `-ParseScript` on `Ensure-Tool` still wins over the registry.
Spec: `spec/shared/tool-version-parsers.md`.
