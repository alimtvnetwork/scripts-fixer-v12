#!/usr/bin/env bash
# 05-vault.sh -- AES-256-CBC + PBKDF2 secret store using openssl.
# Vault passphrase prompted once per session via VAULT_PASSPHRASE env var.
# NOTE: openssl's `enc` subcommand does not support GCM, so we use CBC
# with PBKDF2 key derivation. This is appropriate for local at-rest
# secret storage on a trusted controller (file mode is 0600, vault dir 0700).

VAULT_DIR="${VAULT_DIR:-$HOME/.local/share/ssh-orchestrator/vault}"

ensure_vault_dir() {
  if ! mkdir -p "$VAULT_DIR" 2>/dev/null; then
    log_file_error "$VAULT_DIR" "vault: mkdir failed"
    return 1
  fi
  chmod 700 "$VAULT_DIR"
}

vault_prompt_passphrase_once() {
  if [ -z "${VAULT_PASSPHRASE:-}" ]; then
    printf 'Vault passphrase: ' >&2
    stty -echo 2>/dev/null
    IFS= read -r VAULT_PASSPHRASE
    stty echo 2>/dev/null
    printf '\n' >&2
    export VAULT_PASSPHRASE
  fi
}

vault_put() {
  # vault_put <name> <plaintext>
  local name="$1" plain="$2"
  ensure_vault_dir || return 1
  vault_prompt_passphrase_once
  local out="$VAULT_DIR/$name.enc"
  if ! printf '%s' "$plain" | openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass env:VAULT_PASSPHRASE -out "$out" 2>/dev/null; then
    log_file_error "$out" "vault: openssl encrypt failed"
    return 1
  fi
  chmod 600 "$out"
}

vault_get() {
  # vault_get <name>  -> echoes plaintext on stdout
  local name="$1"
  local in="$VAULT_DIR/$name.enc"
  if [ ! -f "$in" ]; then
    log_file_error "$in" "vault: secret not found"
    return 1
  fi
  vault_prompt_passphrase_once
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass env:VAULT_PASSPHRASE -in "$in" 2>/dev/null; then
    log_file_error "$in" "vault: openssl decrypt failed (wrong passphrase?)"
    return 1
  fi
}
