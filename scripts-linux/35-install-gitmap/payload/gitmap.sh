#!/usr/bin/env bash
# gitmap — show a tree-view of the current git repo with branch/commit overlay
set -u
VERSION="0.1.0"
case "${1:-show}" in
  --version|-V) echo "gitmap $VERSION"; exit 0 ;;
  --help|-h)    echo "Usage: gitmap [show|branches|--version|--help]"; exit 0 ;;
  branches)     git branch -avv 2>/dev/null || { echo "Not a git repo" >&2; exit 1; } ;;
  show|*)
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "Not a git repo" >&2; exit 1
    fi
    echo "== $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD) =="
    if command -v tree >/dev/null 2>&1; then
      tree -L 3 --gitignore -I '.git|node_modules|.venv'
    else
      git ls-files | head -50
    fi
    ;;
esac
