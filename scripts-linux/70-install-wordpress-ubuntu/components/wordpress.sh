#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/wordpress.sh
# Downloads latest WordPress, extracts to WP_INSTALL_PATH, creates the
# database + user, writes wp-config.php with secure salts.
set -u

_wp_genpass() {
    # 24-char password from /dev/urandom; alnum only (no shell-special chars).
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

# _wp_verify_download <local_file> <source_url>
# Integrity gate for the WordPress archive (ZIP or tar.gz). WordPress.org
# publishes <url>.sha1 and <url>.md5 (NO official sha256 -- confirmed via
# 404 on .sha256). We:
#   1. Always compute + log the local SHA256 of the file (audit trail; the
#      operator can pin this in a downstream policy if they want).
#   2. Fetch the official .sha1 and require an exact match. This is the
#      primary integrity gate -- it catches a corrupted download, a MITM
#      that replaced the body, or a partial transfer.
#   3. Fetch the official .md5 and require an exact match. Redundant, but
#      catches the (extremely unlikely) case where SHA1 was forged but
#      MD5 was forgotten -- and it's free to compute.
#   4. Strict by default: if either checksum file is unreachable, abort
#      the install. Set WP_SKIP_CHECKSUM=1 to fall back to a warning when
#      the operator is on a network where the checksum URLs are blocked
#      but the archive itself is mirrored (rare).
# Returns 0 only when SHA1 + MD5 both match. Logs every failure with
# log_file_error path='...' reason='...' (CODE RED).
_wp_verify_download() {
    local file="$1" url="$2"
    local skip="${WP_SKIP_CHECKSUM:-0}"

    if [ ! -s "$file" ]; then
        log_file_error "$file" "downloaded archive is missing or empty -- nothing to checksum"
        return 1
    fi

    if ! command -v sha1sum >/dev/null 2>&1; then
        log_warn "[70][wp][checksum] sha1sum not on PATH -- skipping integrity check"
        return 0
    fi

    # 1. Local SHA256 audit hash
    local sha256_local
    if command -v sha256sum >/dev/null 2>&1; then
        sha256_local="$(sha256sum "$file" | awk '{print $1}')"
        log_info "[70][wp][checksum] sha256(local) = $sha256_local  ($file)"
    fi

    # 2. SHA1 -- official wordpress.org checksum
    local sha1_local sha1_remote
    sha1_local="$(sha1sum "$file" | awk '{print $1}')"
    sha1_remote="$(curl -fsSL "${url}.sha1" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$sha1_remote" ]; then
        if [ "$skip" = "1" ]; then
            log_warn "[70][wp][checksum] could not fetch ${url}.sha1 -- WP_SKIP_CHECKSUM=1, continuing without integrity check"
        else
            log_file_error "${url}.sha1" "could not fetch official SHA1 checksum (set WP_SKIP_CHECKSUM=1 to override at your own risk)"
            return 1
        fi
    elif [ "$sha1_local" != "$sha1_remote" ]; then
        log_file_error "$file" "SHA1 mismatch -- expected '$sha1_remote' (from ${url}.sha1) but got '$sha1_local' -- download is corrupted or tampered with"
        return 1
    else
        log_ok "[70][wp][checksum] sha1 match: $sha1_local"
    fi

    # 3. MD5 -- redundant secondary check
    if command -v md5sum >/dev/null 2>&1; then
        local md5_local md5_remote
        md5_local="$(md5sum "$file" | awk '{print $1}')"
        md5_remote="$(curl -fsSL "${url}.md5" 2>/dev/null | tr -d '[:space:]')"
        if [ -z "$md5_remote" ]; then
            if [ "$skip" = "1" ]; then
                log_warn "[70][wp][checksum] could not fetch ${url}.md5 -- WP_SKIP_CHECKSUM=1, continuing"
            else
                log_file_error "${url}.md5" "could not fetch official MD5 checksum (set WP_SKIP_CHECKSUM=1 to override)"
                return 1
            fi
        elif [ "$md5_local" != "$md5_remote" ]; then
            log_file_error "$file" "MD5 mismatch -- expected '$md5_remote' (from ${url}.md5) but got '$md5_local' -- download is corrupted or tampered with"
            return 1
        else
            log_ok "[70][wp][checksum] md5  match: $md5_local"
        fi
    fi

    return 0
}

