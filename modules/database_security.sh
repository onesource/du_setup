#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Database Security Module
# Handles database security hardening for MySQL/MariaDB/PostgreSQL
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Database Detection Function ---
detect_databases() {
    print_section "Database Detection"

    local mysql_detected=false
    local postgresql_detected=false
    local docker_mysql_detected=false
    local docker_postgresql_detected=false

    # Check for native MySQL/MariaDB
    if command -v mysql >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1; then
        if systemctl is-active --quiet mysql 2>/dev/null || \
           systemctl is-active --quiet mysqld 2>/dev/null || \
           systemctl is-active --quiet mariadb 2>/dev/null; then
            mysql_detected=true
            print_success "MySQL/MariaDB detected and running (native)"
        fi
    fi

    # Check for native PostgreSQL
    if command -v psql >/dev/null 2>&1 || command -v postgres >/dev/null 2>&1; then
        if systemctl is-active --quiet postgresql 2>/dev/null; then
            postgresql_detected=true
            print_success "PostgreSQL detected and running (native)"
        fi
    fi

    # Check for Docker databases if Docker is available
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        print_info "Checking for Docker database containers..."

        # Check for MySQL/MariaDB Docker containers
        local mysql_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep -E "(mysql|mariadb)" | awk '{print $1}')
        if [[ -n "$mysql_containers" ]]; then
            docker_mysql_detected=true
            print_success "MySQL/MariaDB Docker containers detected:"
            for container in $mysql_containers; do
                local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown")
                print_info "  - $container (image: $image)"
            done
        fi

        # Check for PostgreSQL Docker containers
        local postgresql_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep postgres | awk '{print $1}')
        if [[ -n "$postgresql_containers" ]]; then
            docker_postgresql_detected=true
            print_success "PostgreSQL Docker containers detected:"
            for container in $postgresql_containers; do
                local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown")
                print_info "  - $container (image: $image)"
            done
        fi
    fi

    # Set global variables for detected databases
    MYSQL_DETECTED=$mysql_detected
    POSTGRESQL_DETECTED=$postgresql_detected
    DOCKER_MYSQL_DETECTED=$docker_mysql_detected
    DOCKER_POSTGRESQL_DETECTED=$docker_postgresql_detected

    if [[ "$MYSQL_DETECTED" == "false" && "$POSTGRESQL_DETECTED" == "false" && \
          "$DOCKER_MYSQL_DETECTED" == "false" && "$DOCKER_POSTGRESQL_DETECTED" == "false" ]]; then
        print_info "No supported database systems detected. Skipping database security configuration."
        return 1
    fi

    return 0
}

# --- MySQL/MariaDB Hardening Function ---
harden_mysql() {
    print_section "MySQL/MariaDB Security Hardening"
    local mysql_service="" desired=true staged config changed=false validator=""
    systemctl is-active --quiet mysql 2>/dev/null && mysql_service=mysql
    systemctl is-active --quiet mariadb 2>/dev/null && mysql_service=mariadb
    [[ -n "$mysql_service" ]] || { print_warning "No active MySQL/MariaDB service found."; return 0; }
    desired=$(prompt_bool_current "Manage conservative MySQL/MariaDB hardening?" true) || return 1
    state_set database.mysql.hardening "$desired"
    [[ "$desired" == "true" ]] || return 0
    config=/etc/mysql/conf.d/99-du-setup-security.cnf
    staged=$(mktemp)
    cat > "$staged" <<'EOF'
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
# Application-specific settings belong in a different conf.d file.
[mysqld]
local-infile=0
skip-show-database=1
max-connect-errors=100
# General query logging is intentionally not enabled: it can expose secrets
# and impose substantial production overhead.
EOF
    if command -v mysqld >/dev/null 2>&1; then validator=mysqld; elif command -v mariadbd >/dev/null 2>&1; then validator=mariadbd; fi
    if [[ -n "$validator" ]]; then
        mkdir -p /etc/mysql/conf.d
        local backup=""
        [[ -f "$config" ]] && { backup=$(mktemp); cp -a "$config" "$backup"; }
        install -m 0644 -o root -g root "$staged" "$config"
        if ! "$validator" --verbose --help >/dev/null 2>&1; then
            print_error "Database server rejected the managed MySQL/MariaDB configuration."
            [[ -n "$backup" ]] && cp -a "$backup" "$config" || rm -f "$config"
            rm -f "$backup" "$staged"
            return 1
        fi
        [[ -n "$backup" ]] && cmp -s "$backup" "$config" || changed=true
        rm -f "$backup"
    else
        print_error "Cannot validate MySQL/MariaDB configuration; no file was installed."
        rm -f "$staged"
        return 1
    fi
    rm -f "$staged"
    if [[ "$changed" == "true" ]]; then
        systemctl restart "$mysql_service"
        systemctl is-active --quiet "$mysql_service" || return 1
    else
        print_info "MySQL/MariaDB hardening already matches desired state."
    fi
}

