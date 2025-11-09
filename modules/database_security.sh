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

    if ! confirm "Apply MySQL/MariaDB security hardening?"; then
        print_info "Skipping MySQL/MariaDB hardening."
        return 0
    fi

    # Determine which service is running
    local mysql_service=""
    if systemctl is-active --quiet mysql 2>/dev/null; then
        mysql_service="mysql"
    elif systemctl is-active --quiet mysqld 2>/dev/null; then
        mysql_service="mysqld"
    elif systemctl is-active --quiet mariadb 2>/dev/null; then
        mysql_service="mariadb"
    else
        print_error "No MySQL/MariaDB service is running"
        return 1
    fi

    print_info "Securing MySQL/MariaDB installation..."

    # Run mysql_secure_installation if available
    if command -v mysql_secure_installation >/dev/null 2>&1; then
        print_info "Running mysql_secure_installation..."
        # Note: This is interactive, so we'll provide guidance instead
        print_warning "Please run 'mysql_secure_installation' manually to:"
        print_info "  - Set root password"
        print_info "  - Remove anonymous users"
        print_info "  - Disallow remote root login"
        print_info "  - Remove test database"
        print_info "  - Reload privilege tables"
    else
        print_warning "mysql_secure_installation not found. Manual configuration required."
    fi

    # Create secure MySQL configuration
    local mysql_conf="/etc/mysql/conf.d/security.cnf"
    if [[ ! -f "$mysql_conf" ]]; then
        print_info "Creating secure MySQL configuration..."
        mkdir -p /etc/mysql/conf.d

        cat > "$mysql_conf" <<'EOF'
[mysqld]
# Security enhancements
skip-show-database = 1
local-infile = 0

# Logging for audit
general_log = 1
general_log_file = /var/log/mysql/general.log
log_error = /var/log/mysql/error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# Connection security
max_connect_errors = 10
max_user_connections = 100

# SSL/TLS (if certificates are available)
# require_secure_transport = ON
# ssl-ca = /etc/mysql/ssl/ca.pem
# ssl-cert = /etc/mysql/ssl/server-cert.pem
# ssl-key = /etc/mysql/ssl/server-key.pem
EOF

        # Restart MySQL service
        print_info "Restarting MySQL service..."
        systemctl restart "$mysql_service"

        if systemctl is-active --quiet "$mysql_service"; then
            print_success "MySQL/MariaDB security configuration applied"
        else
            print_error "MySQL/MariaDB service failed to restart"
            FAILED_SERVICES+=("$mysql_service")
        fi
    else
        print_info "MySQL security configuration already exists"
    fi

    log "MySQL/MariaDB hardening completed"
}

