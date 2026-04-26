#!/usr/bin/env bash
# scripts-linux/70-install-wordpress-ubuntu/components/wordpress.sh
# Downloads latest WordPress, extracts to WP_INSTALL_PATH, creates the
# database + user, writes wp-config.php with secure salts.
set -u

_wp_genpass() {
    # 24-char password from /dev/urandom; alnum only (no shell-special chars).
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

component_wordpress_verify() {
    local install_path="${WP_INSTALL_PATH:-/var/www/wordpress}"
    [ -f "$install_path/wp-config.php" ] || return 1
    [ -f "$install_path/index.php" ]      || return 1
    return 0
}

_wp_mysql_run() {
    # Run a SQL command as root via socket auth (default on Ubuntu MySQL 8).
    local sql="$1"
    sudo mysql -uroot -e "$sql" 2>&1
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
        local tarball="/tmp/wordpress-latest-$$.tar.gz"
        local url="https://wordpress.org/latest.tar.gz"
        log_info "[70][wp] downloading $url -> $tarball"
        if ! curl -fsSL -o "$tarball" "$url"; then
            log_file_error "$tarball" "curl download failed from $url"
            return 1
        fi
        if ! sudo mkdir -p "$install_path"; then
            log_file_error "$install_path" "mkdir -p failed for WordPress install path"
            rm -f "$tarball"
            return 1
        fi
        # Extract; --strip-components=1 so files land at $install_path/* not $install_path/wordpress/*
        if ! sudo tar -xzf "$tarball" -C "$install_path" --strip-components=1; then
            log_file_error "$install_path" "tar extract failed (source: $tarball)"
            rm -f "$tarball"
            return 1
        fi
        rm -f "$tarball"
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
    local cfg="$install_path/wp-config.php"
    if [ ! -f "$install_path/wp-config-sample.php" ]; then
        log_file_error "$install_path/wp-config-sample.php" "wp-config-sample.php missing -- WordPress tarball was malformed"
        return 1
    fi
    log_info "[70][wp] writing $cfg"
    sudo cp "$install_path/wp-config-sample.php" "$cfg" || {
        log_file_error "$cfg" "cp from wp-config-sample.php failed"
        return 1
    }
    sudo sed -i \
        -e "s/database_name_here/${db_name}/" \
        -e "s/username_here/${db_user}/" \
        -e "s|password_here|${db_pass}|" \
        -e "s/localhost/${db_host}:${db_port}/" \
        "$cfg" || {
        log_file_error "$cfg" "sed replacement failed for DB credentials"
        return 1
    }

    # Replace the entire SALT block with a fresh set from the WordPress API.
    local salts; salts="$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || echo '')"
    if [ -n "$salts" ]; then
        local tmp; tmp="$(mktemp)"
        # Drop existing AUTH_KEY..NONCE_SALT lines, append fresh ones.
        # The redirect runs with the operator's uid (mktemp is operator-writable),
        # so plain `awk ... > "$tmp"` is correct -- no sudo on the redirect.
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
        log_ok "[70][wp] wp-config.php written with fresh API salts"
    else
        log_warn "[70][wp] could not fetch fresh salts from api.wordpress.org -- wp-config.php contains the placeholder salts; rotate them manually"
    fi

    # 4. Save credential record (so the operator can recover the auto-generated pw)
    local rec_dir="$ROOT/.installed"
    mkdir -p "$rec_dir"
    local rec="$rec_dir/70-wordpress-credentials.json"
    cat > "$rec" <<EOF
{
  "install_path": "$install_path",
  "site_url": "http://${WP_SERVER_NAME:-localhost}:${WP_SITE_PORT:-80}/",
  "db_engine": "${WP_DB_ENGINE:-mysql}",
  "db_host": "${db_host}",
  "db_port": ${db_port},
  "db_name": "${db_name}",
  "db_user": "${db_user}",
  "db_pass": "${db_pass}",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$rec" 2>/dev/null || true
    log_info "[70][wp] credentials saved -> $rec (chmod 600)"

    if ! component_wordpress_verify; then
        log_err "[70][wp] post-install verify failed (wp-config.php or index.php missing in $install_path)"
        return 1
    fi
    log_ok "[70][wp] installed OK -- visit http://${WP_SERVER_NAME:-localhost}:${WP_SITE_PORT:-80}/ to finish setup in the browser"
    touch "$rec_dir/70-wordpress.ok"
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