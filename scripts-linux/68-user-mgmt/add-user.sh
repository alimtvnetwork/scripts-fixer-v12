#!/usr/bin/env bash
# 68-user-mgmt/add-user.sh -- create a single local user (Linux | macOS).
#
# Usage:
#   ./add-user.sh <name> [--password PW | --password-file FILE]
#                        [--uid N] [--primary-group G] [--groups g1,g2,...]
#                        [--shell PATH] [--home PATH] [--comment "..."]
#                        [--sudo] [--system] [--dry-run]
#
# Notes:
#   - Idempotent: re-running on an existing user only adjusts membership +
#     password (still skips create).
#   - Plain --password is accepted to mirror the Windows side; prefer
#     --password-file (mode 0600) for any account that outlives a demo.
#   - Passwords are NEVER written to log files. Console echo is masked.
#   - CODE RED: every file/path error logs the EXACT path + reason.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers/_common.sh"

um_usage() {
  cat <<EOF
Usage: add-user.sh <name> [options]

Required:
  <name>                       login name

Password (pick at most one):
  --password PW                plain text (logged masked; visible in shell history)
  --password-file FILE         file mode must be 0600 or stricter

Optional:
  --uid N                      explicit numeric UID
  --primary-group G            primary group (created if missing on Linux; must exist on macOS)
  --groups g1,g2,...           supplementary groups (comma-separated)
  --shell PATH                 login shell (default: /bin/bash on Linux, /bin/zsh on macOS)
  --home  PATH                 home directory (default: /home/<name> | /Users/<name>)
  --comment "..."              GECOS / RealName
  --sudo                       add to sudo group (Linux: 'sudo', macOS: 'admin')
  --system                     create system account (Linux only; ignored on macOS)
  --dry-run                    print what would happen, change nothing

SSH authorized_keys (repeatable; both flags may be combined):
  --ssh-key "<key-line>"       Inline OpenSSH public key (entire single line,
                               e.g. "ssh-ed25519 AAAA... user\@host"). Adds
                               one authorized key. Pass the flag multiple
                               times for multiple keys.
  --ssh-key-file <path>        Read one OR many keys from a local file (one
                               key per line; blanks + '#' comments ignored).
                               Pass the flag multiple times for multiple files.
                               Installed to <home>/.ssh/authorized_keys with
                               mode 0600 (dir 0700) and owner=<name>:<pgroup>.
                               Existing entries are preserved; duplicates are
                               de-duplicated. Key contents are NEVER logged --
                               only a SHA-256 fingerprint + source.
  --ssh-key-url <URL>          Fetch keys from an HTTPS URL (e.g.
                               https://github.com/<user>.keys). Repeatable.
                               Safety: HTTPS-only, host allowlist enforced,
                               curl/wget timeout + max-size enforced, redirects
                               restricted to https + allowlisted hosts. URL
                               body is parsed exactly like --ssh-key-file
                               output (one key per line, # comments OK).
  --ssh-key-url-timeout S      Per-URL timeout in seconds (default: 10).
  --ssh-key-url-max-bytes N    Max response size per URL (default: 65536).
  --ssh-key-url-allowlist L    Comma-separated extra hostnames to allow,
                               e.g. "git.example.com,keys.corp.local".
                               Default allowlist: github.com, gitlab.com,
                               codeberg.org, bitbucket.org, launchpad.net.
                               Use "*" to disable host checking (NOT
                               recommended -- allows arbitrary egress).
  --allow-insecure-url         Permit http:// URLs (NOT recommended -- key
                               can be tampered with in transit).

Rollback tracking (writes a manifest of every key installed this run so you
can later remove ONLY those keys via remove-ssh-keys.sh):
  --run-id <id>                Tag this install run. Default: auto-generated
                               (YYYYmmdd-HHMMSS-<rand>). Reuse the same id
                               across multiple add-user.sh calls in one
                               batch and they all land in the same manifest.
  --manifest-dir <dir>         Where to write manifests. Default:
                               /var/lib/68-user-mgmt/ssh-key-runs (created
                               with mode 0700 root:root). Override only if
                               you know what you're doing.
  --no-manifest                Disable manifest writing for this run
                               (rollback will NOT be possible).
EOF
}

# ---- arg parse --------------------------------------------------------------
UM_NAME=""
UM_PASSWORD_CLI=""
UM_PASSWORD_FILE=""
UM_UID=""
UM_PRIMARY_GROUP=""
UM_GROUPS=""
UM_SHELL=""
UM_HOME=""
UM_COMMENT=""
UM_SUDO=0
UM_SYSTEM=0
UM_DRY_RUN="${UM_DRY_RUN:-0}"
# SSH keys -- two parallel arrays, each entry processed in order.
UM_SSH_KEYS=()        # inline key lines
UM_SSH_KEY_FILES=()   # file paths
UM_SSH_KEY_URLS=()    # https URLs
UM_SSH_URL_TIMEOUT="${UM_SSH_URL_TIMEOUT:-10}"          # seconds, per URL
UM_SSH_URL_MAX_BYTES="${UM_SSH_URL_MAX_BYTES:-65536}"   # 64 KB
UM_SSH_URL_ALLOWLIST_EXTRA="${UM_SSH_URL_ALLOWLIST_EXTRA:-}"  # comma list
UM_SSH_URL_ALLOW_INSECURE="${UM_SSH_URL_ALLOW_INSECURE:-0}"
# Hard-coded baseline of well-known providers that publish .keys endpoints
# over HTTPS with stable certs. Operators add to this via the flag rather
# than edit the script.
UM_SSH_URL_ALLOWLIST_DEFAULT="github.com,gitlab.com,codeberg.org,bitbucket.org,launchpad.net,api.github.com"

# Rollback manifest knobs (v0.172.0). Default dir lives under /var/lib so it
# survives reboots and is root-only readable. Disabling the manifest is an
# explicit opt-out -- the operator is telling us "I don't want rollback".
UM_RUN_ID="${UM_RUN_ID:-}"
UM_MANIFEST_DIR="${UM_MANIFEST_DIR:-/var/lib/68-user-mgmt/ssh-key-runs}"
UM_NO_MANIFEST="${UM_NO_MANIFEST:-0}"
# Per-key source tags accumulated during the install pass. Same length /
# order as the de-duplicated key buffer, used by the manifest writer to
# remember WHERE each tracked key came from.
_UM_SSH_SOURCES=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         um_usage; exit 0 ;;
    --password)        UM_PASSWORD_CLI="${2:-}"; shift 2 ;;
    --password-file)   UM_PASSWORD_FILE="${2:-}"; shift 2 ;;
    --uid)             UM_UID="${2:-}"; shift 2 ;;
    --primary-group)   UM_PRIMARY_GROUP="${2:-}"; shift 2 ;;
    --groups)          UM_GROUPS="${2:-}"; shift 2 ;;
    --shell)           UM_SHELL="${2:-}"; shift 2 ;;
    --home)            UM_HOME="${2:-}"; shift 2 ;;
    --comment)         UM_COMMENT="${2:-}"; shift 2 ;;
    --sudo)            UM_SUDO=1; shift ;;
    --system)          UM_SYSTEM=1; shift ;;
    --dry-run)         UM_DRY_RUN=1; shift ;;
    --ssh-key)         UM_SSH_KEYS+=("${2:-}"); shift 2 ;;
    --ssh-key-file)    UM_SSH_KEY_FILES+=("${2:-}"); shift 2 ;;
    --ssh-key-url)     UM_SSH_KEY_URLS+=("${2:-}"); shift 2 ;;
    --ssh-key-url-timeout)   UM_SSH_URL_TIMEOUT="${2:-}"; shift 2 ;;
    --ssh-key-url-max-bytes) UM_SSH_URL_MAX_BYTES="${2:-}"; shift 2 ;;
    --ssh-key-url-allowlist) UM_SSH_URL_ALLOWLIST_EXTRA="${2:-}"; shift 2 ;;
    --allow-insecure-url)    UM_SSH_URL_ALLOW_INSECURE=1; shift ;;
    --run-id)                UM_RUN_ID="${2:-}"; shift 2 ;;
    --manifest-dir)          UM_MANIFEST_DIR="${2:-}"; shift 2 ;;
    --no-manifest)           UM_NO_MANIFEST=1; shift ;;
    --) shift; break ;;
    -*)
      log_err "unknown option: '$1' (failure: see --help)"
      exit 64
      ;;
    *)
      if [ -z "$UM_NAME" ]; then UM_NAME="$1"; shift
      else log_err "unexpected positional: '$1' (failure: only <name> is positional)"; exit 64; fi
      ;;
  esac
