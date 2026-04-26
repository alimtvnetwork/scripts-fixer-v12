#!/usr/bin/env bash
# scripts-linux/_shared/path-utils.sh
# Path string utilities -- pure bash, no external deps.
#
# Provenance: ported from
#   github.com/aukgit/kubernetes-training-v1/01-base-shell-scripts/05-combine_path.sh
# Renamed for consistency:
#   combine_path           -> path_join                 (matches Python/Node naming)
#   combine_with_base_path -> path_join_basename
# Old names kept as aliases for backward compatibility with k8s-training scripts.

# Public: join two paths with exactly one slash between them.
# Usage:  path_join "/a/b/" "/c/d" -> "/a/b/c/d"
path_join() {
  local a="$1" b="$2"
  [ -z "$a" ] && { printf '%s' "$b"; return; }
  [ -z "$b" ] && { printf '%s' "$a"; return; }
  a="${a%/}"   # strip trailing slash from a
  b="${b#/}"   # strip leading  slash from b
  printf '%s/%s' "$a" "$b"
}

# Public: join source path with the *basename* of the destination path.
# Usage:  path_join_basename "/srv/data" "/var/lib/postgres/main" -> "/srv/data/main"
path_join_basename() {
  local src="$1" dst="$2"
  path_join "$src" "$(basename "$dst")"
}

# Public: expand leading ~ to $HOME (pure bash, no eval).
# Usage:  path_expand_tilde "~/.ssh/id_ed25519" -> "/home/me/.ssh/id_ed25519"
path_expand_tilde() {
  local p="$1"
  case "$p" in
    "~")    printf '%s' "$HOME" ;;
    "~/"*)  printf '%s/%s' "$HOME" "${p:2}" ;;   # strip the leading "~/" (2 chars)
    *)      printf '%s' "$p" ;;
  esac
}

# ---------- backward-compat aliases (upstream names) ----------
combine_path()           { path_join "$@"; }
combine_with_base_path() { path_join_basename "$@"; }
