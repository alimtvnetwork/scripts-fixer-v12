#!/usr/bin/env bash
# helpers/verify-context-menu.sh -- independent post-cleanup scan of the
# Linux desktop / menu / MIME-handler surfaces that VS Code can register
# itself with. This is INDEPENDENT of whatever the cleanup phase touched:
# even if the run targeted only `apt` packages, this verifier still scans
# every known integration surface and reports anything that still names
# code / code-insiders.
#
# Surfaces inspected (all read-only):
#
#   1. .desktop files in the standard XDG application directories:
#        /usr/share/applications
#        /usr/local/share/applications
#        $HOME/.local/share/applications
#        $XDG_DATA_HOME/applications        (if set)
#        each $XDG_DATA_DIRS/applications   (if set)
#      We look for code.desktop / code-insiders.desktop AND for any other
#      .desktop file whose Exec= line invokes `code` or `code-insiders`
#      (e.g. third-party launchers). MimeType= lines are inspected too --
#      a leftover MimeType=text/plain;... entry on a code.desktop file is
#      what produces the "Open With Visual Studio Code" right-click entry
#      in Nautilus / Files.
#
#   2. mimeapps.list user defaults and added-associations:
#        $HOME/.config/mimeapps.list
#        $HOME/.local/share/applications/mimeapps.list
#        /usr/share/applications/mimeapps.list
#        /etc/xdg/mimeapps.list
#      Any line that maps a mime type to code.desktop / code-insiders.desktop
#      is flagged. These are exactly the entries that survive a `dpkg -P`
#      and that keep showing "Open With Code" in file managers.
#
#   3. Nautilus / Nemo / Caja "Scripts" menu entries:
#        $HOME/.local/share/nautilus/scripts/
#        $HOME/.local/share/nemo/scripts/
#        $HOME/.config/caja/scripts/
#      Any script whose name OR contents reference code / code-insiders.
#
#   4. xdg-mime live query (when xdg-mime is on PATH): for a small set of
#      common text mime types we ask xdg-mime which .desktop currently
#      handles them. If the answer is code.desktop / code-insiders.desktop
#      the right-click "Open With" default is still wired up.
#
# OUTPUT: appends rows to $VERIFY_CTX_TSV in the same 5-column shape used
# by _shared/verify.sh so the existing render/manifest code can consume it
# without changes:
#
#   <result>\t<bucket>\t<kind>\t<target>\t<detail>
#
#   result : pass | fail | skip-other
#   bucket : ctx-menu
#   kind   : desktop-file | desktop-exec | desktop-mimetype
#          | mimeapps-line | nautilus-script | xdg-default
#
# Globals exported for the caller:
#   VERIFY_CTX_PASSES, VERIFY_CTX_FAILS, VERIFY_CTX_SKIPS

: "${VERIFY_CTX_TSV:=/tmp/vscode-ctx-verify.tsv}"

_ctx_emit() {
  printf '%s\tctx-menu\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$VERIFY_CTX_TSV" \
    || log_file_error "$VERIFY_CTX_TSV" "failed to append ctx-verify row (result=$1 target=$3)"
}

# Collect every applications dir we should scan for .desktop files.
_ctx_app_dirs() {
  local dirs=(
    "/usr/share/applications"
    "/usr/local/share/applications"
    "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    "$HOME/.local/share/applications"
  )
  if [ -n "${XDG_DATA_DIRS:-}" ]; then
    local d
    IFS=':' read -r -a _xdd <<<"$XDG_DATA_DIRS"
    for d in "${_xdd[@]}"; do
      [ -n "$d" ] && dirs+=("$d/applications")
    done
  fi
  # de-duplicate while preserving order
  local seen=" " out=() x
  for x in "${dirs[@]}"; do
    case "$seen" in *" $x "*) continue ;; esac
    seen="$seen$x "
    out+=("$x")
  done
  printf '%s\n' "${out[@]}"
}

_ctx_mimeapps_files() {
  printf '%s\n' \
    "$HOME/.config/mimeapps.list" \
    "$HOME/.local/share/applications/mimeapps.list" \
    "/usr/share/applications/mimeapps.list" \
    "/etc/xdg/mimeapps.list"
}

_ctx_script_dirs() {
  printf '%s\n' \
    "$HOME/.local/share/nautilus/scripts" \
    "$HOME/.local/share/nemo/scripts" \
    "$HOME/.config/caja/scripts"
}

