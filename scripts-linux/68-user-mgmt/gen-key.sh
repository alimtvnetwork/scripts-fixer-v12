#!/usr/bin/env bash
# 68-user-mgmt/gen-key.sh -- generate an SSH keypair for the current user.
# Mirrors scripts/os/helpers/gen-key.ps1 on the Unix side.
#
# Usage:
#   ./gen-key.sh [--type ed25519|rsa|ecdsa] [--bits 4096]
#                [--out <path>] [--comment "..."]
#                [--passphrase <pw> | --no-passphrase | --ask]
#                [--force] [--dry-run]
#
# Defaults:
#   type    = ed25519
#   out     = ~/.ssh/id_<type>
#   comment = <user>@<host>
#
# Idempotent: refuses to overwrite an existing key unless --force.
# CODE-RED: every file/path error logs the exact path + reason.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"
. "$SCRIPT_DIR/helpers/_ssh-ledger.sh"
_PROMPT_SH="$SCRIPT_DIR/helpers/_prompt.sh"

um_usage() {
  cat <<EOF
Usage: gen-key.sh [options]

Options:
  --type ed25519|rsa|ecdsa     key algorithm (default: ed25519)
  --bits N                     bit length (rsa default 4096; ignored for ed25519)
  --out PATH                   private key path (default: ~/.ssh/id_<type>)
  --comment "..."              key comment (default: <user>@<host>)
  --passphrase PW              passphrase (visible in shell history)
  --no-passphrase              create key with empty passphrase
  --ask                        prompt for passphrase interactively
  --force                      overwrite an existing private key
  --dry-run                    print what would happen, change nothing
EOF
}

UM_TYPE="ed25519"
UM_BITS=""
UM_OUT=""
UM_COMMENT=""
UM_PASSPHRASE=""
UM_NO_PASS=0
UM_ASK=0
UM_FORCE=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)        um_usage; exit 0 ;;
    --type)           UM_TYPE="${2:-}"; shift 2 ;;
    --bits)           UM_BITS="${2:-}"; shift 2 ;;
    --out)            UM_OUT="${2:-}"; shift 2 ;;
    --comment)        UM_COMMENT="${2:-}"; shift 2 ;;
    --passphrase)     UM_PASSPHRASE="${2:-}"; shift 2 ;;
    --no-passphrase)  UM_NO_PASS=1; shift ;;
    --ask)            UM_ASK=1; shift ;;
    --force)          UM_FORCE=1; shift ;;
    --dry-run)        UM_DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) log_err "unknown option: '$1' (failure: see --help)"; exit 64 ;;
    *)  log_err "unexpected positional: '$1' (failure: gen-key takes only flags)"; exit 64 ;;
  esac
done

case "$UM_TYPE" in
  ed25519|rsa|ecdsa) ;;
  *) log_err "unsupported --type '$UM_TYPE' (failure: pick ed25519|rsa|ecdsa)"; exit 64 ;;
esac
[ "$UM_TYPE" = "rsa" ] && [ -z "$UM_BITS" ] && UM_BITS=4096

SSH_DIR="${HOME}/.ssh"
[ -z "$UM_OUT" ]     && UM_OUT="$SSH_DIR/id_$UM_TYPE"
[ -z "$UM_COMMENT" ] && UM_COMMENT="$(id -un 2>/dev/null || echo user)@$(hostname 2>/dev/null || echo host)"

if [ "$UM_ASK" = "1" ] && [ "$UM_NO_PASS" = "0" ] && [ -z "$UM_PASSPHRASE" ]; then
  if [ -f "$_PROMPT_SH" ]; then
    # shellcheck disable=SC1090
    . "$_PROMPT_SH"
    UM_PASSPHRASE=$(um_prompt_secret "Passphrase (blank = none)" 0)
  else
    log_warn "--ask requested but '_prompt.sh' missing at exact path: '$_PROMPT_SH' (failure: continuing with no passphrase)"
  fi
fi

if ! command -v ssh-keygen >/dev/null 2>&1; then
  log_err "ssh-keygen not found on PATH (failure: install openssh-client)"
  exit 127
fi

if [ -e "$UM_OUT" ] && [ "$UM_FORCE" != "1" ]; then
  log_err "Private key already exists at exact path: '$UM_OUT' (failure: pass --force to overwrite, or pick a different --out)"
  exit 1
fi

if [ ! -d "$SSH_DIR" ]; then
  if ! mkdir -p "$SSH_DIR"; then
    log_err "Failed to create SSH dir at exact path: '$SSH_DIR' (failure: mkdir refused)"
    exit 1
  fi
  chmod 700 "$SSH_DIR" 2>/dev/null || true
fi

if [ "$UM_DRY_RUN" = "1" ]; then
  echo ""
  echo "  DRY-RUN -- would generate keypair:"
  echo "    Type        : $UM_TYPE${UM_BITS:+ ($UM_BITS bits)}"
  echo "    Out         : $UM_OUT  (+ ${UM_OUT}.pub)"
  echo "    Comment     : $UM_COMMENT"
  if [ "$UM_NO_PASS" = "1" ] || [ -z "$UM_PASSPHRASE" ]; then
    echo "    Passphrase  : (none)"
  else
    echo "    Passphrase  : (set)"
  fi
  exit 0
fi

# Remove old files when --force.
if [ "$UM_FORCE" = "1" ]; then
  rm -f -- "$UM_OUT" "${UM_OUT}.pub"
fi

PP="$UM_PASSPHRASE"
[ "$UM_NO_PASS" = "1" ] && PP=""

KGARGS=(-t "$UM_TYPE" -f "$UM_OUT" -C "$UM_COMMENT" -N "$PP" -q)
[ -n "$UM_BITS" ] && KGARGS+=(-b "$UM_BITS")

if ! ssh-keygen "${KGARGS[@]}"; then
  log_err "ssh-keygen failed for out='$UM_OUT' (failure: non-zero exit)"
  exit 1
fi
if [ ! -f "${UM_OUT}.pub" ]; then
  log_err "Public key was not produced at exact path: '${UM_OUT}.pub' (failure: ssh-keygen ran but output missing)"
  exit 1
fi
chmod 600 "$UM_OUT" 2>/dev/null || true
chmod 644 "${UM_OUT}.pub" 2>/dev/null || true

FP=""
if FP_LINE=$(ssh-keygen -lf "${UM_OUT}.pub" 2>/dev/null); then
  FP=$(echo "$FP_LINE" | awk '{print $2}')
fi

um_ledger_add "generate" "$FP" "${UM_OUT}.pub" "gen-key" "$UM_COMMENT" || true

echo ""
echo "  Key Generation Summary"
echo "  ======================"
echo "    Private key : $UM_OUT"
echo "    Public key  : ${UM_OUT}.pub"
echo "    Type        : $UM_TYPE${UM_BITS:+ ($UM_BITS bits)}"
echo "    Comment     : $UM_COMMENT"
[ -n "$FP" ] && echo "    Fingerprint : $FP"
echo ""
exit 0
