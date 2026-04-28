---
name: README install placement
description: Exact layout of the Install section in root readme.md — 4 labeled remote one-liner blocks, no local commands
type: preference
---
The root `readme.md` Install section MUST follow this exact 4-block structure, immediately after the intro block (before "At a Glance"). Each block is its own `###` heading with an emoji + OS label, followed by a single fenced code block.

**Order and exact headings:**

1. `### 🪟 Windows · PowerShell`
   ```powershell
   irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1 | iex
   ```

2. `### 🪟 Windows · PowerShell · skip latest-version probe`
   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.ps1)))
   ```

3. `### 🐧 macOS · Linux · Bash`
   ```bash
   curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash
   ```

4. `### 🐧 macOS · Linux · Bash · skip latest-version probe`
   ```bash
   curl -fsSL https://raw.githubusercontent.com/alimtvnetwork/scripts-fixer-v12/main/install.sh | bash -s -- --skip-latest-probe
   ```

**Hard rules:**
- NEVER include local `.\install.ps1` or `bash ./install.sh` commands in this section. Removed entirely per user direction.
- NEVER reorder the 4 blocks. Windows always before macOS/Linux. Plain always before skip-probe variant.
- NEVER collapse two blocks into one. Each gets its own heading + fenced code block.
- NEVER use external repo URLs (e.g. coding-guidelines, GitMap). Always `alimtvnetwork/scripts-fixer-v12`.
- The PowerShell ExecutionPolicy bypass note may follow AFTER all 4 blocks.

**Why:** User wants the screenshot-style 4-block layout (matching coding-guidelines-v17 readme) but pointing at THIS repo. Local commands are not wanted in the Install section at all.