# --- PostgreSQL Security Function ---
harden_postgresql() {
    print_section "PostgreSQL Security Hardening"

    if ! confirm "Apply PostgreSQL security hardening?"; then
        print_info "Skipping PostgreSQL hardening."
        return 0
    fi

    # Find PostgreSQL data directory
    local pg_data=""
    local pg_version=""

    # Try to determine PostgreSQL version and data directory
    if command -v psql >/dev/null 2>&1; then
        pg_version=$(psql --version | awk '{print $3}' | cut -d. -f1-2)
        pg_data="/var/lib/postgresql/$pg_version/main"
    fi

    if [[ -z "$pg_data" || ! -d "$pg_data" ]]; then
        print_error "Could not determine PostgreSQL data directory"
        return 1
    fi

    print_info "Securing PostgreSQL installation..."

    # Backup original configuration
    local pg_hba="$pg_data/pg_hba.conf"
    local pg_conf="$pg_data/postgresql.conf"

    if [[ -f "$pg_hba" ]]; then
        cp "$pg_hba" "$pg_hba.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    if [[ -f "$pg_conf" ]]; then
        cp "$pg_conf" "$pg_conf.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Configure pg_hba.conf for secure connections
    print_info "Configuring secure host-based authentication..."
    cat > "$pg_hba" <<'EOF'
# PostgreSQL Client Authentication Configuration File
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     md5

# IPv4 local connections:
host    all             all             127.0.0.1/32            md5
host    all             all             0.0.0.0/0               reject

# IPv6 local connections:
host    all             all             ::1/128                 md5
host    all             all             ::/0                    reject

# Allow replication connections from localhost, by a user with the
# replication privilege.
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            md5
host    replication     all             ::1/128                 md5
EOF

    # Configure postgresql.conf for security
    print_info "Configuring PostgreSQL security settings..."

    # Update or add security settings
    grep -q "^ssl = on" "$pg_conf" || echo "ssl = on" >> "$pg_conf"
    grep -q "^password_encryption = scram-sha-256" "$pg_conf" || echo "password_encryption = scram-sha-256" >> "$pg_conf"
    grep -q "^logging_collector = on" "$pg_conf" || echo "logging_collector = on" >> "$pg_conf"
    grep -q "^log_destination = 'stderr'" "$pg_conf" || echo "log_destination = 'stderr'" >> "$pg_conf"
    grep -q "^log_directory = 'log'" "$pg_conf" || echo "log_directory = 'log'" >> "$pg_conf"
    grep -q "^log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'" "$pg_conf" || echo "log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'" >> "$pg_conf"
    grep -q "^log_statement = 'all'" "$pg_conf" || echo "log_statement = 'all'" >> "$pg_conf"
    grep -q "^log_connections = on" "$pg_conf" || echo "log_connections = on" >> "$pg_conf"
    grep -q "^log_disconnections = on" "$pg_conf" || echo "log_disconnections = on" >> "$pg_conf"
    grep -q "^log_lock_waits = on" "$pg_conf" || echo "log_lock_waits = on" >> "$pg_conf"

    # Restart PostgreSQL
    print_info "Restarting PostgreSQL service..."
    systemctl restart postgresql

    if systemctl is-active --quiet postgresql; then
        print_success "PostgreSQL security configuration applied"
    else
        print_error "PostgreSQL service failed to restart"
        FAILED_SERVICES+=("postgresql")
    fi

    log "PostgreSQL hardening completed"
}

# --- Database Firewall Configuration Function ---
configure_database_firewall() {
    print_section "Database Firewall Configuration"

    if ! confirm "Configure firewall rules for database access?"; then
        print_info "Skipping database firewall configuration."
        return 0
    fi

    # Check if UFW is available
    if ! command -v ufw >/dev/null 2>&1; then
        print_warning "UFW firewall not found. Skipping firewall configuration."
        return 1
    fi

    local firewall_rules_applied=false

    # MySQL/MariaDB firewall rules
    if [[ "$MYSQL_DETECTED" == "true" ]]; then
        print_info "Configuring firewall for MySQL/MariaDB..."

        # Allow MySQL from localhost only
        if ufw allow from 127.0.0.1 to any port 3306 >/dev/null 2>&1; then
            print_success "MySQL/MariaDB firewall rules applied (localhost only)"
            firewall_rules_applied=true
        fi

        # Deny MySQL from external sources
        if ufw deny from any to any port 3306 >/dev/null 2>&1; then
            print_success "External MySQL/MariaDB access blocked"
        fi
    fi

    # PostgreSQL firewall rules
    if [[ "$POSTGRESQL_DETECTED" == "true" ]]; then
        print_info "Configuring firewall for PostgreSQL..."

        # Allow PostgreSQL from localhost only
        if ufw allow from 127.0.0.1 to any port 5432 >/dev/null 2>&1; then
            print_success "PostgreSQL firewall rules applied (localhost only)"
            firewall_rules_applied=true
        fi

        # Deny PostgreSQL from external sources
        if ufw deny from any to any port 5432 >/dev/null 2>&1; then
            print_success "External PostgreSQL access blocked"
        fi
    fi

    if [[ "$firewall_rules_applied" == "true" ]]; then
        print_info "Reloading firewall..."
        ufw reload >/dev/null 2>&1
        print_success "Database firewall configuration completed"
    fi

    log "Database firewall configuration completed"
}