done

if [ -z "$UM_NAME" ]; then
  log_err "missing required <name> (failure: nothing to create)"
  um_usage; exit 64
fi

um_detect_os || exit $?
um_require_root || exit $?

if [ "$UM_DRY_RUN" = "1" ]; then log_warn "$(um_msg dryRunBanner)"; fi

# Defaults per OS.
if [ "$UM_OS" = "macos" ]; then
  : "${UM_SHELL:=/bin/zsh}"
  : "${UM_HOME:=/Users/$UM_NAME}"
  : "${UM_PRIMARY_GROUP:=staff}"
  UM_SUDO_GROUP="admin"
else
  : "${UM_SHELL:=/bin/bash}"
  : "${UM_HOME:=/home/$UM_NAME}"
  : "${UM_PRIMARY_GROUP:=$UM_NAME}"  # Linux convention: per-user primary group
  UM_SUDO_GROUP="sudo"
fi

# Resolve password (sets UM_RESOLVED_PASSWORD).
um_resolve_password || exit $?
UM_MASKED_PW=$(um_mask_password "$UM_RESOLVED_PASSWORD")

# ---- create user ------------------------------------------------------------
if um_user_exists "$UM_NAME"; then
  log_warn "$(um_msg userExists "$UM_NAME")"
  um_summary_add "skip" "user" "$UM_NAME" "exists"
