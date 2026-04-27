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
. "$SCRIPT_DIR/helpers/_manifest_prune.sh"
# Optional prompt helper -- only sourced if --ask is passed (loaded lazily
# below to keep non-interactive runs free of /dev/tty side-effects).
_UM_PROMPT_SH="$SCRIPT_DIR/helpers/_prompt.sh"

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
  --ask                        prompt interactively for missing fields
                               (username / password / comment / sudo)

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

SSH-key install summary export (v0.182.0):
  --summary-json [TARGET]      Emit a structured JSON document with the
                               SSH-key install counters
                               (sources_requested, keys_parsed,
                               keys_unique, keys_installed_new,
                               keys_preserved) plus context (run-id,
                               user, host, timestamp, authorized_keys
                               path, per-source-type breakdown).
                               TARGET resolution:
                                 (omitted) or "auto"  -> write to
                                   <manifest-dir>/summaries/<run-id>__<user>.summary.json
                                   (mode 0600, dir 0700 root) AND log
                                   the path. Survives reboots; pairs
                                   1:1 with the rollback manifest.
                                 "stdout"             -> append the JSON
                                   to stdout AFTER the human summary,
                                   prefixed by the marker line
                                   '---SSH-SUMMARY-JSON---' so callers
                                   can split parsable JSON from
                                   ANSI-coloured text.
                                 <path>               -> write to that
                                   exact path (mode 0600). Parent dir
                                   must already exist.
                               Failure is non-fatal: the user is still
                               created. CODE-RED: every failure logs
                               the exact path + reason.
  --no-summary-json            Disable summary export even if
                               UM_SUMMARY_JSON is set in the env. Use
                               in batch loaders that already aggregate.
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
UM_ASK="${UM_ASK:-0}"
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
# Auto-prune knob (v0.181.0). Best-effort housekeeping after a successful
# manifest write so the dir self-maintains. Reads policy from config.json
# (manifestRetention.*). Opt-out via --no-auto-prune or UM_NO_AUTO_PRUNE=1.
# Failures during auto-prune NEVER fail the install -- they're warned and
# the operator is told to run `remove-ssh-keys.sh --prune` manually.
UM_NO_AUTO_PRUNE="${UM_NO_AUTO_PRUNE:-0}"
# Summary JSON knobs (v0.182.0). Empty = disabled. Special values:
#   "auto"   = write to <manifest-dir>/summaries/<run-id>__<user>.summary.json
#   "stdout" = append to stdout after the human summary
#   <path>   = write to that exact path
# UM_NO_SUMMARY_JSON forcibly disables (used by batch loader to suppress
# child-level emission when a batch rollup is being assembled).
UM_SUMMARY_JSON="${UM_SUMMARY_JSON:-}"
UM_NO_SUMMARY_JSON="${UM_NO_SUMMARY_JSON:-0}"
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
    --ask)             UM_ASK=1; shift ;;
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
    --no-auto-prune)         UM_NO_AUTO_PRUNE=1; shift ;;
    # --summary-json with OPTIONAL arg. Peek at $2: if it starts with '-'
    # or is unset, treat as "auto" (the default mode). Also accept the
    # explicit --summary-json=... form for unambiguous scripting.
    --summary-json)
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
            UM_SUMMARY_JSON="$2"; shift 2
        else
            UM_SUMMARY_JSON="auto"; shift
        fi
        ;;
    --summary-json=*)        UM_SUMMARY_JSON="${1#--summary-json=}"; shift ;;
    --no-summary-json)       UM_NO_SUMMARY_JSON=1; shift ;;
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

# ---- --ask: interactive prompt for missing required fields ----------------
# Lazy-load the prompt helper only when needed so non-interactive runs don't
# touch /dev/tty. Mirrors the Windows add-user.ps1 --ask flow.
if [ "$UM_ASK" = "1" ]; then
  if [ ! -f "$_UM_PROMPT_SH" ]; then
    log_err "--ask requested but helper not found at exact path: '$_UM_PROMPT_SH' (failure: cannot prompt)"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$_UM_PROMPT_SH"
  [ -z "$UM_NAME" ] && UM_NAME=$(um_prompt_string "Username" "" 1)
  if [ -z "$UM_PASSWORD_CLI" ] && [ -z "$UM_PASSWORD_FILE" ]; then
    UM_PASSWORD_CLI=$(um_prompt_secret "Password (blank = no password set)" 0)
  fi
  if [ -z "$UM_COMMENT" ]; then
    UM_COMMENT=$(um_prompt_string "Comment / GECOS (blank to skip)" "" 0)
  fi
  if [ "$UM_SUDO" = "0" ]; then
    if um_prompt_confirm "Grant sudo (admin) access?" 0; then UM_SUDO=1; fi
  fi
