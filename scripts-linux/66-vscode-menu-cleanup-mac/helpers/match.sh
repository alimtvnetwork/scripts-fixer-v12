#!/usr/bin/env bash
# helpers/match.sh -- read-only helpers shared by sweep modes.
#
# All three "registry-equivalent" surfaces (LaunchAgents, LaunchDaemons,
# url-handlers) need to peek inside .plist files to decide whether they
# reference VS Code. macOS plists may be XML *or* binary -- we normalize
# to XML via plutil so a plain `grep` works either way.

# Convert any plist to XML on stdout. Returns "" on failure (file missing,
# unreadable, plutil broken). Never writes anywhere.
plist_to_xml() {
  local p="$1"
  if [ ! -r "$p" ]; then
    log_file_error "$p" "plist not readable (skip)"
    return 1
  fi
  if command -v plutil >/dev/null 2>&1; then
    plutil -convert xml1 -o - "$p" 2>/dev/null
    return $?
  fi
  # Fallback: just cat -- works for already-XML plists, fails silently
  # on binary ones (the caller's substring match will simply miss them).
  cat "$p" 2>/dev/null
}

# Returns 0 if the plist content references ANY of the supplied substrings.
# Args: <plist-path> <substring> [<substring> ...]
plist_references_any() {
  local p="$1"; shift
  local xml
  xml="$(plist_to_xml "$p")" || return 1
  [ -z "$xml" ] && return 1
  local needle
  for needle in "$@"; do
    if printf '%s' "$xml" | grep -F -q -- "$needle"; then
      return 0
    fi
  done
  return 1
}

# Read the launchctl Label key from a plist. Returns "" if absent.
plist_label() {
  local p="$1"
  local xml; xml="$(plist_to_xml "$p")" || return 1
  # <key>Label</key><string>com.foo.bar</string>
  printf '%s' "$xml" \
    | tr -d '\n' \
    | sed -n 's/.*<key>Label<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p' \
    | head -n 1
}