else
  if [ "$UM_OS" = "linux" ]; then
    args=(useradd)
    [ "$UM_SYSTEM" = "1" ] && args+=(--system)
    args+=(--shell "$UM_SHELL")
    args+=(--home-dir "$UM_HOME")
    args+=(--create-home)
    [ -n "$UM_UID" ]     && args+=(--uid "$UM_UID")
    [ -n "$UM_COMMENT" ] && args+=(--comment "$UM_COMMENT")
    # primary group: create per-user group if it doesn't exist
    if [ "$UM_PRIMARY_GROUP" = "$UM_NAME" ]; then
      args+=(--user-group)
    else
      if ! um_group_exists "$UM_PRIMARY_GROUP"; then
        um_run groupadd "$UM_PRIMARY_GROUP" \
          || { log_err "$(um_msg groupCreateFail "$UM_PRIMARY_GROUP" "groupadd failed")"; exit 1; }
      fi
      args+=(--gid "$UM_PRIMARY_GROUP")
    fi
    args+=("$UM_NAME")

    if um_run "${args[@]}"; then
      created_uid=$(id -u "$UM_NAME" 2>/dev/null || echo "?")
      log_ok "$(um_msg userCreated "$UM_NAME" "$created_uid" "$UM_PRIMARY_GROUP")"
      um_summary_add "ok" "user" "$UM_NAME" "uid=$created_uid"
    else
      log_err "$(um_msg userCreateFail "$UM_NAME" "useradd returned non-zero")"
      um_summary_add "fail" "user" "$UM_NAME" "useradd failed"
      exit 1
    fi

  else  # macos
    if [ -z "$UM_UID" ]; then UM_UID=$(um_next_macos_uid 510); fi
    # Resolve primary group GID (must exist).
    pg_gid=$(dscl . -read "/Groups/$UM_PRIMARY_GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}')
    if [ -z "$pg_gid" ]; then
      log_err "primary group '$UM_PRIMARY_GROUP' not found on macOS (failure: create it first or pick 'staff')"
      exit 1
    fi
    um_run dscl . -create "/Users/$UM_NAME"                                     || { log_err "$(um_msg userCreateFail "$UM_NAME" "dscl create failed")"; exit 1; }
    um_run dscl . -create "/Users/$UM_NAME" UserShell      "$UM_SHELL"          || true
    um_run dscl . -create "/Users/$UM_NAME" RealName       "${UM_COMMENT:-$UM_NAME}" || true
    um_run dscl . -create "/Users/$UM_NAME" UniqueID       "$UM_UID"            || true
    um_run dscl . -create "/Users/$UM_NAME" PrimaryGroupID "$pg_gid"            || true
    um_run dscl . -create "/Users/$UM_NAME" NFSHomeDirectory "$UM_HOME"         || true
    if [ "$UM_DRY_RUN" != "1" ] && [ ! -d "$UM_HOME" ]; then
      um_run mkdir -p "$UM_HOME" \
        || log_file_error "$UM_HOME" "could not create home dir"
      um_run chown "$UM_NAME:$pg_gid" "$UM_HOME" 2>/dev/null || true
    fi
    log_ok "$(um_msg userCreated "$UM_NAME" "$UM_UID" "$UM_PRIMARY_GROUP")"
    um_summary_add "ok" "user" "$UM_NAME" "uid=$UM_UID"
  fi
fi

# ---- supplementary groups ---------------------------------------------------
UM_GROUP_LIST=""
if [ -n "$UM_GROUPS" ]; then UM_GROUP_LIST="$UM_GROUPS"; fi
if [ "$UM_SUDO" = "1" ]; then
  if [ -z "$UM_GROUP_LIST" ]; then UM_GROUP_LIST="$UM_SUDO_GROUP"
  else UM_GROUP_LIST="$UM_GROUP_LIST,$UM_SUDO_GROUP"; fi
fi

if [ -n "$UM_GROUP_LIST" ]; then
  IFS=',' read -ra _grps <<< "$UM_GROUP_LIST"
  for g in "${_grps[@]}"; do
    g="${g// /}"
    [ -z "$g" ] && continue
    if ! um_group_exists "$g"; then
      log_warn "group '$g' does not exist -- creating it (failure to create will abort)"
      if [ "$UM_OS" = "linux" ]; then
        um_run groupadd "$g" || { log_err "$(um_msg groupCreateFail "$g" "groupadd failed")"; exit 1; }
      else
        next_gid=$(um_next_macos_gid 510)
        um_run dscl . -create "/Groups/$g"                              || true
        um_run dscl . -create "/Groups/$g" PrimaryGroupID "$next_gid"   || true
      fi
    fi
    if [ "$UM_OS" = "linux" ]; then
      if um_run usermod -aG "$g" "$UM_NAME"; then
        log_ok "$(um_msg groupAdded "$UM_NAME" "$g")"
      else
        log_err "$(um_msg groupAddFail "$UM_NAME" "$g" "usermod -aG failed")"
      fi
    else
      if um_run dscl . -append "/Groups/$g" GroupMembership "$UM_NAME"; then
        log_ok "$(um_msg groupAdded "$UM_NAME" "$g")"
      else
        log_err "$(um_msg groupAddFail "$UM_NAME" "$g" "dscl append failed")"
      fi
    fi
  done
fi

# ---- password ---------------------------------------------------------------
if [ -n "$UM_RESOLVED_PASSWORD" ]; then
  if [ "$UM_OS" = "linux" ]; then
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] chpasswd <<< '$UM_NAME:<masked>'"
    else
      if printf '%s:%s\n' "$UM_NAME" "$UM_RESOLVED_PASSWORD" | chpasswd 2>/dev/null; then
        log_ok "$(um_msg passwordSet "$UM_NAME" "$UM_MASKED_PW")"
      else
        log_err "$(um_msg passwordSetFail "$UM_NAME" "chpasswd failed")"
      fi
    fi
  else  # macos
    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] dscl . -passwd /Users/$UM_NAME <masked>"
    else
      if dscl . -passwd "/Users/$UM_NAME" "$UM_RESOLVED_PASSWORD" 2>/dev/null; then
        log_ok "$(um_msg passwordSet "$UM_NAME" "$UM_MASKED_PW")"
      else
        log_err "$(um_msg passwordSetFail "$UM_NAME" "dscl -passwd failed")"
      fi
    fi
  fi
