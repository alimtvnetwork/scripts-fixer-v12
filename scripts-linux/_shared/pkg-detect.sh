#!/usr/bin/env bash
# Package manager + environment detection for Linux installer toolkit.
# Resolution order: apt -> snap -> tarball/curl|sh -> none

is_apt_available()  { command -v apt-get >/dev/null 2>&1; }
is_snap_available() { command -v snap     >/dev/null 2>&1; }
is_dpkg_available() { command -v dpkg     >/dev/null 2>&1; }
has_curl()          { command -v curl     >/dev/null 2>&1; }
has_wget()          { command -v wget     >/dev/null 2>&1; }
has_jq()            { command -v jq       >/dev/null 2>&1; }
has_tar()           { command -v tar      >/dev/null 2>&1; }
is_root()           { [ "$(id -u)" -eq 0 ]; }

get_arch() { uname -m; }

get_distro_id() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release && echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

get_distro_like() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release && echo "${ID_LIKE:-}"
  fi
}

get_ubuntu_version() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release && echo "${VERSION_ID:-unknown}"
  else
    echo "unknown"
  fi
}

is_debian_family() {
  local id like
  id=$(get_distro_id)
  like=$(get_distro_like)
  case "$id" in ubuntu|debian|linuxmint|pop|elementary) return 0 ;; esac
  case "$like" in *debian*|*ubuntu*) return 0 ;; esac
  return 1
}

# Check if an apt package is already installed.
is_apt_pkg_installed() {
  local pkg="$1"
  is_dpkg_available || return 1
  dpkg -s "$pkg" >/dev/null 2>&1
}

# Check if a snap is installed.
is_snap_pkg_installed() {
  local pkg="$1"
  is_snap_available || return 1
  snap list "$pkg" >/dev/null 2>&1
}

# Resolve install method for a logical package.
# Reads <config.json>:
#   install.apt      (string|array) -- apt package name(s)
#   install.snap     (string)       -- snap name
#   install.tarball  (object {url}) -- tarball URL
# Echoes one of: apt | snap | tarball | none
resolve_install_method() {
  local config="$1"
  if [ ! -f "$config" ]; then
    echo "none"; return 0
  fi
  has_jq || { echo "none"; return 0; }
  local has_apt has_snap has_tarball
  has_apt=$(jq -r '.install.apt // empty | if type=="array" then .[0] else . end' "$config" 2>/dev/null)
  has_snap=$(jq -r '.install.snap // empty' "$config" 2>/dev/null)
  has_tarball=$(jq -r '.install.tarball // empty | if type=="object" then (.url // empty) else . end' "$config" 2>/dev/null)

  if [ -n "$has_apt" ]     && is_apt_available  && is_debian_family; then echo "apt";     return 0; fi
  if [ -n "$has_snap" ]    && is_snap_available;                     then echo "snap";    return 0; fi
  if [ -n "$has_tarball" ] && has_curl;                              then echo "tarball"; return 0; fi
  echo "none"
}

# Public: check if a command/binary is on PATH.
# Differs from is_apt_pkg_installed (dpkg-based) -- this is portable to any OS
# and works for tools installed outside apt (snap, brew, tarballs, npm, etc.).
# Usage:  if is_command_available helm; then ...; fi
is_command_available() {
  command -v "$1" >/dev/null 2>&1
}

# Backward-compat alias for k8s-training scripts (logs while checking).
# Usage:  is_package_installed helm
is_package_installed() {
  local pkg="$1"
  if is_command_available "$pkg"; then
    log_ok "$pkg is installed"
    return 0
  fi
  log_warn "$pkg is not installed"
  return 1
}
