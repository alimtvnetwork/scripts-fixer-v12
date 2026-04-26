#!/usr/bin/env bash
# scripts-linux/_shared/apt-install.sh
# apt installer with idempotency + colorized logging.
# Source order (caller must source these first):
#   . _shared/logger.sh
#   . _shared/pkg-detect.sh
#
# Provenance: ported from
#   github.com/aukgit/kubernetes-training-v1/01-base-shell-scripts/02-install-apt.sh
# Renamed for consistency with rest of _shared/:
#   install_apt        -> apt_install_packages          (chatty, with [info]/[ok])
#   install_apt_no_msg -> apt_install_packages_quiet    (silent except on error)
#
# Both check `dpkg -s <pkg>` first so they're idempotent and never re-run apt
# update + install for already-present packages.

# Internal: run `apt-get update` exactly once per shell session.
__apt_did_update=0
__apt_update_once() {
  if [ "$__apt_did_update" = "0" ]; then
    sudo apt-get update -y >/dev/null 2>&1 || sudo apt-get update -y
    __apt_did_update=1
  fi
}

# Public: install one or more apt packages with logging.
# Usage:  apt_install_packages curl git jq
apt_install_packages() {
  local pkg
  is_apt_available || { log_err "apt-get not available on this system"; return 1; }
  for pkg in "$@"; do
    if is_apt_pkg_installed "$pkg"; then
      log_ok "apt: '$pkg' already installed"
      continue
    fi
    log_info "apt: installing '$pkg'"
    __apt_update_once
    if sudo apt-get install -y "$pkg"; then
      log_ok "apt: installed '$pkg'"
    else
      log_err "apt: failed to install '$pkg'"
      return 1
    fi
  done
}

# Public: silent variant -- still idempotent, only logs on failure.
# Usage:  apt_install_packages_quiet curl git jq
apt_install_packages_quiet() {
  local pkg
  is_apt_available || return 1
  for pkg in "$@"; do
    if is_apt_pkg_installed "$pkg"; then continue; fi
    __apt_update_once
    if ! sudo apt-get install -y "$pkg" >/dev/null 2>&1; then
      log_err "apt: failed to install '$pkg' (quiet mode)"
      return 1
    fi
  done
}