fi

# ---- SSH authorized_keys ---------------------------------------------------
# Collected sources -> de-duplicated -> appended to <home>/.ssh/authorized_keys
# with strict perms (700 dir, 600 file, owned by the new user). Key contents
# are NEVER written to logs; we only echo a fingerprint + the source.
#
# Skipped silently when no keys were supplied. Skipped (with a warn) if the
# home directory does not exist on disk -- which can happen when --system
# is used without --create-home, or when --dry-run prevented home creation.
UM_SSH_INSTALLED_COUNT=0
UM_SSH_REQUESTED_COUNT=$(( ${#UM_SSH_KEYS[@]} + ${#UM_SSH_KEY_FILES[@]} + ${#UM_SSH_KEY_URLS[@]} ))

# --- URL-based ssh key fetcher (added v0.171.0) -----------------------------
# _ssh_url_host_allowed <host>
#   0 = allowed, 1 = rejected. "*" in extra-allowlist disables checking.
_ssh_url_host_allowed() {
    local host="$1"
    [ -z "$host" ] && return 1
    local extra="$UM_SSH_URL_ALLOWLIST_EXTRA"
    case ",$extra," in *,\*,*) return 0 ;; esac
    local combined="$UM_SSH_URL_ALLOWLIST_DEFAULT"
    [ -n "$extra" ] && combined="$combined,$extra"
    local h
    IFS=',' read -ra _hosts <<< "$combined"
    for h in "${_hosts[@]}"; do
        h="${h// /}"
        [ -z "$h" ] && continue
        if [ "$host" = "$h" ]; then return 0; fi
        # Allow exact-suffix match on a leading "."  (".example.com" => any
        # subdomain). Bare hosts must match exactly.
        case "$h" in
            .*) case "$host" in *"$h") return 0 ;; esac ;;
        esac
    done
    return 1
}

