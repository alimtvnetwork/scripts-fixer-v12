#!/usr/bin/env bash
# scripts-linux/_shared/aria2c-download.sh
# Parallel/segmented downloads via aria2c with graceful curl/wget fallback.
# Source order (caller must source these first):
#   . _shared/logger.sh
#   . _shared/pkg-detect.sh
#   . _shared/apt-install.sh
#
# Provenance: ported from
#   github.com/aukgit/kubernetes-training-v1/01-base-shell-scripts/03-aria2c-download.sh
# Improvements over upstream:
#   * Calls our apt_install_packages_quiet (upstream invoked install_apt_no_msg
#     with no args -- a bug -- so aria2c was never actually auto-installed).
#   * Falls back to curl, then wget, when aria2c is unavailable AND apt is
#     unavailable (e.g. macOS, Alpine, locked-down CI).
#   * Returns non-zero on download failure (upstream silently swallowed errors).

# Tunables (override per-call via positional args).
ARIA2C_DEFAULT_SPLIT=40
ARIA2C_DEFAULT_CONNECTIONS=16

has_aria2c() { command -v aria2c >/dev/null 2>&1; }

# Internal: ensure aria2c is on PATH; install via apt if possible.
__ensure_aria2c() {
  if has_aria2c; then return 0; fi
  if is_apt_available && is_debian_family; then
    log_info "aria2c not found -- installing via apt"
    apt_install_packages_quiet aria2 || return 1
    has_aria2c
    return $?
  fi
  return 1
}

# Public: download a URL. Tries aria2c first, then curl, then wget.
# Usage:
#   aria2c_download <url> [<output_dir>] [<split>] [<connections>]
# Returns 0 on success, non-zero on failure.
aria2c_download() {
  local url="$1"
  local output_dir="${2:-.}"
  local split="${3:-$ARIA2C_DEFAULT_SPLIT}"
  local connections="${4:-$ARIA2C_DEFAULT_CONNECTIONS}"

  if [ -z "$url" ]; then
    log_err "aria2c_download: <url> is required"
    return 2
  fi
  if ! mkdir -p "$output_dir" 2>/dev/null; then
    log_file_error "$output_dir" "cannot create output directory"
    return 1
  fi

  log_info "Downloading $url -> $output_dir"

  if __ensure_aria2c; then
    if aria2c -x "$connections" -s "$split" -d "$output_dir" "$url"; then
      log_ok "Downloaded (aria2c): $url"
      return 0
    fi
    log_warn "aria2c failed -- falling back to curl/wget"
  fi

  local fname; fname=$(basename "${url%%\?*}")
  if has_curl; then
    if curl -fsSL --retry 3 -o "$output_dir/$fname" "$url"; then
      log_ok "Downloaded (curl): $url"
      return 0
    fi
    log_warn "curl failed -- trying wget"
  fi
  if has_wget; then
    if wget -q --tries=3 -O "$output_dir/$fname" "$url"; then
      log_ok "Downloaded (wget): $url"
      return 0
    fi
  fi
  log_err "Download failed (no working downloader): $url"
  return 1
}
