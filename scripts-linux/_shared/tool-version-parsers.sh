#!/usr/bin/env bash
# scripts-linux/_shared/tool-version-parsers.sh
# Per-tool version parser registry (mirror of scripts/shared/tool-version-parsers.ps1).
#
# Different CLIs print versions in wildly different shapes:
#   git    -> "git version 2.43.0"
#   node   -> "v20.11.0"
#   python -> "Python 3.12.1"
#   go     -> "go version go1.22.0 linux/amd64"
#   java   -> 'openjdk version "21.0.2" 2024-01-16'  (often on STDERR)
#   dotnet -> "8.0.101"
#   rustc  -> "rustc 1.76.0 (07dca489a 2024-02-04)"
#
# Public surface:
#   parse_tool_version <name> <raw_text>   -> echoes cleaned version
#   register_tool_parser <name> <function> -> override at runtime

# Generic semver extractor — handles "1.2", "1.2.3", "1.2.3.4", "1.2.3-rc.1".
get_first_semver_match() {
  local text="$1"
  [ -z "$text" ] && return 1
  echo "$text" | grep -oE '\b[0-9]+\.[0-9]+(\.[0-9]+){0,2}([-+][0-9A-Za-z.\-]+)?\b' | head -n1
}

# -- Built-in parsers (each: read raw on $1, echo cleaned version) ------------
__parse_git()    { echo "$1" | sed -nE 's/.*git version ([^[:space:]]+).*/\1/p' | head -n1; }
__parse_node()   { echo "$1" | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1; }
__parse_python() { echo "$1" | sed -nE 's/.*Python[[:space:]]+([0-9.]+).*/\1/p' | head -n1; }
__parse_go()     { echo "$1" | sed -nE 's/.*go version[[:space:]]+go([0-9.]+).*/\1/p' | head -n1; }
__parse_java()   { echo "$1" | sed -nE 's/.*version[[:space:]]+"([^"]+)".*/\1/p' | head -n1; }
__parse_dotnet() { echo "$1" | tr -d '[:space:]' | grep -E '^[0-9.]+$' | head -n1; }
__parse_rustc()  { echo "$1" | sed -nE 's/.*rustc[[:space:]]+([0-9.]+).*/\1/p' | head -n1; }
__parse_choco()  { echo "$1" | sed -nE 's/.*Chocolatey[[:space:]]+v?([0-9.]+).*/\1/p' | head -n1; }
__parse_pnpm()   { get_first_semver_match "$1"; }

# Registry (associative array — bash 4+).
declare -gA __TOOL_PARSERS=(
  [git]=__parse_git
  [node]=__parse_node
  [nodejs]=__parse_node
  [python]=__parse_python
  [python3]=__parse_python
  [go]=__parse_go
  [golang]=__parse_go
  [java]=__parse_java
  [javac]=__parse_java
  [dotnet]=__parse_dotnet
  [rustc]=__parse_rustc
  [rust]=__parse_rustc
  [pnpm]=__parse_pnpm
  [choco]=__parse_choco
)

register_tool_parser() {
  # Args: <name> <function-name>
  local name="${1,,}"
  local fn="$2"
  __TOOL_PARSERS[$name]="$fn"
}

parse_tool_version() {
  # Args: <name> <raw>
  local name="${1,,}"
  local raw="$2"
  local fn="${__TOOL_PARSERS[$name]:-}"
  local out=""
  if [ -n "$fn" ]; then
    out=$("$fn" "$raw" 2>/dev/null || true)
  fi
  if [ -z "$out" ]; then
    out=$(get_first_semver_match "$raw" || true)
  fi
  if [ -z "$out" ]; then
    # Last resort — return the trimmed raw line.
    out=$(echo "$raw" | head -n1 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  fi
  echo "$out"
}