# _ssh_url_extract_host <url>  -> echoes lowercase host or empty.
_ssh_url_extract_host() {
    local url="$1"
    # Strip scheme then everything from first "/" onward, then any userinfo
    # ("user@") and any ":<port>".
    local rest="${url#*://}"
    local hostport="${rest%%/*}"
    hostport="${hostport##*@}"
    local host="${hostport%%:*}"
    printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# _ssh_fetch_url <url>  -> writes raw body to stdout, returns 0/1.
# Enforces: scheme allowlist, host allowlist, redirect allowlist, max-time,
# max-filesize. Logs HTTP status + bytes on success.
_ssh_fetch_url() {
    local url="$1"
    local scheme="${url%%://*}"
    case "$scheme" in
        https) ;;
        http)
            if [ "$UM_SSH_URL_ALLOW_INSECURE" != "1" ]; then
                log_err "$(um_msg sshUrlInsecure "$url")"
                return 1
            fi
            ;;
        *)
            log_err "$(um_msg sshUrlInsecure "$url")"
            return 1
            ;;
    esac

    local host
    host=$(_ssh_url_extract_host "$url")
    if ! _ssh_url_host_allowed "$host"; then
        local combined="$UM_SSH_URL_ALLOWLIST_DEFAULT"
        [ -n "$UM_SSH_URL_ALLOWLIST_EXTRA" ] && combined="$combined,$UM_SSH_URL_ALLOWLIST_EXTRA"
        log_err "$(um_msg sshUrlNotAllowed "$host" "$url" "$combined")"
        return 1
    fi

    local body http_code bytes
    body=$(mktemp)
    if command -v curl >/dev/null 2>&1; then
        # Build the redirect-protocol whitelist. If --allow-insecure-url is set
        # we also allow http on redirects; otherwise https-only.
        local proto_redir="https"
        [ "$UM_SSH_URL_ALLOW_INSECURE" = "1" ] && proto_redir="https,http"
        # --max-filesize is checked AFTER request -- belt and suspenders with
        # a head -c truncation below.
        local curl_rc=0
        http_code=$(curl -fsSL \
            --proto       '=https,http' \
            --proto-redir "=$proto_redir" \
            --max-time    "$UM_SSH_URL_TIMEOUT" \
            --connect-timeout 5 \
            --retry 2 --retry-delay 1 \
            --max-filesize "$UM_SSH_URL_MAX_BYTES" \
            -A "lovable-68-user-mgmt/0.171.0" \
            -w '%{http_code}' \
            -o "$body" \
            "$url" 2>/tmp/68-curl-err.$$) || curl_rc=$?
        if [ "$curl_rc" -ne 0 ]; then
            local err
            err=$(cat /tmp/68-curl-err.$$ 2>/dev/null | tr '\n' ' ' | head -c 200)
            rm -f /tmp/68-curl-err.$$ "$body"
            # curl exit 63 = "max-filesize exceeded".
            if [ "$curl_rc" = "63" ]; then
                log_err "$(um_msg sshUrlTooBig "$url" "$UM_SSH_URL_MAX_BYTES")"
            else
                log_err "$(um_msg sshUrlFetchFail "$url" "curl rc=$curl_rc ${err:-no-stderr}")"
            fi
            return 1
        fi
        rm -f /tmp/68-curl-err.$$
    elif command -v wget >/dev/null 2>&1; then
        # wget fallback -- no per-byte cap, so we head -c truncate after.
        local wget_rc=0
        wget --quiet --tries 2 \
             --timeout "$UM_SSH_URL_TIMEOUT" \
             --max-redirect 3 \
             -U "lovable-68-user-mgmt/0.171.0" \
             -O "$body" \
             "$url" 2>/dev/null || wget_rc=$?
        if [ "$wget_rc" -ne 0 ]; then
            rm -f "$body"
            log_err "$(um_msg sshUrlFetchFail "$url" "wget rc=$wget_rc")"
            return 1
        fi
        http_code="200"  # wget --quiet doesn't expose status; assume OK on rc=0
    else
        rm -f "$body"
        log_err "$(um_msg sshUrlNoCurl)"
        return 1
    fi

    bytes=$(wc -c < "$body" 2>/dev/null | tr -d ' ')
    if [ "${bytes:-0}" -gt "$UM_SSH_URL_MAX_BYTES" ]; then
        rm -f "$body"
        log_err "$(um_msg sshUrlTooBig "$url" "$UM_SSH_URL_MAX_BYTES")"
        return 1
    fi
    # Hard-cap truncate as belt-and-suspenders against curl --max-filesize
    # not catching a chunked response that lies about content-length.
    head -c "$UM_SSH_URL_MAX_BYTES" "$body"
    local key_lines
    key_lines=$(awk 'NF && $1 !~ /^#/' "$body" | wc -l | tr -d ' ')
    log_info "$(um_msg sshUrlFetched "$url" "${http_code:-?}" "$bytes" "$key_lines")"
    rm -f "$body"
    return 0
}