# --- PostgreSQL Security Function ---
harden_postgresql() {
    print_section "PostgreSQL Security Hardening"
    local desired=true pg_conf pg_hba conf_dir managed staged backup="" changed=false
    desired=$(prompt_bool_current "Manage conservative PostgreSQL hardening?" true) || return 1
    state_set database.postgresql.hardening "$desired"
    [[ "$desired" == "true" ]] || return 0
    pg_conf=$(sudo -u postgres psql -Atqc 'show config_file' 2>/dev/null || true)
    pg_hba=$(sudo -u postgres psql -Atqc 'show hba_file' 2>/dev/null || true)
    if [[ -z "$pg_conf" || ! -f "$pg_conf" ]]; then
        print_warning "Could not query PostgreSQL configuration paths; leaving the database unchanged."
        return 0
    fi
    if [[ -f "$pg_hba" ]] && awk 'NF && $1 !~ /^#/ && $NF == "trust" {found=1} END {exit !found}' "$pg_hba"; then
        print_warning "PostgreSQL pg_hba.conf contains trust authentication. It was preserved; review it manually."
    fi
    conf_dir=$(dirname "$pg_conf")/conf.d
    managed="$conf_dir/99-du-setup.conf"
    mkdir -p "$conf_dir"
    if ! grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "$pg_conf"; then
        print_warning "$pg_conf does not include conf.d; preserving it and skipping managed settings."
        return 0
    fi
    staged=$(mktemp)
    cat > "$staged" <<'EOF'
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
# Application-specific settings belong in another conf.d file.
password_encryption = 'scram-sha-256'
log_connections = on
log_disconnections = on
log_lock_waits = on
EOF
    [[ -f "$managed" ]] && { backup=$(mktemp); cp -a "$managed" "$backup"; }
    install -m 0644 -o postgres -g postgres "$staged" "$managed"
    rm -f "$staged"
    if ! sudo -u postgres psql -Atqc 'select pg_reload_conf()' | grep -qx t; then
        print_error "PostgreSQL rejected the managed configuration; rolling it back."
        [[ -n "$backup" ]] && cp -a "$backup" "$managed" || rm -f "$managed"
        sudo -u postgres psql -Atqc 'select pg_reload_conf()' >/dev/null 2>&1 || true
        rm -f "$backup"
        return 1
    fi
    [[ -n "$backup" ]] && cmp -s "$backup" "$managed" || changed=true
    rm -f "$backup"
    [[ "$changed" == "true" ]] && print_success "PostgreSQL managed settings reloaded; pg_hba.conf was preserved." || print_info "PostgreSQL settings already match desired state."
}

# --- Database Firewall Configuration Function ---
configure_database_firewall() {
    print_section "Database Firewall Review"
    print_warning "Database firewall rules are application-owned and will not be rewritten."
    if command -v ufw >/dev/null 2>&1; then
        local relevant_rules
        relevant_rules=$(ufw status numbered 2>/dev/null | grep -E '(^|[^0-9])(3306|5432)([^0-9]|$)' || true)
        if [[ -n "$relevant_rules" ]]; then
            printf '%s\n' "$relevant_rules"
        else
            print_info "No explicit UFW rules for ports 3306 or 5432 were found."
        fi
    fi
    if command -v ss >/dev/null 2>&1; then
        print_info "Observed database listeners:"
        ss -H -lntp 2>/dev/null | grep -E ':(3306|5432)([[:space:]]|$)' || print_info "No TCP database listeners were observed."
    fi
    print_info "Review remote application CIDRs and provider firewall rules before changing database reachability."
    log "Database firewall reviewed without changing application access rules"
}

