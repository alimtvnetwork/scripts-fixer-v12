---
name: Script 67 context-menu verifier
description: Independent post-cleanup scan for VS Code Linux desktop/MIME/file-manager surfaces, separate from rows-TSV re-probe
type: feature
---

# Script 67 -- context-menu / MIME surface verifier

Added in v0.138.0 alongside the existing `_shared/verify.sh` re-probe.

## Why a second verifier?

`_shared/verify.sh::verify_run` only re-checks rows that the cleanup phase
itself produced. If a method (e.g. `apt`) was the only one detected, the
rows TSV will never reference Nautilus scripts, `mimeapps.list`, or
`xdg-mime` defaults -- so the operator never gets a definitive answer to
the question "did the right-click 'Open with Code' entries actually go
away?". The new helper scans those surfaces independently of what the
cleanup phase touched.

## File

`scripts-linux/67-vscode-cleanup-linux/helpers/verify-context-menu.sh`

Exposes:
- `verify_context_menu_run`   -- writes rows to `$VERIFY_CTX_TSV`
- `verify_context_menu_render` -- prints the report to stderr
- Globals: `VERIFY_CTX_PASSES`, `VERIFY_CTX_FAILS`, `VERIFY_CTX_SKIPS`

## Surfaces inspected (read-only)

1. `.desktop` files in every XDG applications directory:
   `/usr/share/applications`, `/usr/local/share/applications`,
   `$HOME/.local/share/applications`, `$XDG_DATA_HOME/applications`,
   each `$XDG_DATA_DIRS/applications`.
   Flags: `code.desktop` / `code-insiders.desktop` themselves, plus any
   third-party `.desktop` whose `Exec=` line invokes `code` / `code-insiders`,
   plus residual `MimeType=` lines on a code* desktop file.
2. `mimeapps.list` defaults + added-associations:
   `$HOME/.config/mimeapps.list`,
   `$HOME/.local/share/applications/mimeapps.list`,
   `/usr/share/applications/mimeapps.list`, `/etc/xdg/mimeapps.list`.
3. File-manager Scripts menu directories:
   `$HOME/.local/share/nautilus/scripts`,
   `$HOME/.local/share/nemo/scripts`,
   `$HOME/.config/caja/scripts`. Matches by name OR by content (<=64 KB).
4. `xdg-mime query default` on a curated list of common text mime types
   (`text/plain`, `text/x-shellscript`, `text/x-python`, `text/x-c`,
   `text/x-csrc`, `text/x-c++src`, `text/x-java`, `text/markdown`,
   `application/json`, `application/xml`).

## Run.sh integration

- Sourced at top alongside detect/remove helpers.
- Runs after the existing `verify_run` block, in BOTH apply and dry-run
  modes (read-only), and even when no install method was detected.
- Output TSV: `$RUN_DIR/verify-context-menu.tsv`.
- Manifest gains a `contextMenu: { totals, rows[] }` object alongside
  `verification`.
- New exit code: **4** = context-menu/MIME scan found leftover VS Code
  wiring (after a successful apply). Sits below 3 (rows re-probe failure)
  and above 1 (step failure) in priority.

## Verified

Smoke-tested with planted dirty/clean state in a sandbox HOME:
- Dirty: 5 FAILs (desktop-file, desktop-exec, desktop-mimetype,
  mimeapps-line, nautilus-script) + 1 skip (xdg-mime not on PATH).
- After cleanup: 1 PASS + 2 skip-other, FAIL=0, ✅ verdict.