# Scan one .desktop file for VS Code references. Emits 0..N rows.
_ctx_scan_desktop_file() {
  local f="$1" base
  base=$(basename -- "$f")
  case "$base" in
    code.desktop|code-insiders.desktop)
      _ctx_emit "fail" "desktop-file" "$f" "VS Code .desktop launcher still present"
      VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
      ;;
  esac

  # Exec= line invoking code / code-insiders (not just any string match).
  if grep -E -i '^[[:space:]]*Exec[[:space:]]*=.*([[:space:]/]|^)code(-insiders)?([[:space:]]|$)' "$f" >/dev/null 2>&1; then
    local execline
    execline=$(grep -E -i -m1 '^[[:space:]]*Exec[[:space:]]*=' "$f" 2>/dev/null | head -c 160)
    _ctx_emit "fail" "desktop-exec" "$f" "Exec line invokes code/code-insiders: ${execline}"
    VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
  fi

  # MimeType= line on a code* .desktop file -> right-click "Open With" entry.
  case "$base" in
    code.desktop|code-insiders.desktop)
      if grep -E -i '^[[:space:]]*MimeType[[:space:]]*=' "$f" >/dev/null 2>&1; then
        local ml
        ml=$(grep -E -i -m1 '^[[:space:]]*MimeType[[:space:]]*=' "$f" 2>/dev/null | head -c 160)
        _ctx_emit "fail" "desktop-mimetype" "$f" "MimeType still wired: ${ml}"
        VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
      fi
      ;;
  esac
}