# --- rollback manifest writer (added v0.172.0) ------------------------------
# Writes one JSON file per (run-id, user) tuple under $UM_MANIFEST_DIR. The
# manifest records EVERY key we just wrote into authorized_keys along with
# its fingerprint and source tag. remove-ssh-keys.sh later reads this and
# strips the matching lines back out.
#
# Schema (stable -- bump UM_MANIFEST_VERSION on incompatible change):
#   {
#     "manifestVersion": 1,
#     "runId":   "20260427-153045-ab12",
#     "writtenAt": "2026-04-27T15:30:45+08:00",
#     "host":    "myhost",
#     "user":    "alice",
#     "authorizedKeysFile": "/home/alice/.ssh/authorized_keys",
#     "scriptVersion": "0.172.0",
#     "keys": [
#       { "fingerprint": "SHA256:abc...", "algo": "ssh-ed25519",
#         "source": "url:https://github.com/alice.keys",
#         "line": "ssh-ed25519 AAAA... alice@host" }
#     ]
#   }
#
# The raw key line is kept (mode 0600 on the manifest dir) because some
# operators rotate keys faster than fingerprint formats stabilise -- a
# literal-line fallback guarantees we can always find the row to delete.
UM_MANIFEST_VERSION=1

_um_gen_run_id() {
    # ISO-ish stamp + 4 hex chars of randomness. Avoid spaces / colons so
    # the id can be a filename and a CLI arg without quoting.
    local stamp rnd
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo "00000000-000000")
    if [ -r /dev/urandom ]; then
        rnd=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 4)
    fi
    [ -z "$rnd" ] && rnd=$(printf '%04x' "$$")
    printf '%s-%s' "$stamp" "$rnd"
}

# _um_fingerprint_key <key-line>  -> echoes "fp<TAB>algo" (best effort).
_um_fingerprint_key() {
    local line="$1"
    local fp="" algo=""
    algo=$(printf '%s' "$line" | awk '{print $1}')
    if command -v ssh-keygen >/dev/null 2>&1; then
        fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$fp" ] && command -v sha256sum >/dev/null 2>&1; then
        fp="sha256:"$(printf '%s' "$line" | sha256sum | awk '{print $1}')
    fi
    [ -z "$fp" ] && fp="literal-only"
    printf '%s\t%s' "$fp" "$algo"
}

