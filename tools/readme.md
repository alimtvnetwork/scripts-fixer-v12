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

| Method | Path                  | Description                         |
| ------ | --------------------- | ----------------------------------- |
| GET    | `/health`             | Returns `{ ok, root, scripts }`     |
| GET    | `/config?script=<id>` | Read current config.json            |
| POST   | `/config?script=<id>` | Overwrite config.json (body = JSON) |

Allowed `<id>` values are whitelisted in the script (`52`, `31` by default).
Add more entries to `$allowedScripts` to expose other configs.

## Safety

- Binds to **127.0.0.1 only** — never reachable from the network.
- Optional `-Token` enforces `X-Bridge-Token: <token>` on writes.
- Each successful POST first copies the existing file to
  `config.json.<timestamp>.bak` next to it.
- Rejects any payload that isn't valid JSON.
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