# --- Database Backup Encryption Function ---
setup_database_backup_encryption() {
    print_section "Database Backup Encryption Setup"

    if ! confirm "Set up encrypted database backups with GPG?"; then
        print_info "Skipping database backup encryption setup."
        return 0
    fi

    # Check if GPG is available
    if ! command -v gpg >/dev/null 2>&1; then
        print_info "Installing GPG for backup encryption..."
        apt-get update >/dev/null 2>&1
        apt-get install -y gnupg2 >/dev/null 2>&1
    fi

    # Create backup directory
    local backup_dir="/var/backups/database_encrypted"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    # Create backup script
    local backup_script="/usr/local/bin/database_backup.sh"

    cat > "$backup_script" <<'EOF'
#!/bin/bash

# Database Backup Script with GPG Encryption
# Created by du_setup_modular.sh database security module

BACKUP_DIR="/var/backups/database_encrypted"
LOG_FILE="/var/log/database_backup.log"
DATE=$(date +%Y%m%d_%H%M%S)

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to backup MySQL/MariaDB (native and Docker)
backup_mysql() {
    # Check for native MySQL/MariaDB
    if command -v mysql >/dev/null 2>&1 && systemctl is-active --quiet mysql 2>/dev/null; then
        log "Starting native MySQL backup..."
        local backup_file="$BACKUP_DIR/mysql_native_backup_$DATE.sql"

        # Create SQL backup
        mysqldump --single-transaction --routines --triggers --all-databases > "$backup_file"

        if [[ -f "$backup_file" ]]; then
            # Encrypt with GPG (you'll need to set up a GPG key)
            gpg --symmetric --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
                --s2k-digest-algo SHA512 --s2k-count 65536 --force-mdc \
                --output "$backup_file.gpg" "$backup_file"

            # Remove unencrypted backup
            rm "$backup_file"

            log "Native MySQL backup encrypted: $backup_file.gpg"
        fi
    fi

    # Check for Docker MySQL/MariaDB containers
    if command -v docker >/dev/null 2>&1; then
        local mysql_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep -E "(mysql|mariadb)" | awk '{print $1}')
        for container in $mysql_containers; do
            log "Starting Docker MySQL backup for container: $container"
            local backup_file="$BACKUP_DIR/mysql_docker_${container}_backup_$DATE.sql"

            # Create SQL backup from Docker container
            docker exec "$container" mysqldump --single-transaction --routines --triggers --all-databases > "$backup_file" 2>/dev/null

            if [[ -f "$backup_file" && -s "$backup_file" ]]; then
                # Encrypt with GPG (you'll need to set up a GPG key)
                gpg --symmetric --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
                    --s2k-digest-algo SHA512 --s2k-count 65536 --force-mdc \
                    --output "$backup_file.gpg" "$backup_file"

                # Remove unencrypted backup
                rm "$backup_file"

                log "Docker MySQL backup encrypted for $container: $backup_file.gpg"
            else
                log "Failed to create backup for Docker MySQL container: $container"
            fi
        done
    fi
}

# Function to backup PostgreSQL (native and Docker)
backup_postgresql() {
    # Check for native PostgreSQL
    if command -v pg_dumpall >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
        log "Starting native PostgreSQL backup..."
        local backup_file="$BACKUP_DIR/postgresql_native_backup_$DATE.sql"

        # Create SQL backup
        sudo -u postgres pg_dumpall > "$backup_file"

        if [[ -f "$backup_file" ]]; then
            # Encrypt with GPG (you'll need to set up a GPG key)
            gpg --symmetric --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
                --s2k-digest-algo SHA512 --s2k-count 65536 --force-mdc \
                --output "$backup_file.gpg" "$backup_file"

            # Remove unencrypted backup
            rm "$backup_file"

            log "Native PostgreSQL backup encrypted: $backup_file.gpg"
        fi
    fi

    # Check for Docker PostgreSQL containers
    if command -v docker >/dev/null 2>&1; then
        local postgresql_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep postgres | awk '{print $1}')
        for container in $postgresql_containers; do
            log "Starting Docker PostgreSQL backup for container: $container"
            local backup_file="$BACKUP_DIR/postgresql_docker_${container}_backup_$DATE.sql"

            # Create SQL backup from Docker container
            docker exec "$container" pg_dumpall -U postgres > "$backup_file" 2>/dev/null

            if [[ -f "$backup_file" && -s "$backup_file" ]]; then
                # Encrypt with GPG (you'll need to set up a GPG key)
                gpg --symmetric --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
                    --s2k-digest-algo SHA512 --s2k-count 65536 --force-mdc \
                    --output "$backup_file.gpg" "$backup_file"

                # Remove unencrypted backup
                rm "$backup_file"

                log "Docker PostgreSQL backup encrypted for $container: $backup_file.gpg"
            else
                log "Failed to create backup for Docker PostgreSQL container: $container"
            fi
        done
    fi
}

# Main backup execution
backup_mysql
backup_postgresql