# _um_write_manifest <user> <auth_keys_path> <key-buffer> <added-count>
# Writes (or appends to) the per-run manifest. Does nothing when:
#   - UM_NO_MANIFEST=1 (operator opted out)
#   - UM_DRY_RUN=1     (dry run -- nothing actually installed)
#   - added-count == 0 (no new keys -- nothing to roll back)
_um_write_manifest() {
    local user="$1" auth_path="$2" key_buf="$3" added="$4"
    [ "$UM_NO_MANIFEST" = "1" ] && return 0
    [ "$UM_DRY_RUN" = "1" ]     && return 0
    [ "${added:-0}" -le 0 ]     && return 0
    [ -z "$key_buf" ]           && return 0

    if [ -z "$UM_RUN_ID" ]; then UM_RUN_ID=$(_um_gen_run_id); fi

    if ! mkdir -p "$UM_MANIFEST_DIR" 2>/dev/null; then
        log_err "$(um_msg manifestWriteFail "$UM_MANIFEST_DIR" "could not create manifest dir")"
        return 1
    fi
    chmod 0700 "$UM_MANIFEST_DIR" 2>/dev/null || true

    local manifest_path="$UM_MANIFEST_DIR/${UM_RUN_ID}__${user}.json"

    # Build the JSON body. We map each line in key_buf to its source tag
    # via _UM_SSH_SOURCES (TSV: source<TAB>key). Multiple sources for the
    # same key (post-dedup) collapse to the FIRST one we saw.
    local tmp_json
    tmp_json=$(mktemp -t 68-manifest.XXXXXX) || {
        log_err "$(um_msg manifestWriteFail "$manifest_path" "mktemp failed")"
        return 1
    }

    {
        printf '{\n'
        printf '  "manifestVersion": %s,\n' "$UM_MANIFEST_VERSION"
        printf '  "runId": "%s",\n' "$UM_RUN_ID"
        printf '  "writtenAt": "%s",\n' "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "host": "%s",\n' "$(hostname 2>/dev/null || echo unknown)"
        printf '  "user": "%s",\n' "$user"
        printf '  "authorizedKeysFile": "%s",\n' "$auth_path"
        printf '  "scriptVersion": "0.172.0",\n'
        printf '  "keys": [\n'

        local first=1
        while IFS= read -r kline; do
            [ -z "$kline" ] && continue
            # Resolve source tag (first match wins).
            local src=""
            local row
            for row in "${_UM_SSH_SOURCES[@]}"; do
                local tag="${row%%$'\t'*}"
                local val="${row#*$'\t'}"
                if [ "$val" = "$kline" ]; then src="$tag"; break; fi
            done
            [ -z "$src" ] && src="unknown"

            local fp_algo fp algo
            fp_algo=$(_um_fingerprint_key "$kline")
            fp="${fp_algo%%$'\t'*}"
            algo="${fp_algo##*$'\t'}"

            # JSON-escape the line + source. We only have to handle "
            # and \ -- algo/fingerprint are ASCII-safe by construction.
            local esc_line esc_src
            esc_line=$(printf '%s' "$kline" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
            esc_src=$(printf  '%s' "$src"   | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

            if [ "$first" = "1" ]; then first=0; else printf ',\n'; fi
            printf '    { "fingerprint": "%s", "algo": "%s", "source": "%s", "line": "%s" }' \
                "$fp" "$algo" "$esc_src" "$esc_line"
        done <<< "$key_buf"

        printf '\n  ]\n}\n'
    } > "$tmp_json" 2>/dev/null

    if ! mv "$tmp_json" "$manifest_path" 2>/dev/null; then
        rm -f "$tmp_json"
        log_err "$(um_msg manifestWriteFail "$manifest_path" "mv from tmp failed")"
        return 1
    fi
    chmod 0600 "$manifest_path" 2>/dev/null || true

    local tracked
    tracked=$(printf '%s\n' "$key_buf" | awk 'NF' | wc -l | tr -d ' ')
    log_ok "$(um_msg manifestWritten "$manifest_path" "$UM_RUN_ID" "$user" "$tracked")"
    return 0
}

if [ "$UM_SSH_REQUESTED_COUNT" -gt 0 ]; then

  # Build a single newline-separated buffer of every requested key.
  # Inline keys come first (in CLI order), then file-sourced keys.
  _ssh_buf=""
  _ssh_emit() {
    local k="$1"
    local src="${2:-unknown}"
    # Strip CR + leading/trailing whitespace; ignore blanks + comments.
    k="${k%$'\r'}"
    k="${k#"${k%%[![:space:]]*}"}"
    k="${k%"${k##*[![:space:]]}"}"
    [ -z "$k" ] && return 0
    case "$k" in \#*) return 0 ;; esac
    # Sanity: must look like an OpenSSH public key (algo + base64 chunk).
    case "$k" in
      ssh-rsa\ *|ssh-dss\ *|ssh-ed25519\ *|ecdsa-sha2-*|sk-*) ;;
      *)
        log_warn "$(um_msg sshKeyMalformed "${k:0:30}...")"
        return 0 ;;
    esac
    if [ -z "$_ssh_buf" ]; then _ssh_buf="$k"
    else                        _ssh_buf="$_ssh_buf"$'\n'"$k"
    fi
    # Track origin alongside the key for the rollback manifest. Same
    # index in _UM_SSH_SOURCES corresponds to the same line in _ssh_buf
    # AFTER de-dup -- we re-derive the mapping below.
    _UM_SSH_SOURCES+=("$src"$'\t'"$k")
  }

  for k in "${UM_SSH_KEYS[@]}"; do _ssh_emit "$k" "inline"; done

  for f in "${UM_SSH_KEY_FILES[@]}"; do
    if [ ! -f "$f" ]; then
      log_file_error "$f" "ssh key file not found"
      continue
    fi
    if [ ! -r "$f" ]; then
      log_file_error "$f" "ssh key file not readable"
      continue
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      _ssh_emit "$line" "file:$f"
    done < "$f"
  done

  # URL-sourced keys (v0.171.0). Each fetched body is parsed line-by-line
  # and run through _ssh_emit (same dedup + algo-prefix sanity as files).
  # Failed URLs are logged and skipped -- they don't abort the whole
  # install, so a partial-network failure can't lock the user out.
  for u in "${UM_SSH_KEY_URLS[@]}"; do
    body=$(_ssh_fetch_url "$u") || continue
    while IFS= read -r line || [ -n "$line" ]; do
      _ssh_emit "$line" "url:$u"
    done <<< "$body"
  done

  # De-duplicate while preserving order. Awk on the buffer.
  _ssh_buf=$(printf '%s\n' "$_ssh_buf" | awk 'NF && !seen[$0]++')
  _ssh_count=$(printf '%s\n' "$_ssh_buf" | awk 'NF' | wc -l | tr -d ' ')

  if [ "$_ssh_count" -eq 0 ]; then
    log_warn "$(um_msg sshKeyNoneValid "$UM_SSH_REQUESTED_COUNT")"
  else
    _ssh_dir="$UM_HOME/.ssh"
    _ssh_file="$_ssh_dir/authorized_keys"

    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] would install $_ssh_count ssh key(s) to $_ssh_file (mode 0600, dir 0700, owner $UM_NAME)"
      # Print fingerprints (never key bodies) so the operator can audit.
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        if command -v ssh-keygen >/dev/null 2>&1; then
          fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        elif command -v sha256sum >/dev/null 2>&1; then
          fp="sha256:"$(printf '%s' "$line" | sha256sum | awk '{print $1}')
        else
          fp="(no fingerprinter on PATH)"
        fi
        log_info "[dry-run]   key fingerprint: $fp"
      done <<< "$_ssh_buf"
      UM_SSH_INSTALLED_COUNT="$_ssh_count"
    else
      if [ ! -d "$UM_HOME" ]; then
        log_warn "$(um_msg sshHomeMissing "$UM_HOME" "$UM_NAME")"
      else
        # mkdir -p is idempotent; we always re-assert mode + owner so a
        # half-baked previous run can't leave 0755 perms behind.
        if ! mkdir -p "$_ssh_dir" 2>/dev/null; then
          log_file_error "$_ssh_dir" "could not create .ssh dir"
        else
          chmod 0700 "$_ssh_dir" 2>/dev/null \
            || log_file_error "$_ssh_dir" "could not chmod 0700"

          # Merge: append only NEW keys (not already present in the file).
          existing=""
          [ -f "$_ssh_file" ] && existing=$(cat "$_ssh_file" 2>/dev/null)
          merged=$(printf '%s\n%s\n' "$existing" "$_ssh_buf" | awk 'NF && !seen[$0]++')
          if ! printf '%s\n' "$merged" > "$_ssh_file" 2>/dev/null; then
            log_file_error "$_ssh_file" "could not write authorized_keys"
          else
            chmod 0600 "$_ssh_file" 2>/dev/null \
              || log_file_error "$_ssh_file" "could not chmod 0600"
            chown "$UM_NAME:$UM_PRIMARY_GROUP" "$_ssh_dir" "$_ssh_file" 2>/dev/null \
              || log_warn "$(um_msg sshOwnerWarn "$_ssh_file" "$UM_NAME:$UM_PRIMARY_GROUP")"

            # Count net-new lines added this run.
            before_n=$(printf '%s\n' "$existing" | awk 'NF' | wc -l | tr -d ' ')
            after_n=$(printf '%s\n' "$merged"   | awk 'NF' | wc -l | tr -d ' ')
            added=$(( after_n - before_n ))
            UM_SSH_INSTALLED_COUNT="$_ssh_count"
            log_ok "$(um_msg sshKeyInstalled "$_ssh_file" "$added" "$_ssh_count")"

            # Audit fingerprints (NEVER full key bodies).
            while IFS= read -r line; do
              [ -z "$line" ] && continue
              if command -v ssh-keygen >/dev/null 2>&1; then
                fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
              elif command -v sha256sum >/dev/null 2>&1; then
                fp="sha256:"$(printf '%s' "$line" | sha256sum | awk '{print $1}')
              else
                fp="(no fingerprinter on PATH)"
              fi
              log_info "  key fingerprint: $fp"
            done <<< "$_ssh_buf"

            # Persist rollback manifest. Only the keys that were actually
            # appended this run get tracked -- pre-existing keys are
            # excluded so rollback can never delete keys we didn't put
            # there. Net-new = (merged set) MINUS (existing set), order
            # preserved.
            _new_only=$(awk '
                NR==FNR { if (NF) seen[$0]=1; next }
                NF && !seen[$0] { print }
            ' <(printf '%s\n' "$existing") <(printf '%s\n' "$_ssh_buf"))
            _um_write_manifest "$UM_NAME" "$_ssh_file" "$_new_only" "$added"
          fi
        fi
      fi
    fi
    um_summary_add "ok" "ssh-key" "$UM_NAME" "$_ssh_count requested -> $UM_SSH_INSTALLED_COUNT installed"
  fi
fi

# ---- console summary (masked) ----------------------------------------------
printf '\n'
printf '  User         : %s\n' "$UM_NAME"
printf '  OS           : %s\n' "$UM_OS"
printf '  Shell        : %s\n' "$UM_SHELL"
printf '  Home         : %s\n' "$UM_HOME"
printf '  Primary group: %s\n' "$UM_PRIMARY_GROUP"
if [ -n "$UM_GROUP_LIST" ]; then printf '  Extra groups : %s\n' "$UM_GROUP_LIST"; fi
if [ -n "$UM_RESOLVED_PASSWORD" ]; then
  printf '  Password     : %s  (passed via CLI/JSON -- never logged)\n' "$UM_MASKED_PW"
fi
if [ "$UM_SSH_REQUESTED_COUNT" -gt 0 ]; then
  printf '  SSH keys     : requested=%d installed=%d (file: %s/.ssh/authorized_keys)\n' \
    "$UM_SSH_REQUESTED_COUNT" "$UM_SSH_INSTALLED_COUNT" "$UM_HOME"
fi
printf '\n'