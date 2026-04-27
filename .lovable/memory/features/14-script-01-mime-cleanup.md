---
name: 14-script-01-mime-cleanup
description: Script 01 (install-vscode) MIME defaults cleanup on uninstall — strict allow-list scrub of mimeapps.list/defaults.list
type: feature
---

# Script 01 — VS Code MIME defaults cleanup (v0.165.0)

## Why
The apt and snap install paths register `code.desktop` (and on first
launch, VS Code itself adds `code-url-handler.desktop`) as the default
handler for dozens of text/source MIME types via the freedesktop
mimeapps spec. `apt-get remove code` deletes `/usr/share/applications/code.desktop`
but does NOT remove the references to it from per-user
`~/.config/mimeapps.list` or the legacy `~/.local/share/applications/defaults.list`.
Result: file managers keep showing "Open with Code" greyed out and
`xdg-open` fails for those MIME types until the user hand-edits the file.

## What the cleanup does
On `verb_uninstall`, after `apt-get remove`/`snap remove`,
`_clean_mime_defaults` runs an STRICT allow-list scrub. It NEVER deletes
whole files and NEVER touches sibling associations.

### config.json: `mimeCleanup` block
- `enabled` — set false to skip entirely (e.g. user reinstalled via flatpak)
- `desktopFiles[]` — exact .desktop tokens to strip
  (`code.desktop`, `code-url-handler.desktop`, `code_code.desktop`,
  `code-insiders.desktop`, `code-insiders-url-handler.desktop`)
- `userFiles[]` — files in $HOME to scrub (`${HOME}` is the only
  variable expanded)
- `systemFiles[]` — files under `/usr` and `/etc` (sudo)
- `cacheFiles[]` — touched only for logging; rebuilt via
  `update-desktop-database`, never deleted

### Scrub logic (sed chain)
For each allow-listed `<desktop>`:
1. `^[^=]*=<desktop>;\?$` — drop whole line where the value is ONLY the
   allow-listed token
2. `=<desktop>;` → `=` — strip from start of value list
3. `;<desktop>;` → `;` — strip from middle of value list
4. `;<desktop>$` → `` — strip from end of value list
5. `^[^=]*=$` — drop any line left with empty RHS

After scrub, sibling tokens like `gedit.desktop;sublime.desktop` and
unrelated lines like `text/html=firefox.desktop` are PRESERVED byte-
for-byte.

### Safety
- Each modified file gets a `.bak-01-<timestamp>` copy BEFORE write-back
- Original mode preserved via `chmod` round-trip
- `cmp -s` (or `diff -q` fallback) skips files with no matching entries
  — no spurious backups
- All file/path errors go through `log_file_error` per CODE RED rule

## Verified test cases
| Input fixture line | Expected outcome | Verified |
|---|---|---|
| `text/plain=code.desktop` | line dropped | ✅ |
| `text/x-python=code.desktop;` | line dropped | ✅ |
| `text/x-c=gedit.desktop;code.desktop;sublime.desktop;` | code stripped, siblings preserved | ✅ |
| `text/markdown=code.desktop;ghostwriter.desktop` | code stripped, ghostwriter preserved | ✅ |
| `text/x-shellscript=vim.desktop;code.desktop` | code stripped (end-of-list), vim preserved | ✅ |
| `application/json=code-insiders.desktop` | line dropped | ✅ |
| `application/x-yaml=code.desktop;code-insiders.desktop;` | both stripped, line dropped | ✅ |
| `text/html=firefox.desktop` | UNTOUCHED (not allow-listed) | ✅ |
| `text/x-rust=code_code.desktop;rustrover.desktop` | code_code stripped, rustrover preserved | ✅ |

## Files
- `scripts-linux/01-install-vscode/config.json` — `mimeCleanup` block
- `scripts-linux/01-install-vscode/run.sh` — `_clean_mime_defaults` helper
  invoked from `verb_uninstall`

## Out of scope (see suggestions)
- Reverse cleanup for the snap variant's `code_code.desktop` cache under
  `~/snap/code/current/.config/mimeapps.list`
- xdg-mime per-MIME re-default to next-best handler (script just leaves
  the MIME unset, letting xdg-open's normal precedence rules pick)
- Cleanup for the .deb variant's per-arch `/var/lib/snapd/desktop/applications/`
  cache (snapd manages it itself on `snap remove`)

## v0.166.0 — `_clean_vscode_desktop_entries` (in-file scrub)

The original `_clean_mime_defaults` only scrubbed REFERENCES from
`mimeapps.list` / `defaults.list`. But VS Code's OWN `.desktop` files
(written by apt postinst, snap install, and `code --install-extension`
shell-integration prompts) also contain `MimeType=`, `Actions=`, and
`[Desktop Action <name>]` group blocks. On snap removal and partial
uninstalls these per-user copies survive and still claim MIME ownership.

`_clean_vscode_desktop_entries` strips ONLY:
- `MimeType=...` lines (whole line)
- `Actions=...`  lines (whole line)
- `[Desktop Action <name>]` group blocks (header through next group/EOF)

It PRESERVES every other key (`Name`, `GenericName`, `Comment`, `Exec`,
`TryExec`, `Icon`, `Type`, `Categories`, `StartupNotify`, `StartupWMClass`,
`Keywords`, `NoDisplay`, `Hidden`, `OnlyShowIn`, `NotShowIn`, `X-*`).

It NEVER touches a `.desktop` file whose basename is not in
`mimeCleanup.desktopFiles[]`. `firefox.desktop`, `gimp.desktop`, etc. are
verified byte-for-byte unchanged via sha256sum in the test fixture.

### Searched directories (`mimeCleanup.desktopEntryDirs[]`)
- `${HOME}/.local/share/applications`
- `${HOME}/.local/share/applications/wine/Programs`
- `/usr/share/applications`
- `/var/lib/snapd/desktop/applications`
- `/var/lib/flatpak/exports/share/applications`
- `${HOME}/.local/share/flatpak/exports/share/applications`

Only files matching `desktopFiles[] x desktopEntryDirs[]` are considered.
Sudo is used for any path outside `$HOME`. First-line sanity check
refuses to touch any file that doesn't start with `[Desktop Entry]` or a
`#` comment.

### Change-detection hardening
Both helpers now try `cmp` -> `diff` -> `md5sum` -> shell string compare
(handles minimal sandbox/container environments missing coreutils
diff/cmp). No-op files no longer get spurious `.bak-*` backups.

Backup naming differs to keep the two scrubs distinct on disk:
- `_clean_mime_defaults` writes `<file>.bak-01-<ts>`
- `_clean_vscode_desktop_entries` writes `<file>.bak-01de-<ts>`

### Verified test cases (v0.166.0)
| Input | Outcome | Verified |
|---|---|---|
| `code.desktop` with MimeType/Actions/2 Action blocks | keys + blocks stripped, all other keys preserved | ✅ |
| `code-url-handler.desktop` with no MimeType/Actions | NO change, NO backup written | ✅ |
| `firefox.desktop` with MimeType + Actions + `[Desktop Action ...]` | byte-for-byte unchanged (sha256 verified) | ✅ |
| Non-existent dirs (snap, flatpak, wine, /usr/share missing) | skipped silently | ✅ |
