#!/usr/bin/env bash
# Package manager + environment detection for Linux installer toolkit.
# Resolution order: apt -> snap -> tarball/curl|sh -> none

is_apt_available()  { command -v apt-get >/dev/null 2>&1; }
is_snap_available() { command -v snap     >/dev/null 2>&1; }
has_curl()          { command -v curl     >/dev/null 2>&1; }
has_wget()          { command -v wget     >/dev/null 2>&1; }
is_root()           { [ "$(id -u)" -eq 0 ]; }

get_arch() { uname -m; }

get_distro_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release && echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

get_ubuntu_version() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release && echo "${VERSION_ID:-unknown}"
  else
    echo "unknown"
  fi
}

# Resolve install method for a logical package name.
# Looks up scripts-linux/<script>/config.json fields:
#   install.apt, install.snap, install.tarball
# Returns first available method on stdout: apt|snap|tarball|none
resolve_install_method() {
  local config="$1"
  if [ ! -f "$config" ]; then
    echo "none"; return 0
  fi
  local has_apt has_snap has_tarball
  has_apt=$(jq -r '.install.apt // empty'     "$config" 2>/dev/null)
  has_snap=$(jq -r '.install.snap // empty'   "$config" 2>/dev/null)
  has_tarball=$(jq -r '.install.tarball // empty' "$config" 2>/dev/null)

  if [ -n "$has_apt" ]     && is_apt_available;  then echo "apt";     return 0; fi
  if [ -n "$has_snap" ]    && is_snap_available; then echo "snap";    return 0; fi
  if [ -n "$has_tarball" ] && has_curl;          then echo "tarball"; return 0; fi
  echo "none"
}