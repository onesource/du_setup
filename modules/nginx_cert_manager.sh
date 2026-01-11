#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Nginx Certificate Management Module
# Handles SSL/TLS certificate generation, renewal, and management
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Certificate Management Function ---
manage_certificates() {
    local single_run="${1:-false}"  # If true, run once and return (for "All Security Features")

    while true; do
        print_section "SSL/TLS Certificate Management"

        # Check if certificates directory exists
        if [[ ! -d /opt/nginx/certs ]]; then
            mkdir -p /opt/nginx/certs
            chown root:root /opt/nginx/certs
            chmod 755 /opt/nginx/certs
        fi

        while true; do
            printf '%s\n' "${CYAN}Certificate Management Options:${NC}"
            printf '  0) Return to Main Menu%s\n' "$NC"
            printf '  1) Generate Self-Signed Certificate (for testing)%s\n' "$NC"
            printf '  2) Setup Let'\''s Encrypt Certificate (includes auto-renewal option)%s\n' "$NC"
            printf '  3) Import Existing Certificate%s\n' "$NC"
            printf '  4) View Certificate Status%s\n' "$NC"
            printf '  5) Setup Auto-Renewal (cron job for existing certificates)%s\n' "$NC"
            printf '  6) Fix Broken Renewal Configuration%s\n' "$NC"
            printf '  7) Regenerate HTTPS Configuration (fix health check)%s\n' "$NC"

            read -rp "$(printf '%s' "${CYAN}Enter choice (0-7): ${NC}")" CERT_CHOICE
            case $CERT_CHOICE in
                0)
                    print_info "Returning to main menu..."
                    return 0
                    ;;
                1) generate_self_signed_cert; break ;;
                2) setup_letsencrypt; break ;;
                3) import_certificate; break ;;
                4) view_certificate_status; break ;;
                5) setup_auto_renewal; break ;;
                6) fix_renewal_configurations; break ;;
                7) regenerate_https_config; break ;;
                *)
                    print_error "Invalid choice. Please enter 0-7."
                    continue
                    ;;
            esac
        done

        # If single_run mode (called from "All Security Features"), exit after one task
        if [[ "$single_run" == "true" ]]; then
            return 0
        fi

        # Ask if user wants to continue
        echo
        read -rp "$(printf '%s' "${CYAN}Would you like to perform another certificate management task? (y/n): ${NC}")" ANOTHER_CERT_CHOICE
        if [[ ! "$ANOTHER_CERT_CHOICE" =~ ^[Yy]$ ]]; then
            print_info "Exiting Nginx certificate management setup..."
            return 0
        fi
        echo
    done
}

# --- Generate Self-Signed Certificate ---
generate_self_signed_cert() {
    print_info "Generating self-signed certificate for testing..."

    # Get domain information
    read -rp "$(printf '%s' "${CYAN}Enter domain name (e.g., localhost): ${NC}")" DOMAIN
    DOMAIN=${DOMAIN:-localhost}

    # Certificate configuration
    cat > /opt/nginx/certs/cert.conf << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
C = DE
ST = Bayern
L = Nuremberg
O = netcup Server
OU = IT Department
CN = $DOMAIN

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = www.$DOMAIN
IP.1 = 127.0.0.1
EOF

    # Generate private key and certificate
    if openssl genrsa -out /opt/nginx/certs/key.pem 2048 && \
       openssl req -new -x509 -key /opt/nginx/certs/key.pem \
       -out /opt/nginx/certs/cert.pem \
       -days 365 \
       -config /opt/nginx/certs/cert.conf; then

        # Set proper permissions
        chmod 600 /opt/nginx/certs/key.pem
        chmod 644 /opt/nginx/certs/cert.pem
        chown root:root /opt/nginx/certs/key.pem
        chown root:root /opt/nginx/certs/cert.pem

        print_success "Self-signed certificate generated successfully."
        print_info "Certificate: /opt/nginx/certs/cert.pem"
        print_info "Private key: /opt/nginx/certs/key.pem"
        print_warning "This certificate is for testing only. Browsers will show security warnings."

        # Update nginx configuration for HTTPS
        update_nginx_https_config "$DOMAIN"

        log "Self-signed certificate generated for $DOMAIN"
    else
        print_error "Failed to generate self-signed certificate."
        return 1
    fi
}