# Clean up old backups (keep last 7 days)
find "$BACKUP_DIR" -name "*.gpg" -mtime +7 -delete

log "Database backup completed"
EOF

    chmod +x "$backup_script"

    # Create cron job for daily backups at 2 AM
    local cron_file="/etc/cron.d/database_backup"
    echo "0 2 * * * root $backup_script" > "$cron_file"

    print_success "Database backup encryption script created"
    print_info "Backup script: $backup_script"
    print_info "Backup directory: $backup_dir"
    print_warning "Remember to set up GPG keys for encryption"
    print_info "Cron job scheduled for daily execution at 2 AM"

    log "Database backup encryption setup completed"
}

# --- Database Audit Logging Function ---
setup_database_audit_logging() {
    print_section "Database Audit Logging Configuration"

    if ! confirm "Set up comprehensive database audit logging?"; then
        print_info "Skipping database audit logging setup."
        return 0
    fi

    local audit_configured=false

    # MySQL/MariaDB audit logging
    if [[ "$MYSQL_DETECTED" == "true" ]]; then
        print_info "Configuring MySQL/MariaDB audit logging..."

        local mysql_audit_conf="/etc/mysql/conf.d/audit.cnf"
        if [[ ! -f "$mysql_audit_conf" ]]; then
            cat > "$mysql_audit_conf" <<'EOF'
[mysqld]
# Audit Plugin Configuration
plugin-load = audit_log.so
audit_log_file = /var/log/mysql/audit.log
audit_log_format = JSON
audit_log_policy = ALL
audit_log_rotate_on_size = 1073741824  # 1GB
audit_log_rotations = 5
audit_log_buffer_size = 1048576  # 1MB
EOF

            # Create audit log directory and set permissions
            mkdir -p /var/log/mysql
            touch /var/log/mysql/audit.log
            chown mysql:mysql /var/log/mysql/audit.log
            chmod 640 /var/log/mysql/audit.log

            audit_configured=true
            print_success "MySQL/MariaDB audit logging configured"
        else
            print_info "MySQL/MariaDB audit logging already configured"
        fi
    fi

    # PostgreSQL audit logging
    if [[ "$POSTGRESQL_DETECTED" == "true" ]]; then
        print_info "Configuring PostgreSQL audit logging..."

        # Install pgaudit extension if available
        if apt-cache show postgresql-*-pgaudit >/dev/null 2>&1; then
            local pg_version=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)
            if [[ -n "$pg_version" ]]; then
                apt-get install -y "postgresql-$pg_version-pgaudit" >/dev/null 2>&1

                # Find PostgreSQL data directory
                local pg_data="/var/lib/postgresql/$pg_version/main"
                local pg_conf="$pg_data/postgresql.conf"

                # Add pgaudit configuration
                grep -q "^shared_preload_libraries = 'pgaudit'" "$pg_conf" || \
                    echo "shared_preload_libraries = 'pgaudit'" >> "$pg_conf"

                grep -q "^pgaudit.log = 'all'" "$pg_conf" || \
                    echo "pgaudit.log = 'all'" >> "$pg_conf"

                grep -q "^pgaudit.log_catalog = on" "$pg_conf" || \
                    echo "pgaudit.log_catalog = on" >> "$pg_conf"

                grep -q "^pgaudit.log_level = 'log'" "$pg_conf" || \
                    echo "pgaudit.log_level = 'log'" >> "$pg_conf"

                # Restart PostgreSQL to load pgaudit
                systemctl restart postgresql

                audit_configured=true
                print_success "PostgreSQL audit logging configured with pgaudit"
            fi
        else
            print_warning "PostgreSQL audit extension (pgaudit) not available"
        fi
    fi

    if [[ "$audit_configured" == "true" ]]; then
        # Create log rotation for audit logs
        local logrotate_conf="/etc/logrotate.d/database-audit"
        cat > "$logrotate_conf" <<'EOF'
/var/log/mysql/audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 640 mysql mysql
    postrotate
        systemctl reload mysql >/dev/null 2>&1 || true
    endscript
}