# Public: run every context-menu / MIME surface scan.
# Args: (none) -- reads $VERIFY_CTX_TSV path from env (set by caller).
verify_context_menu_run() {
  VERIFY_CTX_PASSES=0
  VERIFY_CTX_FAILS=0
  VERIFY_CTX_SKIPS=0
  : > "$VERIFY_CTX_TSV" || { log_file_error "$VERIFY_CTX_TSV" "failed to truncate ctx-verify TSV"; return 1; }

  # ---- 1. .desktop files in every applications directory ----
  local d files=0 found=0
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    # nullglob-equivalent in plain sh
    local f
    for f in "$d"/*.desktop; do
      [ -e "$f" ] || continue
      files=$((files+1))
      local before="$VERIFY_CTX_FAILS"
      _ctx_scan_desktop_file "$f"
      [ "$VERIFY_CTX_FAILS" -gt "$before" ] && found=$((found+1))
    done
  done < <(_ctx_app_dirs)
  if [ "$files" -eq 0 ]; then
    _ctx_emit "skip-other" "desktop-file" "(applications dirs)" "no .desktop files found in any XDG applications directory"
    VERIFY_CTX_SKIPS=$((VERIFY_CTX_SKIPS+1))
  elif [ "$found" -eq 0 ]; then
    _ctx_emit "pass" "desktop-file" "(applications dirs)" "scanned $files .desktop file(s); none reference code/code-insiders"
    VERIFY_CTX_PASSES=$((VERIFY_CTX_PASSES+1))
  fi

  # ---- 2. mimeapps.list lines ----
  local m
  while IFS= read -r m; do
    if [ ! -f "$m" ]; then
      continue
    fi
    if grep -E -i '(^|[=;[:space:]])code(-insiders)?\.desktop([[:space:]]|;|$)' "$m" >/dev/null 2>&1; then
      local sample
      sample=$(grep -E -i -m1 '(^|[=;[:space:]])code(-insiders)?\.desktop([[:space:]]|;|$)' "$m" 2>/dev/null | head -c 160)
      _ctx_emit "fail" "mimeapps-line" "$m" "still maps a mime type to code.desktop: ${sample}"
      VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
    else
      _ctx_emit "pass" "mimeapps-line" "$m" "no code/code-insiders associations remain"
      VERIFY_CTX_PASSES=$((VERIFY_CTX_PASSES+1))
    fi
  done < <(_ctx_mimeapps_files)

  # ---- 3. Nautilus / Nemo / Caja Scripts menu entries ----
  local s
  while IFS= read -r s; do
    if [ ! -d "$s" ]; then
      continue
    fi
    local hits=0 entry
    for entry in "$s"/*; do
      [ -e "$entry" ] || continue
      local base
      base=$(basename -- "$entry")
      # name-based match
      case "$base" in
        *[Cc]ode*|*vscode*|*VSCode*)
          _ctx_emit "fail" "nautilus-script" "$entry" "script name references code/vscode"
          VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
          hits=$((hits+1))
          continue ;;
      esac
      # content-based match (small files only)
      if [ -f "$entry" ] && [ -r "$entry" ]; then
        local sz
        sz=$(wc -c <"$entry" 2>/dev/null || echo 0)
        if [ "${sz:-0}" -le 65536 ] \
          && grep -E -i '(^|[[:space:]/])(code|code-insiders)([[:space:]]|$)' "$entry" >/dev/null 2>&1; then
          _ctx_emit "fail" "nautilus-script" "$entry" "script body invokes code/code-insiders"
          VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
          hits=$((hits+1))
        fi
      fi
    done
    if [ "$hits" -eq 0 ]; then
      _ctx_emit "pass" "nautilus-script" "$s" "no code/vscode entries in this scripts directory"
      VERIFY_CTX_PASSES=$((VERIFY_CTX_PASSES+1))
    fi
  done < <(_ctx_script_dirs)

  # ---- 4. xdg-mime live defaults ----
  if command -v xdg-mime >/dev/null 2>&1; then
    local mt handler
    for mt in \
      text/plain \
      text/x-shellscript \
      text/x-python \
      text/x-c \
      text/x-csrc \
      text/x-c++src \
      text/x-java \
      text/markdown \
      application/json \
      application/xml
    do
      handler=$(xdg-mime query default "$mt" 2>/dev/null || true)
      case "$handler" in
        code.desktop|code-insiders.desktop)
          _ctx_emit "fail" "xdg-default" "$mt" "xdg-mime still reports default handler: $handler"
          VERIFY_CTX_FAILS=$((VERIFY_CTX_FAILS+1))
          ;;
        "")
          : # no default at all -- fine
          ;;
        *)
          : # different handler -- fine
          ;;
      esac
    done
    if [ "$VERIFY_CTX_FAILS" -eq 0 ]; then
      _ctx_emit "pass" "xdg-default" "(common text mime types)" "no mime type defaults to code/code-insiders"
      VERIFY_CTX_PASSES=$((VERIFY_CTX_PASSES+1))
    fi
  else
    _ctx_emit "skip-other" "xdg-default" "xdg-mime" "xdg-mime not on PATH; cannot query live defaults"
    VERIFY_CTX_SKIPS=$((VERIFY_CTX_SKIPS+1))
  fi

  return 0
}

# Render the context-menu verification report to stderr.
# Args: <verify-tsv> <title>
verify_context_menu_render() {
  local tsv="$1" title="${2:-VS Code context-menu / MIME surface scan}"
  if [ ! -f "$tsv" ]; then
    log_file_error "$tsv" "ctx-verify TSV missing -- cannot render report"
    return 1
  fi
  local total
  total=$(grep -c . "$tsv" 2>/dev/null || echo 0)
  printf '\n  ===== %s =====\n' "$title" >&2
  if [ "$total" -eq 0 ]; then
    printf '  (no surfaces scanned)\n\n' >&2
    return 0
  fi
  printf '  %-12s  %-18s  %s\n' "RESULT" "KIND" "TARGET (detail)" >&2
  printf '  %s\n' "$(printf '%.0s-' {1..100})" >&2
  local result _b kind target detail
  while IFS=$'\t' read -r result _b kind target detail; do
    [ -z "$result" ] && continue
    printf '  %-12s  %-18s  %s  (%s)\n' "$result" "$kind" "$target" "$detail" >&2
  done < "$tsv"
  printf '  %s\n' "$(printf '%.0s-' {1..100})" >&2
  local p="${VERIFY_CTX_PASSES:-0}" f="${VERIFY_CTX_FAILS:-0}" s="${VERIFY_CTX_SKIPS:-0}"
  printf '  CTX-MENU TOTALS: pass=%d  fail=%d  skipped=%d\n' "$p" "$f" "$s" >&2
  if [ "$f" -gt 0 ]; then
    printf '\n  CTX-MENU VERDICT: ❌ FAIL -- %d context-menu/MIME entry(ies) still wired to VS Code. See FILE-ERROR lines above for paths.\n\n' "$f" >&2
  else
    printf '\n  CTX-MENU VERDICT: ✅ PASS -- no VS Code context-menu / MIME wiring detected.\n\n' "$f" >&2
  fi
  return 0
}