# --- Setup Let's Encrypt Certificate ---
setup_letsencrypt() {
    print_info "Setting up Let's Encrypt certificate..."

    # Check if certbot is installed
    if ! command -v certbot >/dev/null 2>&1; then
        print_info "Installing certbot..."
        apt-get update -qq
        # Install certbot without nginx plugin to avoid system nginx installation
        # We use standalone mode which doesn't need nginx integration
        apt-get install -y certbot
    fi

    # Get domain information
    read -rp "$(printf '%s' "${CYAN}Enter domain name: ${NC}")" DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        print_error "Domain name is required."
        return 1
    fi

    # Check if certificate already exists for this domain
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        print_warning "Certificate already exists for $DOMAIN"
        print_info "Certificate directory: /etc/letsencrypt/live/$DOMAIN"

        if ! confirm "A certificate for $DOMAIN already exists. Do you want to generate a new one anyway?"; then
            print_info "Skipping certificate generation."
            print_info "You can use the existing certificate or select 'Fix Broken Renewal Configuration' to fix renewal issues."
            return 0
        fi

        print_warning "Generating a new certificate will create a new renewal configuration file."
        print_warning "Certbot may add a suffix like -0001 to avoid conflicts."
    fi

    # Get email for renewal notices
    read -rp "$(printf '%s' "${CYAN}Enter email for renewal notices: ${NC}")" EMAIL
    if [[ -z "$EMAIL" ]]; then
        print_error "Email address is required."
        return 1
    fi

    # Check if DNS is configured
    if ! dig +short "$DOMAIN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        print_warning "Domain $DOMAIN does not resolve to this server's IP."
        print_info "Please ensure DNS is properly configured before proceeding."
        if ! confirm "Continue anyway?"; then
            return 1
        fi
    fi

    # Stop nginx to free up port 80
    NGINX_STOPPED=false
    NGINX_TYPE=""

    # Check if system nginx is running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        print_info "Temporarily stopping system Nginx service..."
        systemctl stop nginx
        NGINX_STOPPED=true
        NGINX_TYPE="system"
    # Check if Docker nginx is running
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
        print_info "Temporarily stopping Nginx container..."
        cd /opt/nginx && docker compose stop
        NGINX_STOPPED=true
        NGINX_TYPE="docker"
    fi

    # Generate certificate
    print_info "Generating Let's Encrypt certificate for $DOMAIN..."
    if certbot certonly --standalone \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$DOMAIN" \
        -d "www.$DOMAIN" \
        --rsa-key-size 4096; then

        # Copy certificates to nginx directory
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /opt/nginx/certs/cert.pem
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /opt/nginx/certs/key.pem

        # Set proper permissions
        chmod 600 /opt/nginx/certs/key.pem
        chmod 644 /opt/nginx/certs/cert.pem
        chown root:root /opt/nginx/certs/key.pem
        chown root:root /opt/nginx/certs/cert.pem

        print_success "Let's Encrypt certificate generated successfully."

        # Create renewal hook script (needed before configuring renewal)
        cat > /opt/nginx/certs/renewal_hook.sh << 'EOF'
#!/bin/bash
# Certificate renewal hook for Nginx

# Copy renewed certificates
DOMAIN=$RENEWED_DOMAINS
if [[ -n "$DOMAIN" ]]; then
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /opt/nginx/certs/cert.pem
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /opt/nginx/certs/key.pem

    # Set proper permissions
    chmod 600 /opt/nginx/certs/key.pem
    chmod 644 /opt/nginx/certs/cert.pem
    chown root:root /opt/nginx/certs/key.pem
    chown root:root /opt/nginx/certs/cert.pem

    # Reload Nginx - check if it's system or Docker
    if systemctl is-active --quiet nginx 2>/dev/null; then
        # System nginx
        systemctl reload nginx
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
        # Docker nginx
        cd /opt/nginx && docker compose exec nginx nginx -s reload
    fi

    echo "Certificate renewed for $DOMAIN at $(date)"
fi
EOF

        chmod +x /opt/nginx/certs/renewal_hook.sh

        # Update nginx configuration for HTTPS
        update_nginx_https_config "$DOMAIN"

        # Setup auto-renewal configuration
        setup_certbot_renewal "$DOMAIN"

        # Normalize renewal configuration file name (remove suffix)
        if normalize_renewal_config "$DOMAIN"; then
            print_success "Normalized renewal configuration file name."
        fi

        # Fix any broken renewal configurations
        print_info "Checking for broken renewal configurations..."
        local fixed_count=0
        for renewal_file in /etc/letsencrypt/renewal/${DOMAIN}*.conf; do
            if [[ -f "$renewal_file" ]]; then
                local domain_name=$(basename "$renewal_file" .conf)
                if fix_broken_renewal_config "$domain_name"; then
                    ((fixed_count++))
                fi
            fi
        done

        if [[ $fixed_count -gt 0 ]]; then
            print_success "Fixed $fixed_count broken renewal configuration(s)."
        fi

        # Restart nginx
        if [[ "$NGINX_STOPPED" == "true" ]]; then
            if [[ "$NGINX_TYPE" == "system" ]]; then
                print_info "Restarting system Nginx service..."
                systemctl start nginx
            elif [[ "$NGINX_TYPE" == "docker" ]]; then
                print_info "Restarting Nginx container..."
                cd /opt/nginx && docker compose start
            fi
        fi

        # Offer to set up auto-renewal cron job
        if confirm "Would you like to set up automatic certificate renewal (cron job)?"; then
            print_info "Setting up auto-renewal cron job..."
            setup_auto_renewal_cron
        else
            print_info "Auto-renewal cron job not set up. You can set it up later by selecting 'Setup Auto-Renewal' option."
        fi

        log "Let's Encrypt certificate generated for $DOMAIN"
    else
        print_error "Failed to generate Let's Encrypt certificate."
        # Restart nginx if it was stopped
        if [[ "$NGINX_STOPPED" == "true" ]]; then
            if [[ "$NGINX_TYPE" == "system" ]]; then
                print_info "Restarting system Nginx service..."
                systemctl start nginx
            elif [[ "$NGINX_TYPE" == "docker" ]]; then
                print_info "Restarting Nginx container..."
                cd /opt/nginx && docker compose start
            fi
        fi
        return 1
    fi
}