/var/log/postgresql/*/postgresql-*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload postgresql >/dev/null 2>&1 || true
    endscript
}
EOF

        print_success "Database audit logging configured with log rotation"
    fi

    log "Database audit logging setup completed"
}

# --- Docker Database Security Functions ---
harden_docker_mysql() {
    print_section "Docker MySQL/MariaDB Security Hardening"

    if ! confirm "Apply Docker MySQL/MariaDB security hardening?"; then
        print_info "Skipping Docker MySQL/MariaDB hardening."
        return 0
    fi

    local mysql_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep -E "(mysql|mariadb)" | awk '{print $1}')

    for container in $mysql_containers; do
        print_info "Securing Docker MySQL/MariaDB container: $container"

        # Check if container has custom config mounted
        local has_config_mount=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/etc/mysql/conf.d"}}{{.Source}}{{end}}{{end}}' "$container" 2>/dev/null)

        if [[ -n "$has_config_mount" ]]; then
            print_info "Container $container has config mounted at $has_config_mount"

            # Create security config file on host
            local security_config="$has_config_mount/security.cnf"
            if [[ ! -f "$security_config" ]]; then
                cat > "$security_config" <<'EOF'
[mysqld]
# Security enhancements
skip-show-database = 1
local-infile = 0

# Logging for audit
general_log = 1
general_log_file = /var/log/mysql/general.log
log_error = /var/log/mysql/error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# Connection security
max_connect_errors = 10
max_user_connections = 100
EOF
                print_success "Created security config for $container"

                # Restart container to apply config
                docker restart "$container" >/dev/null 2>&1
                print_info "Restarted container $container to apply security settings"
            else
                print_info "Security config already exists for $container"
            fi
        else
            print_warning "Container $container does not have config directory mounted. Manual configuration required."
            print_info "Consider running with: -v /path/to/config:/etc/mysql/conf.d"
        fi
    done

    log "Docker MySQL/MariaDB hardening completed"
}

harden_docker_postgresql() {
    print_section "Docker PostgreSQL Security Hardening"

    if ! confirm "Apply Docker PostgreSQL security hardening?"; then
        print_info "Skipping Docker PostgreSQL hardening."
        return 0
    fi

    local postgresql_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep postgres | awk '{print $1}')

    for container in $postgresql_containers; do
        print_info "Securing Docker PostgreSQL container: $container"

        # Check if container has data directory mounted
        local has_data_mount=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' "$container" 2>/dev/null)

        if [[ -n "$has_data_mount" ]]; then
            print_info "Container $container has data mounted at $has_data_mount"

            # Create postgresql.conf security additions
            local pg_conf="$has_data_mount/postgresql.conf"
            if [[ -f "$pg_conf" ]]; then
                # Backup original
                cp "$pg_conf" "$pg_conf.backup.$(date +%Y%m%d_%H%M%S)"

                # Add security settings
                grep -q "^password_encryption = scram-sha-256" "$pg_conf" || \
                    echo "password_encryption = scram-sha-256" >> "$pg_conf"

                grep -q "^logging_collector = on" "$pg_conf" || \
                    echo "logging_collector = on" >> "$pg_conf"

                grep -q "^log_statement = 'all'" "$pg_conf" || \
                    echo "log_statement = 'all'" >> "$pg_conf"

                grep -q "^log_connections = on" "$pg_conf" || \
                    echo "log_connections = on" >> "$pg_conf"

                grep -q "^log_disconnections = on" "$pg_conf" || \
                    echo "log_disconnections = on" >> "$pg_conf"

                # Create pg_hba.conf for secure connections
                local pg_hba="$has_data_mount/pg_hba.conf"
                if [[ -f "$pg_hba" ]]; then
                    cp "$pg_hba" "$pg_hba.backup.$(date +%Y%m%d_%H%M%S)"

                    cat > "$pg_hba" <<'EOF'
# PostgreSQL Client Authentication Configuration File
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     md5

# IPv4 local connections:
host    all             all             127.0.0.1/32            md5
host    all             all             0.0.0.0/0               reject

# IPv6 local connections:
host    all             all             ::1/128                 md5
host    all             all             ::/0                    reject

# Allow replication connections from localhost
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            md5
host    replication     all             ::1/128                 md5
EOF
                fi

                # Restart container to apply config
                docker restart "$container" >/dev/null 2>&1
                print_success "Restarted container $container to apply security settings"
            else
                print_warning "Could not find postgresql.conf in mounted data directory"
            fi
        else
            print_warning "Container $container does not have data directory mounted. Manual configuration required."
            print_info "Consider running with: -v /path/to/data:/var/lib/postgresql/data"
        fi
    done

    log "Docker PostgreSQL hardening completed"
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