#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="27"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 27-install-elasticsearch"; exit 1; }
has_jq || { log_err "[27] jq required to read config"; exit 1; }

APT_PKG=$(jq -r '.install.apt' "$CONFIG")
VERIFY_CMD='/usr/share/elasticsearch/bin/elasticsearch --version'
KEY_URL=$(jq -r '.thirdPartyRepo.keyUrl' "$CONFIG")
KEYRING=$(jq -r '.thirdPartyRepo.keyring' "$CONFIG")
REPO_LIST=$(jq -r '.thirdPartyRepo.repoListPath' "$CONFIG")
REPO_LINE=$(jq -r '.thirdPartyRepo.repoLine' "$CONFIG")
INSTALLED_MARK="$ROOT/.installed/27.ok"

verify_installed() { bash -c "$VERIFY_CMD" >/dev/null 2>&1; }

setup_repo() {
  has_curl || { log_err "[27] curl required"; return 1; }
  command -v gpg >/dev/null 2>&1 || { sudo apt-get install -y gnupg || return 1; }
  log_info "[27] Fetching GPG key from $KEY_URL"
  local key_tmp
  key_tmp=$(mktemp /tmp/27-install-elasticsearch.gpg.XXXXXX) || { log_file_error "/tmp" "mktemp failed"; return 1; }
  if ! curl -fsSL "$KEY_URL" | gpg --dearmor > "$key_tmp" 2>/dev/null; then
    log_file_error "$key_tmp" "GPG key fetch/dearmor failed from $KEY_URL"
    rm -f "$key_tmp"; return 1
  fi
  if ! sudo install -D -o root -g root -m 644 "$key_tmp" "$KEYRING"; then
    log_file_error "$KEYRING" "keyring install failed"
    rm -f "$key_tmp"; return 1
  fi
  rm -f "$key_tmp"
  log_info "[27] Writing apt repo: $REPO_LIST"
  if ! echo "$REPO_LINE" | sudo tee "$REPO_LIST" >/dev/null; then
    log_file_error "$REPO_LIST" "repo file write failed"; return 1
  fi
  sudo apt-get update -y >/dev/null 2>&1 || true
}

verb_install() {
  log_info "[27] Starting Elasticsearch 8.x installer"
  if verify_installed; then log_ok "[27] Already installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0; fi
  if ! is_debian_family || ! is_apt_available; then log_err "[27] apt required"; return 1; fi
  setup_repo || return 1
  log_info "[27] Installing via apt: $APT_PKG"
  if sudo apt-get install -y $APT_PKG; then
    log_ok "[27] Installed"; mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_err "[27] apt install failed"; return 1
}
verb_check()     { if verify_installed; then log_ok "[27] Verify OK"; return 0; fi; log_warn "[27] Verify FAILED"; return 1; }
verb_repair()    { rm -f "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  sudo apt-get remove -y $APT_PKG || true
  sudo rm -f "$REPO_LIST" "$KEYRING"
  rm -f "$INSTALLED_MARK"
  log_ok "[27] Removed (apt + repo file + keyring)"
}
case "${1:-install}" in install) verb_install;; check) verb_check;; repair) verb_repair;; uninstall) verb_uninstall;; *) log_err "[27] Unknown verb: $1"; exit 2;; esac