# --- Import Existing Certificate ---
import_certificate() {
    print_info "Importing existing SSL certificate..."

    # Get certificate file path
    read -rp "$(printf '%s' "${CYAN}Enter path to certificate file (.crt or .pem): ${NC}")" CERT_FILE
    if [[ ! -f "$CERT_FILE" ]]; then
        print_error "Certificate file not found: $CERT_FILE"
        return 1
    fi

    # Get private key file path
    read -rp "$(printf '%s' "${CYAN}Enter path to private key file (.key): ${NC}")" KEY_FILE
    if [[ ! -f "$KEY_FILE" ]]; then
        print_error "Private key file not found: $KEY_FILE"
        return 1
    fi

    # Validate certificate and key
    if ! openssl x509 -in "$CERT_FILE" -text -noout >/dev/null 2>&1; then
        print_error "Invalid certificate file."
        return 1
    fi

    if ! openssl rsa -in "$KEY_FILE" -check >/dev/null 2>&1; then
        print_error "Invalid private key file."
        return 1
    fi

    # Copy certificates
    cp "$CERT_FILE" /opt/nginx/certs/cert.pem
    cp "$KEY_FILE" /opt/nginx/certs/key.pem

    # Set proper permissions
    chmod 600 /opt/nginx/certs/key.pem
    chmod 644 /opt/nginx/certs/cert.pem
    chown root:root /opt/nginx/certs/key.pem
    chown root:root /opt/nginx/certs/cert.pem

    # Extract domain from certificate
    DOMAIN=$(openssl x509 -in /opt/nginx/certs/cert.pem -noout -subject | sed -n 's/.*CN=\([^,]*\).*/\1/p')
    DOMAIN=${DOMAIN:-unknown}

    print_success "Certificate imported successfully."
    print_info "Domain: $DOMAIN"
    print_info "Certificate: /opt/nginx/certs/cert.pem"
    print_info "Private key: /opt/nginx/certs/key.pem"

    # Update nginx configuration for HTTPS
    update_nginx_https_config "$DOMAIN"

    log "Certificate imported for $DOMAIN"
}

