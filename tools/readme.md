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
```

```bash
# Unix / macOS
bash tools/scan-legacy-fixer-refs.sh                   # default v8/v9/v10
SCAN_VERSIONS="8|9|10|11" bash tools/scan-legacy-fixer-refs.sh
SCAN_ROOT="/path/to/repo" bash tools/scan-legacy-fixer-refs.sh
```

Exit codes: `0` PASS (no matches) · `1` FAIL (matches grouped by file with
a per-version summary) · `2` error (logs exact path + reason).

---

## fix-and-verify-legacy-refs (.ps1 / .sh)

**Single command** that runs the full migration safety net in one shot:

1. Dry-run the fixer to **preview** every file that would change (no writes).
2. Apply the rewrite (`scripts-fixer-v8/v9/v10` -> `scripts-fixer-v11`) and
   write the JSON summary to `legacy-fix-report.json`.
3. Run the scanner. The whole command **only exits 0 when the scanner
   reports PASS**, so a green exit guarantees the repo is clean.

If the dry-run or apply step fails, the pipeline aborts before later steps
run and exits `2` (no destructive action on a broken preview).

```powershell
# Windows
.\tools\fix-and-verify-legacy-refs.ps1                    # full preview -> apply -> scan
.\tools\fix-and-verify-legacy-refs.ps1 -SkipApply         # preview + scan only (no writes)
.\tools\fix-and-verify-legacy-refs.ps1 -ReportFile r.json # custom JSON report path
```

```bash
# Unix / macOS
bash tools/fix-and-verify-legacy-refs.sh                   # full preview -> apply -> scan
SKIP_APPLY=1 bash tools/fix-and-verify-legacy-refs.sh      # preview + scan only (no writes)
REPORT_FILE=r.json bash tools/fix-and-verify-legacy-refs.sh
```

Exit codes:

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| `0`  | dry-run + apply succeeded **and** scanner reports PASS (repo is clean)   |
| `1`  | scanner reports FAIL after apply (legacy refs still present somewhere)   |
| `2`  | dry-run, apply, or required-script error (exact file + reason logged)    |

