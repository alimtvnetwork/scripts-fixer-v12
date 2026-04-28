# Config Bridge

A tiny localhost HTTP server that lets the Lovable web app's `/settings`
page write `config.json` files **on your local machine**.

## Why it exists

The React app runs in a browser sandbox and cannot touch your filesystem.
The bridge runs **on your machine** and exposes a small HTTP API the page
calls. Settings flow:

```
Browser (/settings)  --POST-->  http://127.0.0.1:7531/config?script=52
                                            |
                                            v
                          scripts/52-vscode-folder-repair/config.json
```

## Run it

```powershell
# From the repo root
.\tools\config-bridge.ps1                   # default port 7531, no token
.\tools\config-bridge.ps1 -Port 8080
.\tools\config-bridge.ps1 -Token "secret"   # require X-Bridge-Token header on POST
```

Keep the window open while you use the Settings page. Ctrl+C to stop.

## Endpoints

| Method | Path                          | Description                                       |
| ------ | ----------------------------- | ------------------------------------------------- |
| GET    | `/health`                     | Returns `{ ok, root, scripts }`                   |
| GET    | `/config?script=<id>`         | Read current config.json                          |
| POST   | `/config?script=<id>`         | Overwrite config.json (body = full JSON object)   |
| PATCH  | `/config?script=<id>`         | Deep-merge partial options into stored config     |
| POST   | `/config/options?script=<id>` | Alias of PATCH (for clients that can't send PATCH)|

Allowed `<id>` values are whitelisted in the script (`52`, `31` by default).
Add more entries to `$allowedScripts` to expose other configs.

### PATCH / options merge

The Settings UI uses `PATCH /config?script=<id>` to send only the options the
user changed. The bridge:

1. Loads the existing `config.json` (or `{}` if missing).
2. Deep-merges the patch object: nested objects merge key-by-key; arrays and
   scalars in the patch replace whatever was in the stored config.
3. Backs up the previous file to `config.json.<timestamp>.bak`.
4. Writes the merged JSON.
5. Returns `{ ok, path, bytes, config }` where `config` is the updated model.

Example:

```bash
curl -X PATCH "http://127.0.0.1:7531/config?script=52" \
     -H "Content-Type: application/json" \
     -H "X-Bridge-Token: my-secret" \
     -d '{"contextMenu":{"enabled":true},"edition":"insiders"}'
```

## Safety

- Binds to **127.0.0.1 only** — never reachable from the network.
- Optional `-Token` enforces `X-Bridge-Token: <token>` on writes (POST + PATCH).
- Each successful write first copies the existing file to
  `config.json.<timestamp>.bak` next to it.
- Rejects any payload that isn't valid JSON; PATCH also requires a JSON object.
- Every file/path error logs **exact path + reason** (CODE RED rule).

---

## scan-legacy-fixer-refs (.ps1 / .sh)

Audit the repo for any remaining mentions of legacy `scripts-fixer-vN`
generations (default `v8`, `v9`, `v10`). Use after a migration to confirm
nothing slipped through.

```powershell
# Windows
.\tools\scan-legacy-fixer-refs.ps1                    # default v8/v9/v10
.\tools\scan-legacy-fixer-refs.ps1 -Versions 8,9,10,11
.\tools\scan-legacy-fixer-refs.ps1 -Paths tools,src   # restrict to folders
```

```bash
# Unix / macOS
bash tools/scan-legacy-fixer-refs.sh                   # default v8/v9/v10
SCAN_VERSIONS="8|9|10|11" bash tools/scan-legacy-fixer-refs.sh
SCAN_ROOT="/path/to/repo" bash tools/scan-legacy-fixer-refs.sh
SCAN_PATHS="tools/ src/"  bash tools/scan-legacy-fixer-refs.sh
bash tools/scan-legacy-fixer-refs.sh --paths tools/,src/
```

**Path filter:** `-Paths` (PowerShell) and `--paths` / `SCAN_PATHS` (Bash)
restrict the scan to the listed repo-relative folders or files. Each entry
must exist or the scanner aborts with a CODE RED file error and exit `2`.
Omit the flag to scan the entire repo (default).

Exit codes: `0` PASS (no matches) · `1` FAIL (matches grouped by file with
a per-version summary) · `2` error (logs exact path + reason).

---

## fix-and-verify-legacy-refs (.ps1 / .sh)

**Single command** that runs the full migration safety net in one shot:

1. **Dry-run** the fixer to preview every file that would change (no writes).
2. **Apply** the rewrite with **timestamped backups** under
   `.legacy-fix-backups/<UTC-timestamp>/<repo-relative-path>`. Backups are
   on by default and the chosen directory is recorded in
   `legacy-fix-report.json` under `backupDir`.
3. **Scan** the result. If the scanner reports FAIL, the pipeline
   **automatically rolls back** every file from the backup so the repo is
   restored to its pre-apply state. The whole command only exits `0` when
   the scanner reports PASS, so a green exit guarantees the repo is clean.

If the dry-run or apply step itself fails, the pipeline aborts before later
steps run and exits `2` (no destructive action on a broken preview). Empty
backup directories left behind by no-op runs are auto-removed on success.

```powershell
# Windows
.\tools\fix-and-verify-legacy-refs.ps1                       # preview -> apply (with backups) -> scan -> rollback on FAIL
.\tools\fix-and-verify-legacy-refs.ps1 -SkipApply            # preview + scan only (no writes, no backup, no rollback)
.\tools\fix-and-verify-legacy-refs.ps1 -NoBackup             # apply without backups (rollback disabled)
.\tools\fix-and-verify-legacy-refs.ps1 -NoRollback           # keep changes even if the scanner FAILs
.\tools\fix-and-verify-legacy-refs.ps1 -ReportFile r.json    # custom JSON report path
.\tools\fix-and-verify-legacy-refs.ps1 -BackupRoot D:\bk     # custom backup root (default: .legacy-fix-backups)
```

```bash
# Unix / macOS
bash tools/fix-and-verify-legacy-refs.sh                     # preview -> apply (with backups) -> scan -> rollback on FAIL
SKIP_APPLY=1   bash tools/fix-and-verify-legacy-refs.sh      # preview + scan only (no writes, no backup, no rollback)
NO_BACKUP=1    bash tools/fix-and-verify-legacy-refs.sh      # apply without backups (rollback disabled)
NO_ROLLBACK=1  bash tools/fix-and-verify-legacy-refs.sh      # keep changes even if the scanner FAILs
REPORT_FILE=r.json   bash tools/fix-and-verify-legacy-refs.sh
BACKUP_ROOT=/tmp/bk  bash tools/fix-and-verify-legacy-refs.sh
```

You can also call the fixer directly with the same backup flags, and limit
it to specific folders via `-Paths` / `--paths` / `FIX_PATHS`:

```bash
BACKUP=1 BACKUP_ROOT=.legacy-fix-backups bash tools/fix-legacy-fixer-refs.sh
FIX_PATHS="tools/ src/" bash tools/fix-legacy-fixer-refs.sh
bash tools/fix-legacy-fixer-refs.sh --paths tools/,src/
```

```powershell
.\tools\fix-legacy-fixer-refs.ps1 -Backup -BackupRoot .legacy-fix-backups
.\tools\fix-legacy-fixer-refs.ps1 -Paths tools,src
```

Exit codes:

| Code | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| `0`  | dry-run + apply succeeded **and** scanner reports PASS (repo is clean)                 |
| `1`  | scanner reports FAIL; auto-rollback was attempted unless `-NoBackup` / `-NoRollback`   |
| `2`  | dry-run, apply, rollback, or required-script error (exact file + reason logged)        |



---

## check-required-packages

Verifies every package listed in `tools/check-required-packages.config.json`
is actually installed under `node_modules/`. Designed to be the first thing
you run when you see an error like:

```
error TS2307: Cannot find module '@supabase/supabase-js'
```

### Usage

```bash
# Quick check (auto-detects bun / npm / pnpm / yarn from your lockfile)
node tools/check-required-packages.mjs
bun run check:deps              # convenience alias

# Only print failures (CI-friendly)
node tools/check-required-packages.mjs --quiet

# Machine-readable output
node tools/check-required-packages.mjs --json

# Actually run the install command for any missing packages
node tools/check-required-packages.mjs --fix
bun run check:deps:fix
```

### What it does

1. Reads `tools/check-required-packages.config.json` (`required`, `optional`).
2. For each entry, checks `package.json` declared range + the installed
   version under `node_modules/<name>/package.json`.
3. Prints a colored table per package, then a copy-pasteable fix command
   for the package manager it auto-detected from your lockfile.
4. CODE RED rule: every file/path failure logs the exact path + reason.

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | every required package is installed |
| `1` | one or more required packages are missing or version-mismatched |
| `2` | config / IO error (bad path, unreadable file -- exact reason logged) |

### Adding a new required package

Edit `tools/check-required-packages.config.json` and append to `required`
(or `optional`). Each entry takes `name` and an optional `reason` string
that's printed as "why" hint when the package is missing.