# --- View Certificate Status ---
view_certificate_status() {
    print_info "Certificate Status:"

    if [[ -f /opt/nginx/certs/cert.pem ]]; then
        print_info "Certificate found: /opt/nginx/certs/cert.pem"

        # Display certificate information
        echo
        printf '%s%s%s\n' "$BOLD" "Certificate Details:" "$NC"
        openssl x509 -in /opt/nginx/certs/cert.pem -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:|DNS:)" | sed 's/^/  /'

        # Check expiration
        EXPIRY_DATE=$(openssl x509 -in /opt/nginx/certs/cert.pem -noout -enddate | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
        CURRENT_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

        echo
        if [[ $DAYS_LEFT -lt 30 ]]; then
            printf '%s%s%s\n' "$RED" "Certificate expires in $DAYS_LEFT days!" "$NC"
            print_warning "Certificate renewal required soon."
        elif [[ $DAYS_LEFT -lt 7 ]]; then
            printf '%s%s%s\n' "$RED" "Certificate expires in $DAYS_LEFT days!" "$NC"
            print_error "Certificate renewal required immediately."
        else
            printf '%s%s%s\n' "$GREEN" "Certificate expires in $DAYS_LEFT days." "$NC"
        fi
    else
        print_info "No certificate found at /opt/nginx/certs/cert.pem"
    fi

    # Check Let's Encrypt certificates
    if [[ -d /etc/letsencrypt/live ]]; then
        echo
        printf '%s%s%s\n' "$BOLD" "Let's Encrypt Certificates:" "$NC"

        # Track domains with duplicates
        declare -A domains_seen
        local has_duplicates=false

        for cert_dir in /etc/letsencrypt/live/*; do
            if [[ -d "$cert_dir" ]]; then
                local domain=$(basename "$cert_dir")
                local base_domain="${domain%%-[0-9]*}"

                # Check if this is a duplicate (suffixed) certificate
                if [[ "$domain" =~ ^.+-[0-9]+$ ]]; then
                    # Mark that we have duplicates for this base domain
                    domains_seen["$base_domain"]="has_duplicates"
                    has_duplicates=true
                fi

                # Only display base domains (not suffixed ones)
                if [[ ! "$domain" =~ ^.+-[0-9]+$ ]]; then
                    if [[ -f "$cert_dir/fullchain.pem" ]]; then
                        expiry=$(openssl x509 -in "$cert_dir/fullchain.pem" -noout -enddate | cut -d= -f2)
                        expiry_epoch=$(date -d "$expiry" +%s)
                        days_left=$(( (expiry_epoch - CURRENT_EPOCH) / 86400 ))

                        if [[ $days_left -lt 30 ]]; then
                            printf '  %s: %s%s days%s (renewal needed)\n' "$domain" "$RED" "$days_left" "$NC"
                        else
                            printf '  %s: %s%d days%s\n' "$domain" "$GREEN" "$days_left" "$NC"
                        fi
                    fi
                fi
            fi
        done

        # Display warning about duplicates
        if [[ "$has_duplicates" == "true" ]]; then
            echo
            printf '%s%s%s\n' "$YELLOW" "⚠ WARNING: Duplicate certificate directories detected!" "$NC"
            printf '%s%s%s\n' "$YELLOW" "  This can happen when certificates are requested multiple times." "$NC"
            printf '%s%s%s\n' "$YELLOW" "  Run option 6 (Fix Broken Renewal Configuration) to clean up duplicates." "$NC"

            # List the domains with duplicates
            echo
            printf '%s%s%s\n' "$BOLD" "Domains with duplicate certificates:" "$NC"
            for domain in "${!domains_seen[@]}"; do
                if [[ "${domains_seen[$domain]}" == "has_duplicates" ]]; then
                    printf '  - %s\n' "$domain"
                fi
            done
        fi
    fi
}

# --- Setup Auto-Renewal Cron Job ---
setup_auto_renewal_cron() {
    print_info "Setting up certificate auto-renewal cron job..."

    # Ensure renewal hook script exists
    if [[ ! -f /opt/nginx/certs/renewal_hook.sh ]]; then
        print_info "Creating renewal hook script..."
        cat > /opt/nginx/certs/renewal_hook.sh << 'EOF'
#!/bin/bash
# Certificate renewal hook for Nginx

# Copy renewed certificates
DOMAIN=$RENEWED_DOMAINS
if [[ -n "$DOMAIN" ]]; then
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /opt/nginx/certs/cert.pem
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /opt/nginx/certs/key.pem

    # Set proper permissions
    chmod 600 /opt/nginx/certs/key.pem
    chmod 644 /opt/nginx/certs/cert.pem
    chown root:root /opt/nginx/certs/key.pem
    chown root:root /opt/nginx/certs/cert.pem

    # Reload Nginx - check if it's system or Docker
    if systemctl is-active --quiet nginx 2>/dev/null; then
        # System nginx
        systemctl reload nginx
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
        # Docker nginx
        cd /opt/nginx && docker compose exec nginx nginx -s reload
    fi

    echo "Certificate renewed for $DOMAIN at $(date)"
fi
EOF

        chmod +x /opt/nginx/certs/renewal_hook.sh
    fi

    # Setup cron job for renewal
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet --post-hook '/opt/nginx/certs/renewal_hook.sh'") | crontab -
        print_success "Auto-renewal cron job created."
    else
        print_info "Auto-renewal cron job already exists."
    fi

    # Check and fix broken renewal configurations
    print_info "Checking renewal configurations..."
    local fixed_configs=0
    for renewal_file in /etc/letsencrypt/renewal/*.conf; do
        if [[ -f "$renewal_file" ]]; then
            local domain=$(basename "$renewal_file" .conf)
            if fix_broken_renewal_config "$domain"; then
                ((fixed_configs++))
            fi
        fi
    done

    if [[ $fixed_configs -gt 0 ]]; then
        print_success "Fixed $fixed_configs broken renewal configuration(s)."
    fi

    # Test renewal configuration
    print_info "Testing renewal configuration..."

    # Stop nginx temporarily for dry-run test
    local nginx_was_running=false
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl stop nginx
        nginx_was_running=true
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
        cd /opt/nginx && docker compose stop
        nginx_was_running=true
    fi

    if certbot renew --dry-run; then
        print_success "Auto-renewal setup completed successfully."
    else
        print_warning "Renewal test failed. Please check configuration."
        return 1
    fi

    # Restart nginx if it was running
    if [[ "$nginx_was_running" == "true" ]]; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl start nginx
        elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
            cd /opt/nginx && docker compose start
        fi
    fi
}

# --- Fix All Broken Renewal Configurations ---
fix_renewal_configurations() {
    print_info "Checking and fixing broken renewal configurations..."

    local total_configs=0
    local fixed_configs=0
    local skipped_configs=0
    local normalized_configs=0

    # Check if renewal directory exists
    if [[ ! -d /etc/letsencrypt/renewal ]]; then
        print_warning "No renewal configurations found."
        print_info "This is normal if you haven't generated any Let's Encrypt certificates yet."
        print_success "Certificate renewal configuration check completed."
        echo
        return 0
    fi

    # Enable nullglob so that globs with no matches expand to nothing
    local restore_nullglob=false
    if shopt -q nullglob; then
        restore_nullglob=true
    else
        shopt -s nullglob || true
    fi

    # First, normalize configuration file names (remove suffixes)
    print_info "Normalizing renewal configuration file names..."
    local found_configs=false

    for renewal_file in /etc/letsencrypt/renewal/*.conf; do
        if [[ -f "$renewal_file" ]]; then
            found_configs=true
            local filename=$(basename "$renewal_file")
            # Check if this is a suffixed configuration (e.g., domain-0001.conf)
            if [[ "$filename" =~ ^(.+)-[0-9]+\.conf$ ]]; then
                local domain="${BASH_REMATCH[1]}"
                if normalize_renewal_config "$domain"; then
                    normalized_configs=$((normalized_configs + 1))
                fi
            fi
        fi
    done

    if [[ "$found_configs" == "false" ]]; then
        print_info "No renewal configuration files found in /etc/letsencrypt/renewal/"
        print_success "Certificate renewal configuration check completed."
        echo

        # Restore nullglob setting if we changed it
        if [[ "$restore_nullglob" == "false" ]]; then
            shopt -u nullglob || true
        fi
        return 0
    fi

    if [[ $normalized_configs -gt 0 ]]; then
        print_success "Normalized $normalized_configs renewal configuration file name(s)."
    fi

    # Check for and remove duplicate certificate directories
    print_info "Checking for duplicate certificate directories..."
    local domains_with_duplicates=()

    # Collect all unique base domains
    declare -A seen_domains
    for cert_dir in /etc/letsencrypt/live/*; do
        if [[ -d "$cert_dir" ]]; then
            local domain=$(basename "$cert_dir")
            # Extract base domain name (remove suffix if present)
            local base_domain="${domain%%-[0-9]*}"

            # Skip if this is already a suffixed domain
            if [[ "$domain" =~ ^.+-[0-9]+$ ]]; then
                continue
            fi

            # Check if this domain has duplicates
            if [[ -d "$cert_dir" ]]; then
                local has_duplicates=false
                for dup_dir in /etc/letsencrypt/live/${base_domain}-*; do
                    if [[ -d "$dup_dir" ]]; then
                        has_duplicates=true
                        break
                    fi
                done

                if [[ "$has_duplicates" == "true" ]]; then
                    domains_with_duplicates+=("$base_domain")
                fi
            fi
        fi
    done

    # Remove duplicates for each domain
    local total_duplicates_removed=0
    for domain in "${domains_with_duplicates[@]}"; do
        if remove_duplicate_certs "$domain" "false"; then
            # Count how many were removed by checking the log or counting remaining
            local remaining=0
            for dup_dir in /etc/letsencrypt/live/${domain}-*; do
                if [[ -d "$dup_dir" ]]; then
                    ((remaining++))
                fi
            done
            # We can't easily count exact removals here, but we know we attempted
        fi
    done

    if [[ ${#domains_with_duplicates[@]} -gt 0 ]]; then
        print_success "Checked ${#domains_with_duplicates[@]} domain(s) for duplicate certificates."
    fi

    # Now check for broken configurations
    local found_any_configs=false

    for renewal_file in /etc/letsencrypt/renewal/*.conf; do
        if [[ -f "$renewal_file" ]]; then
            found_any_configs=true
            total_configs=$((total_configs + 1))
            local domain=$(basename "$renewal_file" .conf)

            # Check if the config is broken
            if ! grep -q "^cert = " "$renewal_file" || \
               ! grep -q "^privkey = " "$renewal_file" || \
               ! grep -q "^chain = " "$renewal_file" || \
               ! grep -q "^fullchain = " "$renewal_file"; then

                print_warning "Found broken renewal configuration for $domain"

                # Check if there's a backup configuration
                local backup_conf="/etc/letsencrypt/renewal/$domain.conf.backup"
                if [[ -f "$backup_conf" ]]; then
                    print_info "Restoring from backup..."
                    cp "$backup_conf" "$renewal_file"
                    fixed_configs=$((fixed_configs + 1))
                    print_success "Restored configuration for $domain from backup."
                else
                    print_info "Removing broken configuration (no backup available)..."
                    rm -f "$renewal_file"
                    fixed_configs=$((fixed_configs + 1))
                    print_info "Removed broken configuration for $domain. Certbot will regenerate it."
                fi
            else
                skipped_configs=$((skipped_configs + 1))
            fi
        fi
    done

    # Restore nullglob setting if we changed it
    if [[ "$restore_nullglob" == "false" ]]; then
        shopt -u nullglob || true
    fi

    if [[ "$found_any_configs" == "false" ]]; then
        print_info "No renewal configuration files found in /etc/letsencrypt/renewal/"
        print_success "Certificate renewal configuration check completed."
        echo
        return 0
    fi

    echo
    if [[ $total_configs -eq 0 ]]; then
        print_info "No renewal configurations found."
        print_success "Certificate renewal configuration check completed."
    elif [[ $fixed_configs -eq 0 && $normalized_configs -eq 0 ]]; then
        print_success "All $total_configs renewal configuration(s) are valid."
        print_info "No fixes were needed."
        print_success "Certificate renewal configuration check completed."
    else
        print_success "Fixed $fixed_configs out of $total_configs renewal configuration(s)."
        print_info "Skipped $skipped_configs valid configuration(s)."

        # Test renewal after fixing
        echo
        if confirm "Would you like to test the renewal configuration now?"; then
            print_info "Testing renewal configuration..."

            # Stop nginx temporarily for dry-run test
            local nginx_was_running=false
            if systemctl is-active --quiet nginx 2>/dev/null; then
                systemctl stop nginx
                nginx_was_running=true
            elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
                cd /opt/nginx && docker compose stop
                nginx_was_running=true
            fi

            if certbot renew --dry-run; then
                print_success "Renewal test passed successfully."
            else
                print_warning "Renewal test failed. Please check configuration."
            fi

            # Restart nginx if it was running
            if [[ "$nginx_was_running" == "true" ]]; then
                if systemctl is-active --quiet nginx 2>/dev/null; then
                    systemctl start nginx
                elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
                    cd /opt/nginx && docker compose start
                fi
            fi
        fi
    fi

    log "Renewal configuration check completed: $fixed_configs fixed, $normalized_configs normalized, $skipped_configs valid"

    print_success "Certificate renewal configuration check completed."
    echo
}

# --- Setup Auto-Renewal (standalone option) ---
setup_auto_renewal() {
    print_info "Setting up certificate auto-renewal..."

    # Check if certbot is installed
    if ! command -v certbot >/dev/null 2>&1; then
        print_info "Certbot is not installed. Installing certbot..."
        apt-get update -qq
        # Install certbot without nginx plugin to avoid system nginx installation
        if apt-get install -y certbot; then
            print_success "Certbot installed successfully."
        else
            print_error "Failed to install certbot. Cannot setup auto-renewal."
            return 1
        fi
    fi

    # Check if Let's Encrypt certificates exist
    if [[ ! -d /etc/letsencrypt/live ]]; then
        print_warning "No Let's Encrypt certificates found."
        print_info "Please select 'Setup Let's Encrypt Certificate' first to generate certificates."
        return 1
    fi

    # Call the cron job setup function
    setup_auto_renewal_cron
}

# --- Fix Broken Renewal Configuration ---
fix_broken_renewal_config() {
    local domain="$1"
    local complete_conf=""
    local incomplete_confs=()

    # Find all renewal configuration files for this domain
    for config_file in /etc/letsencrypt/renewal/${domain}*.conf; do
        if [[ -f "$config_file" ]]; then
            # Check if this configuration is complete (has required file references)
            if grep -q "^cert = " "$config_file" && \
               grep -q "^privkey = " "$config_file" && \
               grep -q "^chain = " "$config_file" && \
               grep -q "^fullchain = " "$config_file"; then
                complete_conf="$config_file"
            else
                incomplete_confs+=("$config_file")
            fi
        fi
    done

    # If we found a complete configuration, remove all incomplete ones
    if [[ -n "$complete_conf" ]]; then
        for broken_conf in "${incomplete_confs[@]}"; do
            print_warning "Removing incomplete renewal configuration: $(basename "$broken_conf")"
            rm -f "$broken_conf"
        done
        return 0
    elif [[ ${#incomplete_confs[@]} -gt 0 ]]; then
        # No complete configuration found, but there are incomplete ones
        print_warning "Found incomplete renewal configuration(s) for $domain"
        print_info "Removing incomplete configuration(s)..."

        for broken_conf in "${incomplete_confs[@]}"; do
            rm -f "$broken_conf"
        done

        print_info "Incomplete configuration(s) removed. Certbot will regenerate it on next renewal."
        return 0
    fi

    return 1
}

# --- Normalize Renewal Configuration File Name ---
normalize_renewal_config() {
    local domain="$1"
    local base_conf="/etc/letsencrypt/renewal/${domain}.conf"
    local suffixed_conf=""

    # Check if base configuration exists and is complete
    if [[ -f "$base_conf" ]] && \
       grep -q "^cert = " "$base_conf" && \
       grep -q "^privkey = " "$base_conf" && \
       grep -q "^chain = " "$base_conf" && \
       grep -q "^fullchain = " "$base_conf"; then
        # Base configuration is complete, no action needed
        return 0
    fi

    # Find the suffixed configuration (e.g., -0001, -0002)
    for config_file in /etc/letsencrypt/renewal/${domain}-*.conf; do
        if [[ -f "$config_file" ]]; then
            # Check if this configuration is complete
            if grep -q "^cert = " "$config_file" && \
               grep -q "^privkey = " "$config_file" && \
               grep -q "^chain = " "$config_file" && \
               grep -q "^fullchain = " "$config_file"; then
                suffixed_conf="$config_file"
                break
            fi
        fi
    done

    if [[ -n "$suffixed_conf" ]]; then
        # Remove incomplete base configuration if it exists
        if [[ -f "$base_conf" ]]; then
            print_info "Removing incomplete base configuration: $(basename "$base_conf")"
            rm -f "$base_conf"
        fi

        # Rename suffixed configuration to base name
        print_info "Renaming $(basename "$suffixed_conf") to ${domain}.conf"
        mv "$suffixed_conf" "$base_conf"
        log "Normalized renewal configuration: ${domain}.conf"
        return 0
    fi

    return 1
}

# --- Detect Duplicate Certificates ---
detect_duplicate_certs() {
    local domain="$1"
    local duplicates=()
    local base_cert="/etc/letsencrypt/live/$domain"

    # Check if base certificate directory exists
    if [[ ! -d "$base_cert" ]]; then
        return 1
    fi

    # Find all suffixed certificate directories for this domain
    for cert_dir in /etc/letsencrypt/live/${domain}-*; do
        if [[ -d "$cert_dir" ]]; then
            local cert_name=$(basename "$cert_dir")
            # Check if it matches the pattern domain-XXXX where XXXX are digits
            if [[ "$cert_name" =~ ^${domain}-[0-9]+$ ]]; then
                duplicates+=("$cert_dir")
            fi
        fi
    done

    # Return the list of duplicates
    printf '%s\n' "${duplicates[@]}"
}

# --- Remove Duplicate Certificate Directories ---
remove_duplicate_certs() {
    local domain="$1"
    local force="${2:-false}"
    local removed_count=0

    print_info "Checking for duplicate certificate directories for $domain..."

    # Get list of duplicate certificates
    local duplicates=()
    while IFS= read -r cert_dir; do
        duplicates+=("$cert_dir")
    done < <(detect_duplicate_certs "$domain")

    if [[ ${#duplicates[@]} -eq 0 ]]; then
        print_info "No duplicate certificate directories found for $domain."
        return 0
    fi

    echo
    printf '%s%s%s\n' "$BOLD" "Found ${#duplicates[@]} duplicate certificate directory(s):" "$NC"
    for dup in "${duplicates[@]}"; do
        local dup_name=$(basename "$dup")
        printf '  - %s\n' "$dup_name"
    done
    echo

    # Check which one is currently in use
    local current_cert=""
    if [[ -f /opt/nginx/certs/cert.pem ]]; then
        # Get the certificate serial number of the current cert
        local current_serial=$(openssl x509 -in /opt/nginx/certs/cert.pem -noout -serial 2>/dev/null | cut -d= -f2)

        # Check which certificate matches the current serial
        for cert_dir in "${duplicates[@]}" "/etc/letsencrypt/live/$domain"; do
            if [[ -f "$cert_dir/fullchain.pem" ]]; then
                local cert_serial=$(openssl x509 -in "$cert_dir/fullchain.pem" -noout -serial 2>/dev/null | cut -d= -f2)
                if [[ "$cert_serial" == "$current_serial" ]]; then
                    current_cert="$cert_dir"
                    break
                fi
            fi
        done
    fi

    # If no current cert found, assume the base cert is in use
    if [[ -z "$current_cert" && -d "/etc/letsencrypt/live/$domain" ]]; then
        current_cert="/etc/letsencrypt/live/$domain"
    fi

    if [[ -n "$current_cert" ]]; then
        printf '%s%s%s\n' "$GREEN" "Currently in use:" "$NC"
        printf '  %s\n' "$(basename "$current_cert")"
        echo
    fi

    # Ask for confirmation unless force is true
    if [[ "$force" != "true" ]]; then
        if ! confirm "Do you want to remove the duplicate certificate directories?"; then
            print_info "Skipping duplicate certificate removal."
            return 0
        fi
    fi

    # Remove duplicate directories
    for dup in "${duplicates[@]}"; do
        local dup_name=$(basename "$dup")

        # Don't remove the currently used certificate
        if [[ "$dup" == "$current_cert" ]]; then
            print_warning "Skipping $dup_name (currently in use)"
            continue
        fi

        # Check if there's a corresponding archive directory
        local archive_dir="/etc/letsencrypt/archive/$dup_name"

        # Remove the live directory (which is a symlink)
        if [[ -L "$dup" ]]; then
            print_info "Removing symlink: $dup_name"
            rm -f "$dup"
            ((removed_count++))
        elif [[ -d "$dup" ]]; then
            print_warning "Removing directory: $dup_name"
            rm -rf "$dup"
            ((removed_count++))
        fi

        # Remove the archive directory
        if [[ -d "$archive_dir" ]]; then
            print_info "Removing archive: $dup_name"
            rm -rf "$archive_dir"
        fi

        # Remove the renewal configuration file
        local renewal_conf="/etc/letsencrypt/renewal/$dup_name.conf"
        if [[ -f "$renewal_conf" ]]; then
            print_info "Removing renewal configuration: $dup_name.conf"
            rm -f "$renewal_conf"
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        print_success "Removed $removed_count duplicate certificate directory(ies)."
        log "Removed $removed_count duplicate certificate directories for $domain"
    else
        print_info "No duplicate certificates were removed."
    fi

    return 0
}

# --- Setup Certbot Renewal ---
setup_certbot_renewal() {
    local domain="$1"
    local renewal_conf=""
    local found_config=false

    # Find the actual renewal configuration file created by certbot
    # Certbot may create files with suffixes like -0001, -0002 for duplicate requests
    for config_file in /etc/letsencrypt/renewal/${domain}*.conf; do
        if [[ -f "$config_file" ]]; then
            # Check if this configuration is complete (has required file references)
            if grep -q "^cert = " "$config_file" && \
               grep -q "^privkey = " "$config_file" && \
               grep -q "^chain = " "$config_file" && \
               grep -q "^fullchain = " "$config_file"; then
                renewal_conf="$config_file"
                found_config=true
                break
            fi
        fi
    done

    if [[ "$found_config" == "true" ]]; then
        local config_name=$(basename "$renewal_conf")
        print_info "Found certbot renewal configuration: $config_name"

        # Update existing configuration - add or update post_hook in [renewalparams]
        if grep -q "^\[renewalparams\]" "$renewal_conf"; then
            # Check if post_hook already exists
            if grep -q "^post_hook" "$renewal_conf"; then
                # Update existing post_hook
                sed -i 's|^post_hook.*|post_hook = /opt/nginx/certs/renewal_hook.sh|' "$renewal_conf"
                print_info "Updated post_hook in renewal configuration."
            else
                # Add post_hook after [renewalparams]
                sed -i '/^\[renewalparams\]/a post_hook = /opt/nginx/certs/renewal_hook.sh' "$renewal_conf"
                print_info "Added post_hook to renewal configuration."
            fi

            # Ensure authenticator is set to standalone
            if grep -q "^authenticator" "$renewal_conf"; then
                sed -i 's|^authenticator.*|authenticator = standalone|' "$renewal_conf"
            else
                sed -i '/^\[renewalparams\]/a authenticator = standalone' "$renewal_conf"
            fi
        else
            # Add [renewalparams] section if it doesn't exist
            cat >> "$renewal_conf" << EOF

[renewalparams]
authenticator = standalone
post_hook = /opt/nginx/certs/renewal_hook.sh
EOF
            print_info "Added [renewalparams] section to renewal configuration."
        fi

        # Remove any incomplete renewal configurations for this domain
        for config_file in /etc/letsencrypt/renewal/${domain}*.conf; do
            if [[ -f "$config_file" && "$config_file" != "$renewal_conf" ]]; then
                # Check if this config is incomplete (missing required file references)
                if ! grep -q "^cert = " "$config_file" || \
                   ! grep -q "^privkey = " "$config_file" || \
                   ! grep -q "^chain = " "$config_file" || \
                   ! grep -q "^fullchain = " "$config_file"; then
                    print_warning "Removing incomplete renewal configuration: $(basename "$config_file")"
                    rm -f "$config_file"
                fi
            fi
        done

        log "Updated certbot renewal configuration: $config_name"
    else
        # No complete configuration found - this should not happen if certbot succeeded
        print_error "No certbot renewal configuration found for $domain"
        print_error "This indicates that certbot did not successfully generate a certificate."
        log "Certbot renewal configuration file not found for $domain"
        return 1
    fi
}

# --- Update Nginx HTTPS Configuration ---
update_nginx_https_config() {
    local domain="$1"

    # Determine nginx type
    local nginx_type="docker"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_type="system"
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
        nginx_type="docker"
    fi

    if [[ "$nginx_type" == "system" ]]; then
        # For system nginx, create config in /etc/nginx/
        cat > /etc/nginx/sites-available/https.conf << 'EOF'
# HTTPS configuration for DOMAIN_PLACEHOLDER
server {
    listen 8080;
    server_name https.DOMAIN_PLACEHOLDER www.DOMAIN_PLACEHOLDER;
    return 301 https://$server_name$request_uri;
}

server {
    listen 8443 ssl http2;
    server_name https.DOMAIN_PLACEHOLDER www.DOMAIN_PLACEHOLDER;

    # SSL configuration
    ssl_certificate /opt/nginx/certs/cert.pem;
    ssl_certificate_key /opt/nginx/certs/key.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # Security headers
    include /etc/nginx/conf.d/security-headers.conf 2>/dev/null || {
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
    }

    # Root directory
    root   /var/www/html;
    index  index.html index.htm;

    # Health check endpoint - MUST BE FIRST
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Block access to sensitive files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ ~$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block access to backup files
    location ~* \.(bak|backup|old|orig|save|tmp)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block access to configuration files
    location ~* \.(conf|config|ini|log|sql|sh|py|pl)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Main location
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Nginx status (restricted to localhost)
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
    }

    # Error pages
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
        internal;
    }

    # Logging
    access_log  /var/log/nginx/https_access.log  main;
    error_log   /var/log/nginx/https_error.log warn;
}
EOF

        # Replace DOMAIN_PLACEHOLDER with actual domain
        sed -i "s/DOMAIN_PLACEHOLDER/$domain/g" /etc/nginx/sites-available/https.conf

        # Enable the site
        ln -sf /etc/nginx/sites-available/https.conf /etc/nginx/sites-enabled/https.conf 2>/dev/null || true

        print_success "HTTPS configuration created for $domain."
        print_info "Configuration file: /etc/nginx/sites-available/https.conf"
        print_info "Please reload Nginx to apply changes:"
        print_info "  sudo systemctl reload nginx"
    else
        # For Docker nginx, create config in /opt/nginx/
        cat > /opt/nginx/conf.d/https.conf << 'EOF'
# HTTPS configuration for DOMAIN_PLACEHOLDER
server {
    listen 8080;
    server_name https.DOMAIN_PLACEHOLDER www.DOMAIN_PLACEHOLDER;
    return 301 https://$server_name$request_uri;
}

server {
    listen 8443 ssl http2;
    server_name https.DOMAIN_PLACEHOLDER www.DOMAIN_PLACEHOLDER;

    # SSL configuration
    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # Security headers
    include /etc/nginx/conf.d/security-headers.conf;

    # Root directory
    root   /usr/share/nginx/html;
    index  index.html index.htm;

    # Health check endpoint - MUST BE FIRST
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Block access to sensitive files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ ~$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block access to backup files
    location ~* \.(bak|backup|old|orig|save|tmp)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block access to configuration files
    location ~* \.(conf|config|ini|log|sql|sh|py|pl)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Main location
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Nginx status (restricted to localhost)
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
    }

    # Error pages
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
        internal;
    }

    # Logging
    access_log  /var/log/nginx/https_access.log  main;
    error_log   /var/log/nginx/https_error.log warn;
}
EOF

        # Replace DOMAIN_PLACEHOLDER with actual domain
        sed -i "s/DOMAIN_PLACEHOLDER/$domain/g" /opt/nginx/conf.d/https.conf

        print_success "HTTPS configuration created for $domain."
        print_info "Configuration file: /opt/nginx/conf.d/https.conf"
        print_info "Please reload Nginx to apply changes:"
        print_info "  cd /opt/nginx && docker compose exec nginx nginx -s reload"
    fi
}

# --- Regenerate HTTPS Configuration ---
regenerate_https_config() {
    print_info "Regenerating HTTPS configuration with health check fix..."

    # Check if certificate exists
    if [[ ! -f /opt/nginx/certs/cert.pem ]]; then
        print_error "No certificate found at /opt/nginx/certs/cert.pem"
        print_info "Please generate a certificate first (options 1-3)."
        return 1
    fi

    # Extract domain from certificate
    DOMAIN=$(openssl x509 -in /opt/nginx/certs/cert.pem -noout -subject | sed -n 's/.*CN=\([^,]*\).*/\1/p')
    DOMAIN=${DOMAIN:-unknown}

    print_info "Domain detected: $DOMAIN"

    # Backup current config
    if [[ -f /opt/nginx/conf.d/https.conf ]]; then
        cp /opt/nginx/conf.d/https.conf /opt/nginx/conf.d/https.conf.backup.$(date +%Y%m%d_%H%M%S)
        print_info "Backup created: https.conf.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Create fixed https.conf
    print_info "Creating fixed https.conf..."
    cat > /opt/nginx/conf.d/https.conf << EOF
# HTTPS configuration for $DOMAIN
server {
    listen 8080;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 8443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    # Security settings - Rate limiting enabled
    limit_req zone=general burst=40 nodelay;
    limit_conn conn_limit_per_ip 10;

    # SSL configuration
    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # Security headers
    include /etc/nginx/conf.d/security-headers.conf;

    # Root directory
    root   /usr/share/nginx/html;
    index  index.html index.htm;

    # Health check endpoint - MUST BE FIRST
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Block access to sensitive files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ ~$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block access to backup files
    location ~* \.(bak|backup|old|orig|save|tmp)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block access to configuration files
    location ~* \.(conf|config|ini|log|sql|sh|py|pl)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Main location
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Nginx status (restricted to localhost)
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
    }

    # Error pages
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
        internal;
    }

    # Logging
    access_log  /var/log/nginx/https_access.log  main;
    error_log   /var/log/nginx/https_error.log warn;
}
EOF

    # Test configuration
    print_info "Testing nginx configuration..."
    if docker exec nginx nginx -t; then
        print_success "Configuration test passed"

        # Reload nginx
        print_info "Reloading nginx..."
        docker exec nginx nginx -s reload
        print_success "Nginx reloaded"

        # Verify health check
        print_info "Verifying health check..."
        if docker exec nginx curl -f http://localhost:8080/health; then
            print_success "Health check successful"
        else
            print_warning "Health check failed"
            print_info "Checking logs..."
            docker logs nginx --tail 20
        fi

        print_success "HTTPS configuration regenerated successfully."
        log "HTTPS configuration regenerated for $DOMAIN"
    else
        print_error "Configuration test failed"
        print_info "Restoring backup..."
        # Find the most recent backup
        local latest_backup=$(ls -t /opt/nginx/conf.d/https.conf.backup.* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            cp "$latest_backup" /opt/nginx/conf.d/https.conf
            docker exec nginx nginx -s reload
            print_info "Backup restored from: $latest_backup"
        else
            print_warning "No backup found to restore"
        fi
        return 1
    fi
}