component_wordpress_verify() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    [ -f "$install_path/wp-config.php" ] || return 1
    [ -f "$install_path/index.php" ]      || return 1
    return 0
}

# component_wordpress_verify_config <install_path> <db_name> <db_user> <db_pass> <db_host> <db_port>
# Strict post-generation validator for wp-config.php. Confirms:
#   1. File exists, is non-empty, has the closing PHP marker.
#   2. PHP syntax is valid (php -l), if php is on PATH.
#   3. DB_NAME / DB_USER / DB_PASSWORD / DB_HOST table_prefix lines all
#      contain the values we just installed -- no leftover '*_here' or
#      'localhost' (when a custom port was set).
#   4. All 8 secret keys (AUTH_KEY, SECURE_AUTH_KEY, LOGGED_IN_KEY,
#      NONCE_KEY, AUTH_SALT, SECURE_AUTH_SALT, LOGGED_IN_SALT,
#      NONCE_SALT) are defined exactly once.
#   5. None of the 8 secrets equal the WordPress-shipped placeholder
#      ("put your unique phrase here") -- catches the case where the
#      api.wordpress.org fetch silently failed and we kept defaults.
#   6. The 8 secret values are mutually unique (no duplicates -- the
#      official salt API always returns 8 distinct 64-char strings, so
#      duplicates indicate a malformed fetch or sed mishap).
# Logs every failure with the exact file path + reason via log_file_error
# (CODE RED rule). Returns 0 only when ALL checks pass.
component_wordpress_verify_config() {
    local install_path="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="$5"
    local db_port="$6"
    local cfg="$install_path/wp-config.php"
    local rc=0

    log_info "[70][wp][verify-config] validating $cfg"

    # 1. File presence + non-empty + closing tag/marker
    if [ ! -f "$cfg" ]; then
        log_file_error "$cfg" "wp-config.php not found after generation step"
        return 1
    fi
    if [ ! -s "$cfg" ]; then
        log_file_error "$cfg" "wp-config.php is empty (0 bytes)"
        return 1
    fi
    # WordPress wp-config.php ends with: /* That's all, stop editing! Happy publishing. */
    if ! sudo grep -q "stop editing" "$cfg"; then
        log_file_error "$cfg" "wp-config.php missing 'stop editing' end marker -- file may be truncated"
        rc=1
    fi

    # 2. PHP syntax check (only if php is available -- it should be after prereqs)
    if command -v php >/dev/null 2>&1; then
        local lint_out
        lint_out="$(sudo php -l "$cfg" 2>&1)"
        if ! echo "$lint_out" | grep -q "No syntax errors"; then
            log_file_error "$cfg" "PHP syntax check failed: $lint_out"
            rc=1
        fi
    else
        log_warn "[70][wp][verify-config] php not on PATH -- skipping syntax lint"
    fi

    # 3. DB credentials present
    # Use sudo grep because wp-config.php is chmod 640 owned by www-data.
    local cfg_dump; cfg_dump="$(sudo cat "$cfg")"

    _wp_check_define() {
        local const="$1" expected="$2"
        # Match: define( 'CONST', 'value' );  or  define('CONST','value');
        local line
        line="$(printf '%s\n' "$cfg_dump" | grep -E "define\(\s*['\"]${const}['\"]" | head -1)"
        if [ -z "$line" ]; then
            log_file_error "$cfg" "missing define('${const}', ...) line"
            return 1
        fi
        # Extract the second quoted argument (single OR double quotes).
        local val
        val="$(printf '%s\n' "$line" | sed -E "s/.*define\(\s*['\"]${const}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/")"
        if [ "$val" != "$expected" ]; then
            log_file_error "$cfg" "define('${const}') = '${val}' but expected '${expected}'"
            return 1
        fi
        return 0
    }

    _wp_check_define "DB_NAME"     "$db_name"            || rc=1
    _wp_check_define "DB_USER"     "$db_user"            || rc=1
    _wp_check_define "DB_PASSWORD" "$db_pass"            || rc=1
    _wp_check_define "DB_HOST"     "${db_host}:${db_port}" || rc=1

    # Catch any leftover placeholders from wp-config-sample.php
    if printf '%s\n' "$cfg_dump" | grep -qE 'database_name_here|username_here|password_here'; then
        log_file_error "$cfg" "wp-config.php still contains *_here placeholder(s) -- sed replacement did not run"
        rc=1
    fi

    # 4. + 5. + 6. Secret keys / salts
    local keys=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" \
                "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    local placeholder="put your unique phrase here"
    local salt_values=()
    local k
    for k in "${keys[@]}"; do
        local count
        count="$(printf '%s\n' "$cfg_dump" | grep -cE "define\(\s*['\"]${k}['\"]")"
        if [ "$count" -eq 0 ]; then
            log_file_error "$cfg" "salt define('${k}') is missing"
            rc=1
            continue
        fi
        if [ "$count" -gt 1 ]; then
            log_file_error "$cfg" "salt define('${k}') is defined ${count} times (must be exactly 1) -- awk strip likely failed"
            rc=1
        fi
        local sval
        sval="$(printf '%s\n' "$cfg_dump" | grep -E "define\(\s*['\"]${k}['\"]" | head -1 \
                | sed -E "s/.*define\(\s*['\"]${k}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/")"
        if [ -z "$sval" ]; then
            log_file_error "$cfg" "salt ${k} has empty value"
            rc=1
        elif [ "$sval" = "$placeholder" ]; then
            log_file_error "$cfg" "salt ${k} still equals shipped placeholder '${placeholder}' -- api.wordpress.org fetch failed and was not noticed"
            rc=1
        elif [ "${#sval}" -lt 32 ]; then
            log_file_error "$cfg" "salt ${k} value is only ${#sval} chars (expected >= 32 from api.wordpress.org)"
            rc=1
        fi
        salt_values+=("$sval")
    done

    # Mutual uniqueness check (8 distinct values)
    if [ "${#salt_values[@]}" -eq 8 ]; then
        local uniq_count
        uniq_count="$(printf '%s\n' "${salt_values[@]}" | sort -u | wc -l)"
        if [ "$uniq_count" -ne 8 ]; then
            log_file_error "$cfg" "salt values are not mutually unique (${uniq_count}/8 distinct) -- duplicate salt = weakened security"
            rc=1
        fi
    fi

    if [ "$rc" -eq 0 ]; then
        log_ok "[70][wp][verify-config] OK -- DB creds match, 8 unique salts present, syntax clean"
    else
        log_err "[70][wp][verify-config] FAILED -- see [70][wp][verify-config] errors above"
    fi
    return "$rc"
}

_wp_mysql_run() {
    # Run a SQL command as root via socket auth (default on Ubuntu MySQL 8).
    local sql="$1"
    sudo mysql -uroot -e "$sql" 2>&1
}

# _wp_write_config <install_path> <db_name> <db_user> <db_pass> <db_host> <db_port> [<keep_salts:0|1>]
# Generates wp-config.php from wp-config-sample.php with the supplied DB
# credentials and either fresh or preserved salts. Single source of truth
# used by BOTH the initial install and the reconfigure path so the two
# can never diverge.
#
# keep_salts=0 (default): fetches a fresh salt set from
#   api.wordpress.org/secret-key/1.1/salt/ and replaces the entire SALT
#   block. Use this on a fresh install or when rotating salts.
# keep_salts=1: preserves the existing 8 salt define() lines from a
#   pre-existing wp-config.php. Use this in reconfigure mode when only
#   DB credentials change -- avoids invalidating active user sessions
#   and password reset cookies.
#
# Always runs the strict component_wordpress_verify_config gate at the
# end so a broken file never lands. Returns 0 only on full success.
_wp_write_config() {
    local install_path="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="$5"
    local db_port="$6"
    local keep_salts="${7:-0}"

    local cfg="$install_path/wp-config.php"
    local sample="$install_path/wp-config-sample.php"

    if [ ! -f "$sample" ]; then
        log_file_error "$sample" "wp-config-sample.php missing -- WordPress files were not extracted (run 'install wp' first)"
        return 1
    fi

    # Capture existing salt block BEFORE we overwrite the file (only if asked).
    local preserved_salts=""
    if [ "$keep_salts" = "1" ]; then
        if [ -f "$cfg" ]; then
            preserved_salts="$(sudo grep -E "define\(\s*['\"]?(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)['\"]?" "$cfg" 2>/dev/null || true)"
            local preserved_count
            preserved_count="$(printf '%s\n' "$preserved_salts" | grep -c "define(" || true)"
            if [ "$preserved_count" -lt 8 ]; then
                log_warn "[70][wp][reconfigure] --keep-salts requested but found only $preserved_count/8 salt lines -- will fetch fresh set instead"
                preserved_salts=""
            else
                log_info "[70][wp][reconfigure] preserving 8 existing salts from current wp-config.php"
            fi
        else
            log_warn "[70][wp][reconfigure] --keep-salts requested but $cfg does not exist yet -- will fetch fresh salts"
        fi
    fi

    log_info "[70][wp] writing $cfg (keep_salts=$keep_salts)"
    if ! sudo cp "$sample" "$cfg"; then
        log_file_error "$cfg" "cp from wp-config-sample.php failed"
        return 1
    fi
    if ! sudo sed -i \
            -e "s/database_name_here/${db_name}/" \
            -e "s/username_here/${db_user}/" \
            -e "s|password_here|${db_pass}|" \
            -e "s/localhost/${db_host}:${db_port}/" \
            "$cfg"; then
        log_file_error "$cfg" "sed replacement failed for DB credentials"
        return 1
    fi

    # Resolve the salt block: preserved -> reuse; else fetch fresh.
    local salts="$preserved_salts"
    if [ -z "$salts" ]; then
        salts="$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || echo '')"
    fi

    if [ -n "$salts" ]; then
        local tmp; tmp="$(mktemp)"
        # NOTE: WordPress ships wp-config-sample.php with CRLF line endings,
        # which makes the `;$` end-of-line anchor below fail to match the
        # placeholder salt lines (the trailing \r sits between ; and \n).
        # Normalise to LF first so the awk strip works for BOTH the initial
        # install (CRLF source) and reconfigure-on-existing (LF after first
        # write). Without this, salts pile up on every reconfigure call.
        sudo sed -i 's/\r$//' "$cfg"
        # shellcheck disable=SC2024 # tmp is operator-owned (mktemp); no sudo redirect needed
        sudo awk '!/define\(.*(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT).*\);$/' \
            "$cfg" > "$tmp"
        printf '\n%s\n' "$salts" >> "$tmp"
        if ! sudo mv "$tmp" "$cfg"; then
            log_file_error "$cfg" "mv of salted wp-config.php failed (source: $tmp)"
            return 1
        fi
        sudo chown www-data:www-data "$cfg" || true
        sudo chmod 640 "$cfg" || true
        if [ -n "$preserved_salts" ]; then
            log_ok "[70][wp] wp-config.php written with preserved salts (sessions remain valid)"
        else
            log_ok "[70][wp] wp-config.php written with fresh API salts"
        fi
    else
        log_warn "[70][wp] could not fetch fresh salts from api.wordpress.org -- wp-config.php contains the placeholder salts; rotate them manually"
    fi

    if ! component_wordpress_verify_config \
            "$install_path" "$db_name" "$db_user" "$db_pass" "$db_host" "$db_port"; then
        log_err "[70][wp] wp-config.php verification failed -- file is broken (see errors above)"
        return 1
    fi
    return 0
}

# _wp_save_credentials_record <install_path> <db_engine> <db_host> <db_port> <db_name> <db_user> <db_pass>
# Writes the chmod-600 credentials record used by `show-credentials` and
# operator recovery. Single source of truth so install + reconfigure both
# emit the exact same JSON layout.
_wp_save_credentials_record() {
    local install_path="$1" db_engine="$2" db_host="$3" db_port="$4"
    local db_name="$5" db_user="$6" db_pass="$7"
    local rec_dir="$ROOT/.installed"
    local rec="$rec_dir/70-wordpress-credentials.json"
    if ! mkdir -p "$rec_dir"; then
        log_file_error "$rec_dir" "mkdir -p failed for credentials record dir"
        return 1
    fi
    cat > "$rec" <<EOF
{
  "install_path": "$install_path",
  "site_url": "http://${WP_SERVER_NAME:-localhost}:${WP_SITE_PORT:-80}/",
  "db_engine": "$db_engine",
  "db_host": "$db_host",
  "db_port": $db_port,
  "db_name": "$db_name",
  "db_user": "$db_user",
  "db_pass": "$db_pass",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$rec" 2>/dev/null || true
    log_info "[70][wp] credentials saved -> $rec (chmod 600)"
    return 0
}

# component_wordpress_reconfigure
# Re-runs ONLY the wp-config.php generation step (and the matching DB
# grant) using current WP_DB_NAME / WP_DB_USER / WP_DB_PASS / WP_MYSQL_PORT
# / WP_INSTALL_PATH values. WordPress files themselves are NOT touched --
# no download, no extract, no chown of the docroot. Use this when:
#   - You rotated the DB password and need wp-config.php to reflect it.
#   - You changed the MySQL port and the cached host:port in wp-config.php
#     is stale.
#   - You renamed the DB user or DB itself.
#   - You want to rotate salts independently (omit --keep-salts).
#
# Safety:
#   - Refuses to run if $install_path/wp-config-sample.php is missing
#     (means WordPress files aren't extracted -- use 'install wp' instead).
#   - Backs up the existing wp-config.php to wp-config.php.bak.<UTC-ts>
#     before overwriting, so a manual rollback is one `mv` away.
#   - Honours WP_KEEP_SALTS=1 (set by --keep-salts) to preserve existing
#     salts and avoid logging users out.
#   - Runs the same strict verify_config gate as install (DB creds match,
#     8 unique salts, no placeholders, php -l clean).
#   - Updates .installed/70-wordpress-credentials.json so show-credentials
#     reflects the new state.
component_wordpress_reconfigure() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local db_name="${WP_DB_NAME:-wordpress}"
    local db_user="${WP_DB_USER:-wp_user}"
    local db_pass="${WP_DB_PASS:-}"
    local db_host="127.0.0.1"
    local db_port="${WP_MYSQL_PORT:-3306}"
    local keep_salts="${WP_KEEP_SALTS:-0}"

    log_info "[70][wp][reconfigure] starting (path=$install_path db=$db_name user=$db_user keep_salts=$keep_salts)"

    # Refuse if WordPress files are not present.
    if [ ! -d "$install_path" ]; then
        log_file_error "$install_path" "install path does not exist -- run 'install wp' first to extract WordPress files"
        return 1
    fi
    if [ ! -f "$install_path/wp-config-sample.php" ]; then
        log_file_error "$install_path/wp-config-sample.php" "wp-config-sample.php missing -- WordPress files are not extracted; run 'install wp' first"
        return 1
    fi

    if [ -z "$db_pass" ]; then
        db_pass="$(_wp_genpass)"
        log_info "[70][wp][reconfigure] auto-generated DB password (24 chars) -- pass --db-pass to use a specific value"
    fi

    # Backup current wp-config.php before overwrite.
    local cfg="$install_path/wp-config.php"
    if [ -f "$cfg" ]; then
        local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
        local bak="$cfg.bak.$ts"
        if sudo cp -p "$cfg" "$bak"; then
            log_ok "[70][wp][reconfigure] backed up existing wp-config.php -> $bak"
        else
            log_file_error "$bak" "cp backup failed -- aborting reconfigure to avoid losing original (source: $cfg)"
            return 1
        fi
    else
        log_warn "[70][wp][reconfigure] no existing wp-config.php at $cfg -- writing fresh"
    fi

    # Apply DB grant so the new (user, password, db) actually works in MySQL.
    # Mirrors step 2 of component_wordpress_install but is idempotent here
    # because CREATE DATABASE / CREATE USER both use IF NOT EXISTS and ALTER
    # USER unconditionally rotates the password.
    if command -v mysql >/dev/null 2>&1; then
        log_info "[70][wp][reconfigure] applying MySQL grant for '$db_user'@'localhost' on '$db_name'"
        local grant_sql="
          CREATE DATABASE IF NOT EXISTS \`${db_name}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
          CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
          ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
          GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
          FLUSH PRIVILEGES;"
        local sql_out sql_rc
        sql_out="$(_wp_mysql_run "$grant_sql")"
        sql_rc=$?
        if [ "$sql_rc" -ne 0 ] || echo "$sql_out" | grep -qiE 'ERROR'; then
            log_warn "[70][wp][reconfigure] MySQL grant failed (rc=${sql_rc}): ${sql_out} -- wp-config.php will still be updated, but the site won't connect until the DB user is fixed manually"
        else
            log_ok "[70][wp][reconfigure] MySQL grant applied"
        fi
    else
        log_warn "[70][wp][reconfigure] mysql client not on PATH -- skipped DB grant; wp-config.php will be updated only"
    fi

    # Re-write wp-config.php using the shared helper.
    if ! _wp_write_config "$install_path" "$db_name" "$db_user" "$db_pass" "$db_host" "$db_port" "$keep_salts"; then
        log_err "[70][wp][reconfigure] wp-config.php write/verify failed -- restore from the .bak.<ts> file in $install_path/"
        return 1
    fi

    # Update credentials record so show-credentials reflects the new state.
    _wp_save_credentials_record "$install_path" "${WP_DB_ENGINE:-mysql}" \
        "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass" || true

    log_ok "[70][wp][reconfigure] OK -- new credentials live; previous wp-config.php saved as wp-config.php.bak.<ts>"
    return 0
}

component_wordpress_install() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local db_name="${WP_DB_NAME:-wordpress}"
    local db_user="${WP_DB_USER:-wp_user}"
    local db_pass="${WP_DB_PASS:-}"
    local db_host="127.0.0.1"
    local db_port="${WP_MYSQL_PORT:-3306}"

    if [ -z "$db_pass" ]; then
        db_pass="$(_wp_genpass)"
        log_info "[70][wp] auto-generated DB password (24 chars)"
    fi

    log_info "[70][wp] starting installation (path=$install_path db=$db_name user=$db_user)"

    # 1. Download + extract -------------------------------------------------
    if [ -f "$install_path/wp-config.php" ]; then
        log_ok "[70][wp] $install_path already contains wp-config.php -- skipping download/extract"
    else
        # Prefer ZIP (operator's spec). Fall back to tar.gz only if `unzip` is
        # missing AND we can't install it; that keeps the script working on
        # minimal images where unzip isn't preinstalled.
        if ! command -v unzip >/dev/null 2>&1; then
            log_info "[70][wp] 'unzip' not found -- attempting 'apt-get install -y unzip'"
            sudo apt-get install -y unzip >/dev/null 2>&1 || true
        fi

        if ! sudo mkdir -p "$install_path"; then
            log_file_error "$install_path" "mkdir -p failed for WordPress install path"
            return 1
        fi

        if command -v unzip >/dev/null 2>&1; then
            local zipfile="/tmp/wordpress-latest-$$.zip"
            local url="https://wordpress.org/latest.zip"
            log_info "[70][wp] downloading $url -> $zipfile"
            if ! curl -fsSL -o "$zipfile" "$url"; then
                log_file_error "$zipfile" "curl download failed from $url"
                return 1
            fi
            # Integrity gate: verify SHA1 (+ MD5) BEFORE we touch the staging dir
            # so a tampered/corrupt archive can never extract onto the host.
            if ! _wp_verify_download "$zipfile" "$url"; then
                log_err "[70][wp] download integrity check failed -- aborting (file kept at $zipfile for forensics)"
                return 1
            fi
            local stage; stage="$(mktemp -d)"
            log_info "[70][wp] unzipping into staging dir $stage"
            if ! unzip -q "$zipfile" -d "$stage"; then
                log_file_error "$zipfile" "unzip extract failed (target: $stage)"
                rm -rf "$zipfile" "$stage"
                return 1
            fi
            # The ZIP contains a top-level 'wordpress/' directory; move its
            # contents (including dotfiles) into $install_path so files land
            # at $install_path/* (matching the previous --strip-components=1).
            if [ ! -d "$stage/wordpress" ]; then
                log_file_error "$stage/wordpress" "expected 'wordpress/' top-level dir inside ZIP -- archive layout changed"
                rm -rf "$zipfile" "$stage"
                return 1
            fi
            if ! sudo bash -c "shopt -s dotglob nullglob; mv '$stage/wordpress'/* '$install_path'/"; then
                log_file_error "$install_path" "mv from staged ZIP failed (source: $stage/wordpress)"
                rm -rf "$zipfile" "$stage"
                return 1
            fi
            rm -rf "$zipfile" "$stage"
            log_ok "[70][wp] ZIP extracted to $install_path"
        else
            local tarball="/tmp/wordpress-latest-$$.tar.gz"
            local url="https://wordpress.org/latest.tar.gz"
            log_warn "[70][wp] 'unzip' unavailable after apt-get; falling back to tar.gz"
            log_info "[70][wp] downloading $url -> $tarball"
            if ! curl -fsSL -o "$tarball" "$url"; then
                log_file_error "$tarball" "curl download failed from $url"
                return 1
            fi
            # Integrity gate -- same contract as the ZIP path.
            if ! _wp_verify_download "$tarball" "$url"; then
                log_err "[70][wp] download integrity check failed -- aborting (file kept at $tarball for forensics)"
                return 1
            fi
            # --strip-components=1 so files land at $install_path/* not $install_path/wordpress/*
            if ! sudo tar -xzf "$tarball" -C "$install_path" --strip-components=1; then
                log_file_error "$install_path" "tar extract failed (source: $tarball)"
                rm -f "$tarball"
                return 1
            fi
            rm -f "$tarball"
        fi

        sudo chown -R www-data:www-data "$install_path" || true
        sudo find "$install_path" -type d -exec chmod 755 {} \; 2>/dev/null || true
        sudo find "$install_path" -type f -exec chmod 644 {} \; 2>/dev/null || true
    fi

    # 2. Database + user ---------------------------------------------------
    log_info "[70][wp] creating database '$db_name' and user '$db_user'@'localhost'"
    local create_db_sql="
      CREATE DATABASE IF NOT EXISTS \`${db_name}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
      ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
      GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
      FLUSH PRIVILEGES;"
    local sql_out sql_rc
    sql_out="$(_wp_mysql_run "$create_db_sql")"
    sql_rc=$?
    if [ "$sql_rc" -ne 0 ] || echo "$sql_out" | grep -qiE 'ERROR'; then
        log_err "[70][wp] MySQL grant/create failed (rc=${sql_rc}): ${sql_out}"
        return 1
    fi

    # 3. wp-config.php -----------------------------------------------------
    # Delegate to the shared helper. keep_salts=0 here -- a fresh install
    # always gets a fresh salt set from api.wordpress.org. The helper
    # handles sed substitution, salt rotation, AND the strict verify gate.
    if ! _wp_write_config "$install_path" "$db_name" "$db_user" "$db_pass" "$db_host" "$db_port" "0"; then
        log_err "[70][wp] wp-config.php generation failed -- aborting install (see errors above)"
        return 1
    fi

    # 4. Save credential record (so the operator can recover the auto-generated pw)
    _wp_save_credentials_record "$install_path" "${WP_DB_ENGINE:-mysql}" \
        "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass" || true

    if ! component_wordpress_verify; then
        log_err "[70][wp] post-install verify failed (wp-config.php or index.php missing in $install_path)"
        return 1
    fi
    log_ok "[70][wp] installed OK -- visit http://${WP_SERVER_NAME:-localhost}:${WP_SITE_PORT:-80}/ to finish setup in the browser"
    touch "$rec_dir/70-wordpress.ok"
    return 0
}

# component_wordpress_show_credentials [--json]
# Prints the database credentials and salts location for the installed
# WordPress site, sourced from .installed/70-wordpress-credentials.json
# (the chmod 600 record written during install). Salts are embedded
# inline in wp-config.php -- there is no separate salts file -- so we
# point the operator at that exact location and offer a one-liner to
# extract them.
component_wordpress_show_credentials() {
    local mode="text"
    if [ "${1:-}" = "--json" ]; then
        mode="json"
    fi

    local rec="$ROOT/.installed/70-wordpress-credentials.json"
    if [ ! -f "$rec" ]; then
        log_file_error "$rec" "credentials record missing -- run 'install wordpress' first (file is written with chmod 600 at end of install)"
        return 1
    fi

    if [ "$mode" = "json" ]; then
        # Raw passthrough -- callers can pipe to jq.
        cat "$rec"
        return 0
    fi

    # Parse with a tiny awk extractor so we don't add a jq dependency.
    _wp_field() {
        awk -v key="\"$1\"" '
            $0 ~ key {
                # split on the first colon, then strip quotes/commas/whitespace
                sub(/^[^:]*:[[:space:]]*/, "")
                gsub(/^[[:space:]"]+|[[:space:],"]+$/, "")
                print
                exit
            }' "$rec"
    }

    local install_path site_url db_engine db_host db_port db_name db_user db_pass generated_at
    install_path="$(_wp_field install_path)"
    site_url="$(_wp_field site_url)"
    db_engine="$(_wp_field db_engine)"
    db_host="$(_wp_field db_host)"
    db_port="$(_wp_field db_port)"
    db_name="$(_wp_field db_name)"
    db_user="$(_wp_field db_user)"
    db_pass="$(_wp_field db_pass)"
    generated_at="$(_wp_field generated_at)"

    local cfg="${install_path}/wp-config.php"
    local cfg_status="present"
    if [ ! -f "$cfg" ]; then
        cfg_status="MISSING (expected at this path -- WordPress files may have been removed)"
    fi

    # Print to stdout (not the logger) so the operator can pipe/redirect
    # cleanly. Logger lines still announce the section header.
    log_info "[70][wp] showing saved credentials from $rec"
    cat <<EOF

============================================================
 WordPress installation -- saved credentials
============================================================
 Generated at : ${generated_at}
 Install path : ${install_path}
 Site URL     : ${site_url}

 Database
 --------
 Engine       : ${db_engine}
 Host         : ${db_host}
 Port         : ${db_port}
 Name         : ${db_name}
 User         : ${db_user}
 Password     : ${db_pass}

 wp-config.php
 -------------
 Path         : ${cfg}
 Status       : ${cfg_status}
 Salts path   : ${cfg}  (salts are embedded inline -- no separate file)
 Show salts   : sudo grep -E "^define\\( *'(AUTH|SECURE_AUTH|LOGGED_IN|NONCE)_(KEY|SALT)'" ${cfg}

 Credentials record
 ------------------
 JSON file    : ${rec}  (chmod 600)
 Re-show JSON : $0 show-credentials --json
============================================================

EOF
    return 0
}

component_wordpress_uninstall() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    local db_name="${WP_DB_NAME:-wordpress}"
    local db_user="${WP_DB_USER:-wp_user}"
    if command -v mysql >/dev/null 2>&1; then
        sudo mysql -uroot -e "DROP DATABASE IF EXISTS \`${db_name}\`; DROP USER IF EXISTS '${db_user}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
    fi
    if [ -d "$install_path" ]; then
        sudo rm -rf "$install_path" || log_file_error "$install_path" "rm -rf failed"
    fi
    rm -f "$ROOT/.installed/70-wordpress.ok" "$ROOT/.installed/70-wordpress-credentials.json"
    log_ok "[70][wp] removed (path=$install_path db=$db_name user=$db_user)"
}