# --- Database Backup Encryption Function ---
setup_database_backup_encryption() {
    print_section "Database Backup Encryption Setup"
    local installed=false desired recipient script=/usr/local/bin/database_backup.sh
    [[ -f "$script" ]] && installed=true
    desired=$(prompt_bool_current "Manage encrypted native-database backups?" "$installed") || return 1
    state_set database.backup "$desired"
    [[ "$desired" == "true" ]] || {
        print_info "Encrypted database backup remains disabled; existing files were not deleted."
        return 0
    }

    recipient=$(prompt_value_current "GPG recipient fingerprint/email" "$(state_get database.gpg_recipient '')") || return 1
    if ! gpg --batch --list-keys -- "$recipient" >/dev/null 2>&1; then
        print_error "No root GPG public key matches '$recipient'; backup setup was not changed."
        return 1
    fi
    state_set database.gpg_recipient "$recipient"

    install -d -m 0700 /var/backups/database_encrypted
    local staged
    staged=$(mktemp)
    cat > "$staged" <<EOF
#!/bin/bash
# MANAGED BY du_setup_modular. Manual edits may be overwritten on the next run.
set -Eeuo pipefail
umask 077
BACKUP_DIR=/var/backups/database_encrypted
RECIPIENT=$(printf '%q' "$recipient")
DATE=\$(date +%Y%m%d_%H%M%S)
WORK_DIR=\$(mktemp -d /var/backups/.database-backup.XXXXXX)
trap 'rm -rf -- "\$WORK_DIR"' EXIT
install -d -m 0700 "\$BACKUP_DIR"

encrypt_dump() {
    local source=\$1 destination=\$2
    [[ -s "\$source" ]] || return 1
    gpg --batch --yes --trust-model always --recipient "\$RECIPIENT" \
        --output "\$destination" --encrypt "\$source"
    [[ -s "\$destination" ]]
}

if command -v mysqldump >/dev/null 2>&1 && { systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; }; then
    mysql_dump="\$WORK_DIR/mysql.sql"
    if mysqldump --single-transaction --routines --triggers --all-databases > "\$mysql_dump"; then
        encrypt_dump "\$mysql_dump" "\$BACKUP_DIR/mysql_\$DATE.sql.gpg"
    fi
fi

if command -v pg_dumpall >/dev/null 2>&1 && systemctl is-active --quiet postgresql; then
    pg_dump="\$WORK_DIR/postgresql.sql"
    if sudo -u postgres pg_dumpall > "\$pg_dump"; then
        encrypt_dump "\$pg_dump" "\$BACKUP_DIR/postgresql_\$DATE.sql.gpg"
    fi
fi

find "\$BACKUP_DIR" -maxdepth 1 -type f -name '*.gpg' -mtime +7 -delete
EOF
    install -m 0700 -o root -g root "$staged" "$script"
    rm -f "$staged"
    cat > /etc/cron.d/du-setup-database-backup <<'EOF'
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
0 2 * * * root /usr/local/bin/database_backup.sh
EOF
    chmod 0644 /etc/cron.d/du-setup-database-backup
    print_success "Recipient-encrypted native database backups configured."
    print_warning "Docker databases were not modified; configure application-aware dumps separately."
}

# --- Database Audit Logging Function ---
setup_database_audit_logging() {
    print_section "Database Audit Logging Review"
    print_warning "Audit plugins and shared_preload_libraries are application-sensitive and are not enabled automatically."
    if [[ "$MYSQL_DETECTED" == "true" ]]; then
        local mysql_plugins
        mysql_plugins=$(mysql -NBe "SELECT PLUGIN_NAME, PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME LIKE '%audit%';" 2>/dev/null || true)
        [[ -n "$mysql_plugins" ]] && printf '%s\n' "$mysql_plugins" || print_info "No active MySQL/MariaDB audit plugin was detected."
    fi
    if [[ "$POSTGRESQL_DETECTED" == "true" ]]; then
        local pg_preload
        pg_preload=$(sudo -u postgres psql -Atqc "show shared_preload_libraries" 2>/dev/null || true)
        [[ "$pg_preload" == *pgaudit* ]] && print_info "PostgreSQL pgaudit is present in shared_preload_libraries." || print_info "PostgreSQL pgaudit was not detected."
    fi
    print_info "Enable database audit logging through an application-aware maintenance change with plugin validation and a rollback window."
    log "Database audit logging reviewed without changing database plugins"
}

# --- Docker Database Security Functions ---
harden_docker_mysql() {
    print_section "Docker MySQL/MariaDB Security Review"
    print_warning "Container database configuration is application-owned and will not be rewritten."
    docker ps --format '{{.Names}} {{.Image}}' | grep -E '(mysql|mariadb)' || true
    print_info "Use a version-controlled mounted conf.d file in the application deployment."
}

harden_docker_postgresql() {
    print_section "Docker PostgreSQL Security Review"
    print_warning "Container pg_hba.conf and postgresql.conf are application-owned and will not be rewritten."
    docker ps --format '{{.Names}} {{.Image}}' | grep postgres || true
    print_info "Manage PostgreSQL access rules in the application's version-controlled deployment."
}

# --- Main Database Security Function ---
configure_database_security() {
    # First detect what databases are available
    if ! detect_databases; then
        return 0  # No databases found, which is fine
    fi

    # Apply security configurations based on detected databases
    if [[ "$MYSQL_DETECTED" == "true" ]]; then
        harden_mysql
    fi

    if [[ "$POSTGRESQL_DETECTED" == "true" ]]; then
        harden_postgresql
    fi

    # Apply Docker database security if detected
    if [[ "$DOCKER_MYSQL_DETECTED" == "true" ]]; then
        harden_docker_mysql
    fi

    if [[ "$DOCKER_POSTGRESQL_DETECTED" == "true" ]]; then
        harden_docker_postgresql
    fi

    # Configure firewall rules if any databases are detected
    configure_database_firewall

    # Set up backup encryption
    setup_database_backup_encryption

    # Set up audit logging
    setup_database_audit_logging

    print_success "Database security configuration completed"
    log "Database security module finished"
}