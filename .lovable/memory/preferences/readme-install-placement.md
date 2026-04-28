---
name: README install placement
description: Exact layout of the Install section in root readme.md — local commands first, then fresh-machine one-liners
type: preference
---
The root `readme.md` Install section MUST follow this exact order and structure, immediately after the intro block (before "At a Glance"):

1. One sentence: "Use the installer scripts at the root of this repository: `install.ps1` and `install.sh`."
2. Lead-in line: "If you already have this repo, these are the first commands to run:"
3. **### Windows (PowerShell 5.1+)** heading + fenced powershell block containing ONLY:
   ```
   .\install.ps1
   ```
4. **### Unix / macOS (bash)** heading + fenced bash block containing ONLY:
   ```
   bash ./install.sh
   ```
5. Lead-in line: "Fresh-machine one-liners that fetch those same root scripts:"
6. Fenced powershell block:
   ```
   irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex
   ```
7. Fenced bash block:
   ```
   curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash
   ```
8. Then the PowerShell ExecutionPolicy bypass note follows.

**Why:** Local clone usage is the primary path; remote one-liners are secondary. Order must be: local Windows → local Unix → remote Windows → remote Unix.

**How to apply:** Never reorder. Never put GitMap CLI or external repo one-liners here. Never collapse local + remote into one block. Never swap Windows/Unix order.