fi

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
    # Materialise the home dir via Apple's createhomedir (preferred:
    # populates ~/Library skeleton, applies ACLs, owner+mode 0755). Falls
    # back to mkdir+chown when createhomedir is absent (CI runners). We
    # always pass the NUMERIC gid so chown can't drift on dscl-vs-getpwnam
    # name resolution. Best effort -- a failure here is logged with the
    # exact path + reason but does not abort the rest of user creation
    # (the operator can still chpasswd / add to groups even without a
    # ready home dir; SSH key install will detect the missing home and
    # warn separately).
    um_seed_macos_home "$UM_NAME" "$UM_HOME" "$pg_gid" || true
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
# SSH key counters (renamed in v0.173.0 so the summary is unambiguous):
#   sources_requested  : how many --ssh-key / --ssh-key-file / --ssh-key-url
#                        flags the operator passed (each file/URL is ONE
#                        source even if it contains many keys).
#   keys_parsed        : total non-blank, non-comment, algo-valid key lines
#                        read from all sources combined (BEFORE intra-run
#                        de-dup -- the same key listed in two files counts
#                        twice here).
#   keys_unique        : keys_parsed after dropping intra-run duplicates.
#                        This is the maximum that COULD land in the file.
#   keys_installed_new : net-new lines actually appended to authorized_keys
#                        (keys_unique minus any already present in the
#                        existing file). This is the "did anything change?"
#                        number.
#   keys_preserved     : pre-existing lines in authorized_keys that we left
#                        untouched. Confirms we didn't clobber anything.
UM_SSH_SOURCES_REQUESTED=$(( ${#UM_SSH_KEYS[@]} + ${#UM_SSH_KEY_FILES[@]} + ${#UM_SSH_KEY_URLS[@]} ))
UM_SSH_KEYS_PARSED=0
UM_SSH_KEYS_UNIQUE=0
UM_SSH_KEYS_INSTALLED_NEW=0
UM_SSH_KEYS_PRESERVED=0

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
        printf '  "scriptVersion": "0.173.0",\n'
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

# --- ssh-key install summary writer (added v0.182.0) ----------------------
#
# Emits a structured JSON document with the SSH-key install counters
# plus context. Schema is stable and versioned (`summaryVersion: 1`):
#
#   {
#     "summaryVersion": 1,
#     "writtenAt":  "<UTC ISO-8601>",
#     "host":       "<hostname>",
#     "user":       "<unix user>",
#     "runId":      "<rollback run-id>",
#     "scriptVersion": "<add-user.sh version>",
#     "authorizedKeysFile": "<path>",
#     "summary": {
#       "sources_requested":  <n>,
#       "keys_parsed":        <n>,
#       "keys_unique":        <n>,
#       "keys_installed_new": <n>,
#       "keys_preserved":     <n>
#     },
#     "sources": {
#       "inline":  <n>,    -- count of --ssh-key flags
#       "file":    <n>,    -- count of --ssh-key-file flags
#       "url":     <n>     -- count of --ssh-key-url flags
#     },
#     "manifestFile": "<path or null>",
#     "ok": true
#   }
#
# Failure NEVER fails the install -- the user has already been created.
# CODE RED: every write failure logs the exact path + the precise reason
# (mkdir denied / mode denied / parent missing / disk full / etc).
#
# _um_write_summary_json <user> <auth_keys_path> <target>
#   target = "stdout"  -> write to stdout, prefixed by the marker line
#                         '---SSH-SUMMARY-JSON---' (a downstream parser
#                         splits on that marker; nothing else in our
#                         output ever uses it).
#   target = "auto"    -> write to <UM_MANIFEST_DIR>/summaries/
#                         <run-id>__<user>.summary.json (mode 0600,
#                         dir 0700 root). Pairs 1:1 with the manifest.
#   target = <path>    -> write to that path (mode 0600). Parent dir
#                         must exist.
_um_write_summary_json() {
    local user="$1" auth_path="$2" target="$3"
    [ -z "$target" ] && return 0
    [ "$UM_NO_SUMMARY_JSON" = "1" ] && return 0

    local host
    host=$(hostname 2>/dev/null || echo unknown)
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
    local script_version
    script_version=$(jq -r '.version // "unknown"' \
                        "$SCRIPT_DIR/../../scripts/version.json" 2>/dev/null \
                        || echo unknown)

    # Per-source-type breakdown -- mirrors the CLI flag counts. The
    # aggregate sources_requested is just the sum.
    local n_inline=${#UM_SSH_KEYS[@]}
    local n_file=${#UM_SSH_KEY_FILES[@]}
    local n_url=${#UM_SSH_KEY_URLS[@]}

    # Manifest path (if a manifest was written this run; null otherwise).
    local manifest_path="null"
    if [ "$UM_NO_MANIFEST" != "1" ] && [ -n "${UM_RUN_ID:-}" ]; then
        manifest_path="\"$(printf '%s' "$UM_MANIFEST_DIR/${UM_RUN_ID}__${user}.json" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\""
    fi

    # Build the JSON body in a tmp buffer so writes are atomic. We use
    # printf with %s + manual escaping for the few free-text fields --
    # everything else is numeric or comes from a controlled set.
    local _esc_user _esc_auth _esc_run _esc_host
    _esc_user=$(printf '%s' "$user"            | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    _esc_auth=$(printf '%s' "$auth_path"       | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    _esc_run=$( printf '%s' "${UM_RUN_ID:-}"   | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    _esc_host=$(printf '%s' "$host"            | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

    local body
    body=$(cat <<EOF
{
  "summaryVersion": 1,
  "writtenAt": "$now",
  "host": "$_esc_host",
  "user": "$_esc_user",
  "runId": "$_esc_run",
  "scriptVersion": "$script_version",
  "authorizedKeysFile": "$_esc_auth",
  "summary": {
    "sources_requested":  $UM_SSH_SOURCES_REQUESTED,
    "keys_parsed":        $UM_SSH_KEYS_PARSED,
    "keys_unique":        $UM_SSH_KEYS_UNIQUE,
    "keys_installed_new": $UM_SSH_KEYS_INSTALLED_NEW,
    "keys_preserved":     $UM_SSH_KEYS_PRESERVED
  },
  "sources": {
    "inline": $n_inline,
    "file":   $n_file,
    "url":    $n_url
  },
  "manifestFile": $manifest_path,
  "ok": true
}
EOF
)

    case "$target" in
        stdout)
            # Marker line lets a wrapper script split parseable JSON from
            # the human (potentially ANSI-coloured) summary above. The
            # marker text is fixed and never appears in our log output.
            printf '\n---SSH-SUMMARY-JSON---\n%s\n' "$body"
            log_ok "$(um_msg summaryJsonWritten "<stdout>" "${UM_RUN_ID:-}" "$user" "stdout")"
            return 0
            ;;
        auto)
            # Default location: <manifest-dir>/summaries/<run-id>__<user>.summary.json
            # Mirrors the manifest layout so rollback + summary stay
            # paired. If the operator passed --no-manifest there's no
            # run-id we can sensibly key on -- emit to stdout instead so
            # the data isn't lost.
            if [ "$UM_NO_MANIFEST" = "1" ] || [ -z "${UM_RUN_ID:-}" ]; then
                log_warn "[68][summary-json] no manifest run-id available (--no-manifest set?) -- falling back to stdout"
                printf '\n---SSH-SUMMARY-JSON---\n%s\n' "$body"
                return 0
            fi
            local sdir="$UM_MANIFEST_DIR/summaries"
            local spath="$sdir/${UM_RUN_ID}__${user}.summary.json"
            if ! mkdir -p "$sdir" 2>/dev/null; then
                log_file_error "$sdir" "$(um_msg summaryJsonWriteFail "$sdir" "mkdir failed (need root or check $UM_MANIFEST_DIR ownership)" | sed 's/^[[:alpha:]]*: //')"
                return 0
            fi
            chmod 0700 "$sdir" 2>/dev/null || true
            local tmp_json
            tmp_json=$(mktemp -t 68-summary.XXXXXX) || {
                log_file_error "$spath" "$(um_msg summaryJsonWriteFail "$spath" "mktemp failed" | sed 's/^[[:alpha:]]*: //')"
                return 0
            }
            if ! printf '%s\n' "$body" > "$tmp_json" 2>/dev/null; then
                rm -f "$tmp_json"
                log_file_error "$tmp_json" "$(um_msg summaryJsonWriteFail "$tmp_json" "tmp write failed (disk full? /tmp permissions?)" | sed 's/^[[:alpha:]]*: //')"
                return 0
            fi
            if ! mv "$tmp_json" "$spath" 2>/dev/null; then
                rm -f "$tmp_json"
                log_file_error "$spath" "$(um_msg summaryJsonWriteFail "$spath" "mv from tmp failed" | sed 's/^[[:alpha:]]*: //')"
                return 0
            fi
            chmod 0600 "$spath" 2>/dev/null || true
            log_ok "$(um_msg summaryJsonWritten "$spath" "${UM_RUN_ID:-}" "$user" "auto")"
            return 0
            ;;
        *)
            # Explicit path. Parent dir must exist; we don't auto-create
            # arbitrary paths because they may live under user dirs the
            # operator does NOT want us to mkdir into with mode 0700.
            local spath="$target"
            local sparent
            sparent=$(dirname "$spath")
            if [ ! -d "$sparent" ]; then
                log_file_error "$sparent" "$(um_msg summaryJsonWriteFail "$spath" "parent dir does not exist (create it first or use --summary-json=auto)" | sed 's/^[[:alpha:]]*: //')"
                return 0
            fi
            local tmp_json
            tmp_json=$(mktemp -t 68-summary.XXXXXX) || {
                log_file_error "$spath" "$(um_msg summaryJsonWriteFail "$spath" "mktemp failed" | sed 's/^[[:alpha:]]*: //')"
                return 0
            }
            if ! printf '%s\n' "$body" > "$tmp_json" 2>/dev/null; then
                rm -f "$tmp_json"
                log_file_error "$tmp_json" "$(um_msg summaryJsonWriteFail "$spath" "tmp write failed" | sed 's/^[[:alpha:]]*: //')"
                return 0
            fi
            if ! mv "$tmp_json" "$spath" 2>/dev/null; then
                rm -f "$tmp_json"
                log_file_error "$spath" "$(um_msg summaryJsonWriteFail "$spath" "mv from tmp failed (target unwritable?)" | sed 's/^[[:alpha:]]*: //')"
                return 0
            fi
            chmod 0600 "$spath" 2>/dev/null || true
            log_ok "$(um_msg summaryJsonWritten "$spath" "${UM_RUN_ID:-}" "$user" "explicit-path")"
            return 0
            ;;
    esac
}

if [ "$UM_SSH_SOURCES_REQUESTED" -gt 0 ]; then

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

  # Count parsed keys BEFORE dedup so the summary distinguishes
  # "same key listed twice" from "you only gave me one source".
  UM_SSH_KEYS_PARSED=$(printf '%s\n' "$_ssh_buf" | awk 'NF' | wc -l | tr -d ' ')

  # De-duplicate while preserving order. Awk on the buffer.
  _ssh_buf=$(printf '%s\n' "$_ssh_buf" | awk 'NF && !seen[$0]++')
  UM_SSH_KEYS_UNIQUE=$(printf '%s\n' "$_ssh_buf" | awk 'NF' | wc -l | tr -d ' ')

  if [ "$UM_SSH_KEYS_UNIQUE" -eq 0 ]; then
    log_warn "$(um_msg sshKeyNoneValid "$UM_SSH_SOURCES_REQUESTED")"
  else
    _ssh_dir="$UM_HOME/.ssh"
    _ssh_file="$_ssh_dir/authorized_keys"

    if [ "$UM_DRY_RUN" = "1" ]; then
      log_info "[dry-run] would install $UM_SSH_KEYS_UNIQUE unique ssh key(s) to $_ssh_file (mode 0600, dir 0700, owner $UM_NAME)"
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
      # Dry-run: assume EVERY unique key would be net-new (we can't read
      # the real authorized_keys without committing to the install). The
      # operator will see the actual installed_new count on a real run.
      UM_SSH_KEYS_INSTALLED_NEW="$UM_SSH_KEYS_UNIQUE"
      UM_SSH_KEYS_PRESERVED=0
    else
      if [ ! -d "$UM_HOME" ]; then
        log_warn "$(um_msg sshHomeMissing "$UM_HOME" "$UM_NAME")"
      else
        # Resolve the target's NUMERIC primary GID once, up-front. We use
        # numbers (not names) for chown so a macOS dscl-vs-getpwnam name
        # drift can't break the install. _pg_gid is allowed to be empty
        # (e.g. on a host where `id -g` lags after dscl create); we fall
        # back to the group NAME we already have in $UM_PRIMARY_GROUP and
        # log a warning so the operator can audit.
        _pg_gid=$(um_resolve_pg_gid "$UM_NAME")
        if [ -z "$_pg_gid" ]; then
          log_warn "$(um_msg macPgGidMissing "$UM_NAME" "$UM_PRIMARY_GROUP")"
          _chown_target="$UM_NAME:$UM_PRIMARY_GROUP"
        else
          _chown_target="$UM_NAME:$_pg_gid"
        fi

        # mkdir -p is idempotent; we always re-assert mode + owner so a
        # half-baked previous run can't leave 0755 perms behind.
        if ! mkdir -p "$_ssh_dir" 2>/dev/null; then
          log_file_error "$_ssh_dir" "could not create .ssh dir"
        else
          chmod 0700 "$_ssh_dir" 2>/dev/null \
            || log_file_error "$_ssh_dir" "could not chmod 0700"
          # Chown the .ssh DIR itself before we write the file so an
          # interrupted run can't leave a root-owned dir blocking the
          # user's later sshd access.
          chown "$_chown_target" "$_ssh_dir" 2>/dev/null \
            || log_warn "$(um_msg sshOwnerWarn "$_ssh_dir" "$_chown_target")"

          # Merge: append only NEW keys (not already present in the file).
          existing=""
          [ -f "$_ssh_file" ] && existing=$(cat "$_ssh_file" 2>/dev/null)
          merged=$(printf '%s\n%s\n' "$existing" "$_ssh_buf" | awk 'NF && !seen[$0]++')
          if ! printf '%s\n' "$merged" > "$_ssh_file" 2>/dev/null; then
            log_file_error "$_ssh_file" "could not write authorized_keys"
          else
            chmod 0600 "$_ssh_file" 2>/dev/null \
              || log_file_error "$_ssh_file" "could not chmod 0600"
            if chown "$_chown_target" "$_ssh_file" 2>/dev/null; then
              # Numeric-gid chown succeeded: log it explicitly so the
              # operator (esp. on macOS) sees that the safe path was
              # used. On Linux this looks identical to the old behaviour.
              log_info "$(um_msg sshChownNumeric "$_ssh_file" "$UM_NAME" "${_pg_gid:-$UM_PRIMARY_GROUP}")"
            else
              log_warn "$(um_msg sshOwnerWarn "$_ssh_file" "$_chown_target")"
            fi

            # Count net-new lines added this run. before_n = preserved
            # pre-existing keys; (after_n - before_n) = net-new appended.
            before_n=$(printf '%s\n' "$existing" | awk 'NF' | wc -l | tr -d ' ')
            after_n=$(printf '%s\n' "$merged"   | awk 'NF' | wc -l | tr -d ' ')
            UM_SSH_KEYS_PRESERVED="$before_n"
            UM_SSH_KEYS_INSTALLED_NEW=$(( after_n - before_n ))
            log_ok "$(um_msg sshKeyInstalled "$_ssh_file" \
                "$UM_SSH_SOURCES_REQUESTED" \
                "$UM_SSH_KEYS_PARSED" \
                "$UM_SSH_KEYS_UNIQUE" \
                "$UM_SSH_KEYS_INSTALLED_NEW" \
                "$UM_SSH_KEYS_PRESERVED")"

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
            _um_write_manifest "$UM_NAME" "$_ssh_file" "$_new_only" "$UM_SSH_KEYS_INSTALLED_NEW"

            # v0.181.0: opportunistic prune so the manifest dir self-maintains.
            # Best-effort: a failure here MUST NOT fail the install. Policy
            # comes from config.json (manifestRetention.*) -- if the file
            # is missing or unreadable, we fall through to the documented
            # built-in defaults (90 days / keep-last 20 / max 500). The
            # operator can disable this entirely with --no-auto-prune.
            if [ "$UM_NO_AUTO_PRUNE" != "1" ] && [ "$UM_DRY_RUN" != "1" ]; then
              _ap_cfg="$SCRIPT_DIR/config.json"
              _ap_enabled=1
              _ap_older=90; _ap_keep=20; _ap_max=500
              if [ -r "$_ap_cfg" ] && command -v jq >/dev/null 2>&1; then
                _ap_enabled=$(jq -r '.manifestRetention.autoPruneOnInstall // true | if . then 1 else 0 end' "$_ap_cfg" 2>/dev/null) || _ap_enabled=1
                _ap_older=$( jq -r '.manifestRetention.olderThanDays   // 90'  "$_ap_cfg" 2>/dev/null) || _ap_older=90
                _ap_keep=$(  jq -r '.manifestRetention.keepLastPerUser // 20'  "$_ap_cfg" 2>/dev/null) || _ap_keep=20
                _ap_max=$(   jq -r '.manifestRetention.maxTotal        // 500' "$_ap_cfg" 2>/dev/null) || _ap_max=500
              fi
              if [ "$_ap_enabled" = "1" ]; then
                UM_PRUNE_DIR="$UM_MANIFEST_DIR" \
                UM_PRUNE_OLDER_THAN_DAYS="$_ap_older" \
                UM_PRUNE_KEEP_LAST="$_ap_keep" \
                UM_PRUNE_MAX_TOTAL="$_ap_max" \
                UM_PRUNE_DRY_RUN=0 \
                UM_PRUNE_QUIET=1 \
                  um_manifest_prune || \
                    log_warn "$(um_msg manifestAutoPruneFail "rc=$?")"
              fi
            fi
          fi
        fi
      fi
    fi
    um_summary_add "ok" "ssh-key" "$UM_NAME" \
      "sources=$UM_SSH_SOURCES_REQUESTED parsed=$UM_SSH_KEYS_PARSED unique=$UM_SSH_KEYS_UNIQUE new=$UM_SSH_KEYS_INSTALLED_NEW preserved=$UM_SSH_KEYS_PRESERVED"

    # v0.182.0 -- emit structured install summary JSON if requested.
    # _ssh_file is set inside the install pass above; fall back to the
    # canonical authorized_keys path if it isn't (defensive -- never
    # block the summary on a missing local var).
    if [ -n "$UM_SUMMARY_JSON" ] && [ "$UM_NO_SUMMARY_JSON" != "1" ]; then
        _um_write_summary_json "$UM_NAME" \
            "${_ssh_file:-$UM_HOME/.ssh/authorized_keys}" \
            "$UM_SUMMARY_JSON"
    fi
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
if [ "$UM_SSH_SOURCES_REQUESTED" -gt 0 ]; then
  # Pipeline-style summary so the operator can read left-to-right what
  # happened to each --ssh-key / --ssh-key-file / --ssh-key-url they
  # passed. "preserved" counts pre-existing keys we did NOT touch.
  printf '  SSH keys     : sources=%d parsed=%d unique=%d installed_new=%d preserved=%d\n' \
    "$UM_SSH_SOURCES_REQUESTED" "$UM_SSH_KEYS_PARSED" "$UM_SSH_KEYS_UNIQUE" \
    "$UM_SSH_KEYS_INSTALLED_NEW" "$UM_SSH_KEYS_PRESERVED"
  printf '                 (file: %s/.ssh/authorized_keys)\n' "$UM_HOME"
fi
printf '\n'