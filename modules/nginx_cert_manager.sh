#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Nginx Certificate Management Module
# Handles SSL/TLS certificate generation, renewal, and management
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# Let's Encrypt Staging Flag
CERTBOT_FLAGS=""
if [[ "${LETSENCRYPT_ENVIRONMENT}" == "staging" ]]; then
    CERTBOT_FLAGS="--staging"
    print_warning "Let's Encrypt is in STAGING mode. Certificates will not be trusted by browsers."
fi

# ============================================================================
# Cleanup Functions
# ============================================================================

# Cleanup temporary files on exit
cleanup_temp_files() {
    # Using nullglob locally to prevent literal '*' if no files match
    local temp_files=("/tmp/nginx_cert_*.conf" "/tmp/renewal_hook_*.sh" "/tmp/auto_renewal_*.sh")
    # Find all temporary files created by this script
    for pattern in "${temp_files[@]}"; do
        for file in $pattern; do
            [[ -f "$file" ]] && rm -f "$file"
        done
    done
}
trap cleanup_temp_files EXIT

# ============================================================================
# Input Validation Functions
# ============================================================================

# Validate domain name format
validate_domain() {
    local domain="$1"
    # RFC 1035 compliant regex for domain validation
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        print_error "Invalid domain name: $domain"
        return 1
    fi
    return 0
}

# Validate file path is within allowed directories
validate_file_path() {
    local path="$1"
    # Resolve to absolute path to prevent directory traversal (../)
    local abs_path=$(realpath "$path" 2>/dev/null || echo "$path")
    # Restrict operations to non-system critical paths
    if [[ "$abs_path" != /tmp/* ]] && [[ "$abs_path" != /home/* ]] && [[ "$abs_path" != /opt/* ]]; then
        print_error "Invalid file path: $path (Access restricted to /tmp, /home, or /opt)"
        return 1
    fi
    return 0
}

# Escape special characters for nginx config
escape_nginx_config() {
    local input="$1"
    # Escape backslash, slash, and ampersand for safe use in sed replacement
    echo "$input" | sed 's/[\/&\\]/\\&/g'
}

# ============================================================================
# Certificate Management Functions
# ============================================================================

# --- Certificate Management Function ---
manage_certificates() {
    local single_run="${1:-false}"  # If true, run once and return (for "All Security Features")

    while true; do
        print_section "SSL/TLS Certificate Management"

        # Ensure certificates directory exists
        if [[ ! -d /opt/nginx/certs ]]; then
            mkdir -p /opt/nginx/certs
            # Root owns the dir, but 101 needs to read files inside
            chown root:root /opt/nginx/certs
            chmod 755 /opt/nginx/certs
        fi

        while true; do
            printf '%s\n' "${CYAN}Certificate Management Options:${NC}"
            printf '  0) Return to Security Configuration Menu%s\n' "$NC"
            printf '  1) Generate Self-Signed Certificate (for testing)%s\n' "$NC"
            printf '  2) Setup Let'\''s Encrypt Certificate (includes auto-renewal option)%s\n' "$NC"
            printf '  3) Import Existing Certificate (3rd-party)%s\n' "$NC"
            printf '  4) View Certificate Status%s\n' "$NC"
            printf '  5) Setup Auto-Renewal (cron + deploy-hook)%s\n' "$NC"
            printf '  6) Regenerate HTTPS Configuration%s\n' "$NC"
            printf '  7) Delete Certificate%s\n' "$NC"
            printf '  8) Check Renewal Status%s\n' "$NC"

            read -rp "$(printf '%s' "${CYAN}Enter choice (0-8): ${NC}")" CERT_CHOICE
            case $CERT_CHOICE in
                0)
                    print_info "Returning to security configuration menu..."
                    return 0
                    ;;
                1) generate_self_signed_cert; break ;;
                2) setup_letsencrypt; break ;;
                3) import_certificate; break ;;
                4) view_certificate_status || true; break ;;
                5) setup_auto_renewal_cron; break ;;      # <— canonical function
                6) regenerate_https_config; break ;;
                7) delete_certificate; break ;;
                8) check_renewal_status; break ;;
                *)
                    print_error "Invalid choice. Please enter 0-8."
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
    printf '%s\n' "${CYAN}Enter domain name (e.g., localhost) or type 'q' to cancel: ${NC}"
    read -r DOMAIN
    # Handle cancellation (checks for q, cancel, or if the user is stuck)
    [ -z "$DOMAIN" ] || [ "$DOMAIN" = "q" ] || [ "$DOMAIN" = "cancel" ] && {
        print_info "Generation cancelled."
        return 0
    }

    # Trim and clean domain
    DOMAIN=$(echo "$DOMAIN" | xargs | tr -d ' ')
    DOMAIN=${DOMAIN:-localhost}

    # Determine server names and SANs (Subdomain Awareness)
    local SERVER_NAMES="$DOMAIN"
    local SAN_LIST="DNS.1 = $DOMAIN"
    
    # Only add www if it's a root domain (exactly one dot, not localhost, not already www)
    local dots=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    if [ "$dots" -eq 1 ] && [[ "$DOMAIN" != "localhost" && "$DOMAIN" != "www."* ]]; then
        SERVER_NAMES="$DOMAIN www.$DOMAIN"
        SAN_LIST="DNS.1 = $DOMAIN
DNS.2 = www.$DOMAIN"
    fi

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
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
$SAN_LIST
IP.1 = 127.0.0.1
EOF

    # Generate private key and certificate
    # Using 2048-bit RSA for compatibility and speed
    if openssl genrsa -out "/opt/nginx/certs/$DOMAIN.key" 2048 && \
       openssl req -new -x509 -key "/opt/nginx/certs/$DOMAIN.key" \
        -out "/opt/nginx/certs/$DOMAIN.pem" \
        -days 365 \
        -config /opt/nginx/certs/cert.conf; then

        # --- AUTOMATION START: Set permissions for Unprivileged Docker (UID 101) ---
        print_info "Applying permissions for unprivileged Nginx (UID 101)..."

        # 1. Set Ownership to 101:101 (The Nginx user inside the container)
        # Set proper permissions
        chown 101:101 "/opt/nginx/certs/$DOMAIN.key" "/opt/nginx/certs/$DOMAIN.pem" /opt/nginx/certs/cert.conf 2>/dev/null || true

        # 2. Set strict file permissions: Key is private, Cert is public-readable
        chmod 600 "/opt/nginx/certs/$DOMAIN.key" 2>/dev/null || true
        chmod 644 "/opt/nginx/certs/$DOMAIN.pem" 2>/dev/null || true

        # 3. Ensure the folder is accessible to the Nginx user
        chmod 755 /opt/nginx/certs

        # 4. Remove config file after use
        rm -f /opt/nginx/certs/cert.conf
        # --- AUTOMATION END ---

        print_success "Self-signed certificate generated successfully."
        print_info "Domain: $DOMAIN"
        print_info "Certificate: /opt/nginx/certs/$DOMAIN.pem"
        print_info "Private key: /opt/nginx/certs/$DOMAIN.key"
        print_warning "This certificate is for testing only. Browsers will show 'Insecure' warnings for this self-signed certificate."

        # Update nginx configuration for HTTPS
        update_nginx_https_config "$DOMAIN"
        reload_nginx_service || true

        log "Self-signed certificate generated for $DOMAIN"
    else
        print_error "Failed to generate self-signed certificate."
        return 1
    fi
}

# --- Setup Let's Encrypt Certificate ---
setup_letsencrypt() {
    print_info "Setting up Let's Encrypt certificate..."

    # Dependency Check
    if ! command -v certbot >/dev/null 2>&1; then
        print_info "Installing certbot..."
        # Use apk for Alpine or apt for Debian/Ubuntu (detecting environment)
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache certbot
        else
            # Install certbot without nginx plugin to avoid system nginx installation
            # We use standalone mode which doesn't need nginx integration
            apt-get update -qq && apt-get install -y certbot

        fi
    fi

    # Get Domain Information with Cancellation
    local DOMAIN=""
    local EMAIL=""
    local domain_valid=false

    while [ "$domain_valid" = "false" ]; do
        printf '%s\n' "${CYAN}Enter domain name or type 'q' to cancel: ${NC}"
        read -r DOMAIN
        # Handle cancellation (checks for q, cancel, or if the user is stuck)
        if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "q" ] || [ "$DOMAIN" = "cancel" ]; then
            print_info "Setup cancelled."
            return 0
        fi
        if validate_domain "$DOMAIN"; then
            domain_valid=true
        else
            echo
            if ! confirm "Invalid domain format. Try again?"; then
                print_info "Returning to security configuration menu..."
                return 0
            fi
        fi
    done

    # Check for existing certs
    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        print_warning "Certificate already exists for $DOMAIN"
        print_info "Certificate directory: /etc/letsencrypt/live/$DOMAIN"

        if ! confirm "Issue a new one anyway? (This will create a $DOMAIN-0001 folder)"; then
            print_info "Skipping certificate generation."
            return 0
        fi
    fi

    # Get email for renewal notices
    printf '%s\n' "${CYAN}Enter email for renewal notices (or 'q' to cancel): ${NC}"
    read -r EMAIL
    # Handle cancellation (checks for q, cancel, or if the user is stuck)
    [ -z "$EMAIL" ] || [ "$EMAIL" = "q" ] || [ "$EMAIL" = "cancel" ] && {
        print_error "Email address is required."
        return 1
    }

    # Check if DNS is configured (IPv4 only)
    if ! dig +short "$DOMAIN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        print_warning "Domain $DOMAIN does not currently resolve to an IPv4 address."
        print_info "Please ensure DNS is properly configured before proceeding."
        if ! confirm "Continue anyway? (Standalone mode will likely fail)"; then
            return 1
        fi

    fi

    # Stop nginx to free up port 80 for standalone mode
    local NGINX_STOPPED=false
    local NGINX_MODE="none"

    # Check if system nginx is running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        print_info "Temporarily stopping system Nginx service..."
        systemctl stop nginx
        NGINX_STOPPED=true
        NGINX_MODE="system"
    # Check if Docker nginx is running
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        print_info "Temporarily stopping Nginx container..."
        (cd /opt/nginx && run_docker_compose stop nginx)
        NGINX_STOPPED=true
        NGINX_MODE="docker"
    fi

    # Determine domains (Subdomain Awareness)
    local domains=("-d" "$DOMAIN")
    local dots=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    if [ "$dots" -eq 1 ] && [[ "$DOMAIN" != "www."* ]]; then
        domains+=("-d" "www.$DOMAIN")
        print_info "Including www alias for root domain."
    fi

    if certbot certonly --standalone \
        $CERTBOT_FLAGS \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        "${domains[@]}" \
        --rsa-key-size 4096; then

        # Find the actual lineage (handles suffixing)
        # sort -V is used to ensure -0002 comes after -0001
        local latest_lineage
        latest_lineage=$(find /etc/letsencrypt/live -maxdepth 1 -type d -name "${DOMAIN}*" | sort -V | tail -n 1)
        # Copy certificates to nginx directory
        if [ -n "$latest_lineage" ]; then
            cp -L "$latest_lineage/fullchain.pem" "/opt/nginx/certs/$DOMAIN.pem"
            cp -L "$latest_lineage/privkey.pem" "/opt/nginx/certs/$DOMAIN.key"
            print_success "Copied from $latest_lineage → /opt/nginx/certs/"

            # Permissions and ownership
            chmod 644 "/opt/nginx/certs/$DOMAIN.pem"
            chmod 600 "/opt/nginx/certs/$DOMAIN.key"

            # Set ownership for container (UID 101) or host
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
                chown 101:101 "/opt/nginx/certs/$DOMAIN.pem" "/opt/nginx/certs/$DOMAIN.key"
            else
                chown root:root "/opt/nginx/certs/$DOMAIN.pem" "/opt/nginx/certs/$DOMAIN.key"
            fi

            print_success "Certificates deployed from $latest_lineage"
        else
            print_error "No lineage directory found for $DOMAIN after certbot run."
        fi

        # Restart nginx so we can test the new config
        if [ "$NGINX_STOPPED" = "true" ]; then
            print_info "Restarting Nginx to apply new certificate..."
            if [ "$NGINX_MODE" = "system" ]; then
                systemctl start nginx
            elif [ "$NGINX_MODE" = "docker" ]; then
                (cd /opt/nginx && run_docker_compose start nginx)
            fi
        fi

        # Create renewal hook script (deploy-hook)
        cat > /opt/nginx/certs/renewal_hook.sh << 'EOF'
#!/bin/bash
# Certbot deploy-hook for Nginx (container or system)
set -euo pipefail

# Copy renewed certificates
if [[ -z "${RENEWED_LINEAGE:-}" ]]; then
  echo "RENEWED_LINEAGE not set; this must be run as a Certbot deploy hook."
  exit 0
fi

LINEAGE_DIR="$RENEWED_LINEAGE"
DOMAIN_NAME="$(basename "$LINEAGE_DIR")"

cp -L "$LINEAGE_DIR/fullchain.pem" /opt/nginx/certs/cert.pem
cp -L "$LINEAGE_DIR/privkey.pem"   /opt/nginx/certs/key.pem

# Set proper permissions
chmod 644 /opt/nginx/certs/cert.pem
chmod 600 /opt/nginx/certs/key.pem

# Check if Docker nginx is running and set ownership
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
    chown 101:101 /opt/nginx/certs/cert.pem /opt/nginx/certs/key.pem
else
    chown root:root /opt/nginx/certs/cert.pem /opt/nginx/certs/key.pem
fi

# Reload Nginx - check if it's system or Docker
if systemctl is-active --quiet nginx 2>/dev/null; then
    # System nginx
    systemctl reload nginx
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
    # Docker nginx
    cd /opt/nginx && run_docker_compose exec -T nginx nginx -s reload
fi

echo "Certificate renewed for $DOMAIN_NAME at $(date -Iseconds)"
EOF
        chmod +x /opt/nginx/certs/renewal_hook.sh
        print_success "Created renewal hook script at /opt/nginx/certs/renewal_hook.sh"

        # Update Nginx config
        regenerate_https_config "$DOMAIN"

        # Offer to set up auto-renewal cron job (one global cron, not per-domain)
        if confirm "Would you like to set up automatic certificate renewal (cron + deploy-hook)?"; then
            print_info "Setting up auto-renewal cron job..."
            setup_auto_renewal_cron
        else
            print_info "Auto-renewal cron job not set up. You can set it up later by selecting 'Setup Auto-Renewal' option."
        fi

        log "Let's Encrypt certificate generated for $DOMAIN"
    else
        print_error "Failed to generate Let's Encrypt certificate."
        # If certbot failed, we still need to restart nginx if we stopped it.
        if [ "$NGINX_STOPPED" = "true" ]; then
            print_info "Restarting original Nginx configuration..."
            if [ "$NGINX_MODE" = "system" ]; then
                systemctl start nginx
            elif [ "$NGINX_MODE" = "docker" ]; then
                (cd /opt/nginx && run_docker_compose start nginx)
            fi
        fi
    fi

    return 0
}

# --- Setup Auto-Renewal Cron Job ---
setup_auto_renewal_cron() {
    # --- Dependency Check ---
    if ! command -v certbot >/dev/null 2>&1; then
        print_error "Certbot is not installed. Please run 'Setup Let's Encrypt Certificate' (option 2) first."
        return 1
    fi

    print_info "Setting up certificate auto-renewal cron job..."

    # Ensure renewal hook script exists (deploy-hook style)
    if [[ ! -f /opt/nginx/certs/renewal_hook.sh ]]; then
        print_info "Creating renewal hook script..."
        cat > /opt/nginx/certs/renewal_hook.sh << 'EOF'
#!/bin/bash
# Certbot deploy-hook for Nginx (system or Docker)
set -euo pipefail

# RENEWED_LINEAGE points to the live/ directory of the renewed cert
if [[ -z "${RENEWED_LINEAGE:-}" ]]; then
    echo "RENEWED_LINEAGE not set; this script must be run as a Certbot deploy hook."
    exit 0
fi

LINEAGE_DIR="$RENEWED_LINEAGE"
DOMAIN_NAME="$(basename "$LINEAGE_DIR")"

# Copy renewed certificates into Nginx volume
cp -L "$LINEAGE_DIR/fullchain.pem" /opt/nginx/certs/cert.pem
cp -L "$LINEAGE_DIR/privkey.pem"   /opt/nginx/certs/key.pem

# Set permissions
chmod 644 /opt/nginx/certs/cert.pem
chmod 600 /opt/nginx/certs/key.pem

# Adjust ownership for container (UID 101) vs host
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
    chown 101:101 /opt/nginx/certs/cert.pem /opt/nginx/certs/key.pem
else
    chown root:root /opt/nginx/certs/cert.pem /opt/nginx/certs/key.pem
fi

# Reload Nginx - check if it's system or Docker
if systemctl is-active --quiet nginx 2>/dev/null; then
    # System nginx
    systemctl reload nginx
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
    # Docker nginx
    cd /opt/nginx && run_docker_compose exec -T nginx nginx -s reload
fi

echo "Certificate renewed for $DOMAIN_NAME at $(date -Iseconds)"
EOF
        chmod +x /opt/nginx/certs/renewal_hook.sh
    fi

    local CRON_JOB="0 3 * * * /usr/bin/certbot renew --quiet --deploy-hook '/opt/nginx/certs/renewal_hook.sh'"

    # Setup cron job for renewal (global, not per-domain)
    if ! crontab -l 2>/dev/null | grep -q "certbot.*deploy-hook.*renewal_hook"; then
        (crontab -l 2>/dev/null 2>&1 | grep -v "certbot.*deploy-hook"; \
         echo "$CRON_JOB") | crontab -
        print_success "Auto-renewal cron added: $CRON_JOB"
    else
        print_info "Auto-renewal cron already exists."
    fi
    # Verify hook exists
    if [[ ! -x /opt/nginx/certs/renewal_hook.sh ]]; then
        print_warning "renewal_hook.sh missing. Run setup_letsencrypt first."
    fi

    # Optional: Test renewal configuration with a dry-run
    print_info "Testing renewal configuration (certbot renew --dry-run)..."

    local nginx_was_running=false
    local nginx_mode="none"
    local restart_cmd=""

    # Determine if nginx is running and define the appropriate restart command
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_was_running=true
        nginx_mode="system"
        restart_cmd="systemctl start nginx"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        nginx_was_running=true
        nginx_mode="docker"
        restart_cmd="run_docker_compose -f /opt/nginx/docker-compose.yml start nginx"
    fi

    # Set a trap to restart nginx if the script exits unexpectedly
    if [[ "$nginx_was_running" == "true" ]]; then
        # The command string for the trap is fully resolved here
        trap "print_error 'Script exited unexpectedly. Restarting Nginx to prevent downtime.' && $restart_cmd" EXIT

        # Now, stop nginx
        if [[ "$nginx_mode" == "system" ]]; then
            systemctl stop nginx
        elif [[ "$nginx_mode" == "docker" ]]; then
            run_docker_compose -f /opt/nginx/docker-compose.yml stop nginx
        fi
    fi

    # Temporarily disable exit on error to capture certbot's output and exit code
    set +e
    local dry_run_output
    dry_run_output=$(certbot renew --dry-run 2>&1)
    local test_result=$?
    set -e # Re-enable exit on error if it was set

    # If we reach this point, the critical command has finished.
    # We can now disable the trap and manually restore nginx if we stopped it.
    if [[ "$nginx_was_running" == "true" ]]; then
        trap - EXIT # Disable the trap
        print_info "Restoring Nginx service..."
        eval "$restart_cmd"
        print_success "Nginx service restored."
    fi

    # Final Report
    if [[ $test_result -eq 0 ]]; then
        print_success "Auto-renewal setup dry-run completed successfully."
        # Show output on success as well, it can contain useful info
        if [[ -n "$dry_run_output" ]]; then
            echo "$dry_run_output" | sed 's/^/    /'
        fi
        return 0
    else
        print_error "Renewal dry-run failed. See details below:"
        echo "$dry_run_output" | sed 's/^/    /'
        echo

        if [[ "$dry_run_output" =~ "is broken" && "$dry_run_output" =~ "to be a symlink" ]]; then
            print_warning "Certbot's configuration appears to be broken."
            print_info "This typically happens if certificate files were moved or copied incorrectly."
            print_info "To fix this, you should delete the broken certificate(s) and issue new ones."
            echo
            print_info "Recommended Steps:"
            print_info "  1. Use option '7) Delete Certificate' from the menu to remove the affected domain(s)."
            print_info "  2. Use option '2) Setup Let's Encrypt Certificate' to generate a fresh certificate."
            print_info "  3. Finally, run this auto-renewal setup (option 5) again."
        else
            print_info "Please check the Certbot logs for more details: /var/log/letsencrypt/letsencrypt.log"
        fi
        return 1
    fi
}

# --- Import Existing Certificate ---
import_certificate() {
    print_info "Importing existing SSL certificate..."

    # Get certificate file path
    local cert_path_valid=false
    while [[ "$cert_path_valid" == "false" ]]; do
        printf '%s\n' "${CYAN}Enter path to certificate file (.crt or .pem) (or 'q' to cancel): ${NC}"
        read -r CERT_FILE

        # Cancel option
        if [ -z "$CERT_FILE" ] || [ "$CERT_FILE" = "q" ] || [ "$CERT_FILE" = "cancel" ] ; then
            print_info "Import cancelled."
            return 0
        fi

        if [ ! -f "$CERT_FILE" ]; then
            print_error "Certificate file not found: $CERT_FILE"
            if ! confirm "Would you like to try again?"; then
                print_info "Returning to security configuration menu..."
                return 0
            fi
            continue
        fi
        # Use your existing validation helper
        if validate_file_path "$CERT_FILE"; then
            cert_path_valid=true
        else
            echo
            if ! confirm "Path failed security check. Try a different path?"; then
                print_info "Returning to security configuration menu..."
                return 0
            fi
        fi
    done

    # Get private key file path
    local key_path_valid=false
    local KEY_FILE
    while [[ "$key_path_valid" == "false" ]]; do
        printf '%s\n' "${CYAN}Enter path to private key file (.key): ${NC}"
        read -r KEY_FILE

        # Cancel option
        [ -z "$KEY_FILE" ] || [ "$KEY_FILE" = "q" ] || [ "$KEY_FILE" = "cancel" ] && return 0

        if [ ! -f "$KEY_FILE" ]; then
            print_error "Private key file not found: $KEY_FILE"
            if ! confirm "Would you like to try again?"; then
                print_info "Returning to certificate management menu..."
                return 0
            fi
            continue
        fi

        if validate_file_path "$KEY_FILE"; then
            key_path_valid=true
        else
            echo
            if ! confirm "Path failed security check. Try a different path?"; then
                print_info "Returning to certificate management menu..."
                return 0
            fi
        fi
    done

    # Validate certificate and key
    print_info "Validating SSL pair..."
    if ! openssl x509 -in "$CERT_FILE" -text -noout >/dev/null 2>&1; then
        print_error "Invalid certificate file."
        return 1
    fi

    if ! openssl pkey -in "$KEY_FILE" -check -noout >/dev/null 2>&1; then
        print_error "Invalid private key or passphrase required."
        return 1
    fi

    # Verify that the certificate and private key match
    local CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_FILE")
    local KEY_MOD=$(openssl pkey -noout -modulus -in "$KEY_FILE")

    if [ "$CERT_MOD" != "$KEY_MOD" ]; then
        print_error "CRITICAL: Certificate and Private Key do not match!"
        return 1
    fi

    # Extract domain from certificate
    local DOMAIN=$(openssl x509 -in "$CERT_FILE" -noout -subject \
        | sed -n 's/.*CN[ =]*\([^,/]*\).*/\1/p' | head -1)
    DOMAIN=${DOMAIN:-unknown}

    # Backup existing if present
    [ -f "/opt/nginx/certs/$DOMAIN.pem" ] && mv "/opt/nginx/certs/$DOMAIN.pem" "/opt/nginx/certs/$DOMAIN.pem.bak"
    [ -f "/opt/nginx/certs/$DOMAIN.key" ] && mv "/opt/nginx/certs/$DOMAIN.key" "/opt/nginx/certs/$DOMAIN.key.bak"

    # Copy certificates
    cp "$CERT_FILE" "/opt/nginx/certs/$DOMAIN.pem"
    cp "$KEY_FILE" "/opt/nginx/certs/$DOMAIN.key"

    # Check if Docker nginx is running and set ownership
    if docker ps --format "{{.Names}}" | grep -q "^nginx$"; then
        chown 101:101 "/opt/nginx/certs/$DOMAIN.pem" "/opt/nginx/certs/$DOMAIN.key"
    else
        chown root:root "/opt/nginx/certs/$DOMAIN.pem" "/opt/nginx/certs/$DOMAIN.key"
    fi

    # Set proper permissions
    chmod 644 "/opt/nginx/certs/$DOMAIN.pem"
    chmod 600 "/opt/nginx/certs/$DOMAIN.key"

    print_success "Certificate imported successfully."
    print_info "Domain: $DOMAIN"
    print_info "Certificate: /opt/nginx/certs/$DOMAIN.pem"
    print_info "Private key: /opt/nginx/certs/$DOMAIN.key"

    # Update nginx configuration for HTTPS
    update_nginx_https_config "$DOMAIN"
    reload_nginx_service || true

    log "Certificate imported for $DOMAIN"
}

# --- View Certificate Status ---
view_certificate_status() {
    print_info "Checking active certificates in /opt/nginx/certs/..."
    # Set current epoch ONCE at top (used throughout)
    local CURRENT_EPOCH
    CURRENT_EPOCH=$(date +%s)

    local found_any=false

    # Scan for all .pem files in /opt/nginx/certs/
    for cert_file in /opt/nginx/certs/*.pem; do
        [[ ! -f "$cert_file" ]] && continue
        found_any=true

        local domain_file=$(basename "$cert_file")
        print_info "--- Certificate: $domain_file ---"

        # Display certificate information
        printf '%s%s%s\n' "$BOLD" "  Details:" "$NC"
        openssl x509 -in "$cert_file" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:|DNS:)" | sed 's/^/    /'

        # Key Validation
        local key_file="${cert_file%.pem}.key"
        if [[ -f "$key_file" ]]; then
            printf '  %sPrivate key found: %s (%s)%s\n' "$CYAN" "$key_file" "$(stat -c %a "$key_file")" "$NC"

            # Check cert/key match
            local cert_hash key_hash
            cert_hash=$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | openssl md5)
            key_hash=$(openssl pkey -in "$key_file" -pubout 2>/dev/null | openssl md5)

            if [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]; then
                printf '    %sCert/Key match: ✓%s\n' "$GREEN" "$NC"
            else
                printf '    %sCert/Key match: ✗ MISMATCH!%s\n' "$RED" "$NC"
            fi
        else
            printf '  %sWARNING: No private key at %s%s\n' "$RED" "$key_file" "$NC"
        fi

        # Check expiration
        local EXPIRY_DATE EXPIRY_EPOCH DAYS_LEFT
        EXPIRY_DATE=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
        EXPIRY_EPOCH=$(date --date="$EXPIRY_DATE" +%s 2>/dev/null) || EXPIRY_EPOCH=$CURRENT_EPOCH
        DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

        if [[ $DAYS_LEFT -lt 0 ]]; then
            printf '  %sCRITICAL: Certificate expired %d days ago!%s\n' "$RED" "$(( DAYS_LEFT * -1 ))" "$NC"
        elif [[ $DAYS_LEFT -lt 14 ]]; then
            printf '  %sWARNING: Certificate expires in %d days!%s\n' "$YELLOW" "$DAYS_LEFT" "$NC"
        else
            printf '  %sExpires in: %d days%s\n' "$GREEN" "$DAYS_LEFT" "$NC"
        fi
        echo
    done

    if [[ "$found_any" == "false" ]]; then
        print_info "No active certificates found in /opt/nginx/certs/"
    fi

    # Check Let's Encrypt certificates
    if [[ -d /etc/letsencrypt/live ]]; then
        echo
        printf '%s%s%s\n' "$BOLD" "Let's Encrypt Certificates Source Directories (/etc/letsencrypt/live):" "$NC"

        # Track domains with duplicates
        declare -A domains_seen
        local has_duplicates=false

        # POSIX compatible: * expands to nothing if empty
        for cert_dir in /etc/letsencrypt/live/*; do
            [[ ! -d "$cert_dir" ]] && continue  # Skip if no matches
            local domain
            domain=$(basename "$cert_dir")

            # Skip Let's Encrypt README
            [[ "$domain" == "README" ]] && continue

            local base_domain="${domain%%-[0-9]*}"

            # Check if this is a duplicate (suffixed) certificate
            if [[ "$domain" =~ ^.+-[0-9]+$ ]]; then
                # Mark that we have duplicates for this base domain
                domains_seen["$base_domain"]="has_duplicates"
                has_duplicates=true
                continue  # skip display for suffixed
            fi

            # Only display base domains (not suffixed ones)
            if [[ -f "$cert_dir/fullchain.pem" ]]; then
                local expiry expiry_epoch days_left
                expiry=$(openssl x509 -in "$cert_dir/fullchain.pem" -enddate -noout | cut -d= -f2)
                expiry_epoch=$(date --date="$expiry" +%s 2>/dev/null) || expiry_epoch=$CURRENT_EPOCH
                days_left=$(( (expiry_epoch - CURRENT_EPOCH) / 86400 ))

                if [[ $days_left -lt 30 ]]; then
                    printf '  %s: %s%d days%s (renewal imminent)\n' "$domain" "$RED" "$days_left" "$NC"
                else
                    printf '  %s: %s%d days%s\n' "$domain" "$GREEN" "$days_left" "$NC"
                fi
            fi
        done

        # Display warning about duplicates
        if [[ "$has_duplicates" == "true" ]]; then
            echo
            printf '%s%s%s\n' "$YELLOW" "⚠ WARNING: Duplicate certificate directories detected!" "$NC"
            printf '%s%s%s\n' "$YELLOW" "  This can happen when certificates are requested multiple times." "$NC"
            printf '%s%s%s\n' "$YELLOW" "  Multiple lineages exist. Current nginx uses /opt/nginx/certs/cert.pem." "$NC"

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

# --- Check Renewal Status ---
check_renewal_status() {
    print_info "Checking Certbot renewal status (read-only)..."

    if [[ ! -d /etc/letsencrypt/renewal ]]; then
        print_warning "No Certbot renewal configs found."
        return 0
    fi

    local total=$(find /etc/letsencrypt/renewal -name "*.conf" | wc -l)
    local lineages=$(find /etc/letsencrypt/live -mindepth 1 -type d | wc -l)

    print_success "$total renewal configs, $lineages live directories."
    print_info "Active certificates are stored in: /opt/nginx/certs/"

    if [[ $lineages -gt $total ]]; then
        print_warning "$(($lineages - $total)) duplicate lineages detected."
    fi

    # Stop nginx to free up port 80 for standalone mode
    local NGINX_STOPPED=false
    local NGINX_MODE="none"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        print_info "Temporarily stopping system Nginx service..."
        systemctl stop nginx
        NGINX_STOPPED=true
        NGINX_MODE="system"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        print_info "Temporarily stopping Nginx container..."
        (cd /opt/nginx && run_docker_compose stop nginx)
        NGINX_STOPPED=true
        NGINX_MODE="docker"
    fi

    # Dry-run test
    if certbot renew --dry-run; then
        print_success "Dry-run PASSED."
    else
        print_warning "Dry-run FAILED. Check: journalctl -u certbot or /var/log/letsencrypt"
    fi

    # Restart Nginx if it was stopped
    if [ "$NGINX_STOPPED" = "true" ]; then
        if [ "$NGINX_MODE" = "system" ]; then
            print_info "Restarting system Nginx service..."
            systemctl start nginx
        elif [ "$NGINX_MODE" = "docker" ]; then
            print_info "Restarting Nginx container..."
            (cd /opt/nginx && run_docker_compose start nginx)
        fi
    fi
}

# --- Update Nginx HTTPS Configuration ---
update_nginx_https_config() {
    local DOMAIN="$1"
    [[ -z "$DOMAIN" ]] && { print_error "Domain required."; return 1; }

    print_info "Updating nginx HTTPS configuration for $DOMAIN..."


    # Validate certs exist
    if [[ ! -f "/opt/nginx/certs/$DOMAIN.pem" ]] || [[ ! -f "/opt/nginx/certs/$DOMAIN.key" ]]; then
        print_warning "No certs found for $DOMAIN at /opt/nginx/certs/. Skipping HTTPS server block."
        return 1
    fi

    # Detect nginx type
    local NGINX_TYPE="docker"
    local HTTP_PORT=8080
    local HTTPS_PORT=8443
    local ROOT_DIR="/usr/share/nginx/html"
    local LOG_PREFIX="https"
    local CONFIG_DIR="/opt/nginx/conf.d"
    # Always use /opt/nginx/certs paths (mount point)
    local CERT_PATH="/etc/nginx/certs/$DOMAIN.pem"
    local KEY_PATH="/etc/nginx/certs/$DOMAIN.key"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        NGINX_TYPE="system"
        HTTP_PORT=80
        HTTPS_PORT=443
        ROOT_DIR="/var/www/html"
        CONFIG_DIR="/etc/nginx/sites-available"
        LOG_PREFIX="https_$DOMAIN"
        # System nginx uses standard paths (no /opt/nginx/certs mount)
        CERT_PATH="/opt/nginx/certs/$DOMAIN.pem"
        KEY_PATH="/opt/nginx/certs/$DOMAIN.key"
        # Ensure system nginx (www-data) can read certs
        chown root:www-data /opt/nginx/certs /opt/nginx/certs/*
        chmod 750 /opt/nginx/certs
        chmod 640 "/opt/nginx/certs/$DOMAIN.pem"
        chmod 600 "/opt/nginx/certs/$DOMAIN.key"
    fi

    # Legacy Cleanup: Remove or backup the old non-domain-specific config
    if [[ -f "$CONFIG_DIR/https.conf" ]]; then
        print_info "Cleaning up legacy https.conf..."
        mv "$CONFIG_DIR/https.conf" "$CONFIG_DIR/https.conf.legacy_backup"
        [[ "$NGINX_TYPE" == "system" ]] && rm -f /etc/nginx/sites-enabled/https.conf
    fi

    # Determine server names (Subdomain Awareness)
    local SERVER_NAMES="$DOMAIN"
    local dots=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    if [ "$dots" -eq 1 ] && [[ "$DOMAIN" != "localhost" && "$DOMAIN" != "www."* ]]; then
        SERVER_NAMES="$DOMAIN www.$DOMAIN"
    fi

    # Generate config file
    local CONFIG_FILE="$CONFIG_DIR/$DOMAIN.conf"
    cat > "$CONFIG_FILE" << EOF
# HTTPS configuration for $DOMAIN
server {
    listen $HTTP_PORT;
    server_name $SERVER_NAMES;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen $HTTPS_PORT ssl;
    http2 on;
    server_name $SERVER_NAMES;
    # SSL configuration
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # OCSP stapling (disabled for staging certificates)
    # ssl_stapling on;
    # ssl_stapling_verify on;
    # resolver 8.8.8.8 8.8.4.4 valid=300s;
    # resolver_timeout 5s;

    # Security headers
    include /etc/nginx/conf.d/security-headers.conf;

    # Root
    root $ROOT_DIR;
    index index.html index.htm;

    # Health check endpoint - MUST BE FIRST
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Block access to sensitive files
    location ~ /\. { deny all; access_log off; log_not_found off; }
    location ~ ~\$ { deny all; access_log off; log_not_found off; }

    # Block access to backup files
    location ~* \.(bak|backup|old|orig|save|tmp)\$ { deny all; access_log off; log_not_found off; }

    # Block access to configuration files
    location ~* \.(conf|config|ini|log|sql|sh|py|pl)\$ { deny all; access_log off; log_not_found off; }

    # Main location
    location / { try_files \$uri \$uri/ =404; }

    # Nginx status (restricted to localhost)
    location /nginx_status {
        stub_status on; access_log off;
        allow 127.0.0.1; allow 172.20.0.0/16; allow ::1; deny all;
    }

    # Error pages
    error_page 500 502 503 504 /50x.html;
    location = /50x.html { root $ROOT_DIR; internal; }

    # Logging
    access_log /var/log/nginx/${LOG_PREFIX}_access.log main;
    error_log /var/log/nginx/${LOG_PREFIX}_error.log warn;
}
EOF

    # Enable config based on type
    if [[ "$NGINX_TYPE" == "system" ]]; then
        # System nginx: sites-available -> sites-enabled
        ln -sf "$CONFIG_FILE" "/etc/nginx/sites-enabled/$DOMAIN.conf" 2>/dev/null || true
        chown root:root "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        print_success "HTTPS configuration created for $DOMAIN."
        print_success "System nginx HTTPS config: $CONFIG_FILE -> sites-enabled"
        #print_info "Please reload Nginx to apply changes:"
        #print_info "  sudo systemctl reload nginx"
    else
        # Docker: just chown for UID 101
        chown 101:101 "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        print_success "Docker nginx HTTPS config: $CONFIG_FILE"
    fi

    # Reload
    if [[ "$NGINX_TYPE" == "system" ]]; then
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
            print_info "System nginx reloaded."
        else
            systemctl start nginx
            print_info "System nginx started."
        fi
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        print_info "Rerunning nginx container to apply configuration..."
        # We use 'up -d' because 'exec reload' fails if the container is crashed
        cd /opt/nginx && run_docker_compose up -d nginx
        print_info "Docker nginx container updated/restarted."
    else
        print_info "Nginx not running. Start it to apply config."
    fi

    log "HTTPS configuration updated for $DOMAIN ($NGINX_TYPE)"
}

# --- Regenerate HTTPS Configuration ---
regenerate_https_config() {
    print_info "Regenerating HTTPS configuration..."

    # 1. Dynamically determine the domain
    local DOMAIN="${1:-}"

    [[ -z "$DOMAIN" ]] && DOMAIN=$(grep -m1 'server_name.*;' /opt/nginx/conf.d/default.conf 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)
    DOMAIN=${DOMAIN:-localhost}
    print_info "Using domain: $DOMAIN"

    # 2. Check if certs exist for this domain
    if [[ ! -f "/opt/nginx/certs/$DOMAIN.pem" || ! -f "/opt/nginx/certs/$DOMAIN.key" ]]; then
        print_error "Missing certs for $DOMAIN at /opt/nginx/certs/. Generate first."
        return 1
    fi

    # 3. Detect nginx type and initialize paths
    local NGINX_TYPE="docker"
    local INT_HTTP_PORT=8080 INT_HTTPS_PORT=8443
    local EXT_HTTP_PORT=80   EXT_HTTPS_PORT=443
    local ROOT_DIR="/usr/share/nginx/html" CONFIG_DIR="/opt/nginx/conf.d"
    local TEST_CMD="docker exec nginx nginx -t -c /etc/nginx/nginx.conf" RELOAD_CMD="reload_nginx_service"
    local CERT_PATH="/etc/nginx/certs/$DOMAIN.pem"
    local KEY_PATH="/etc/nginx/certs/$DOMAIN.key"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        NGINX_TYPE="system"
        INT_HTTP_PORT=80 INT_HTTPS_PORT=443
        EXT_HTTP_PORT=80 EXT_HTTPS_PORT=443
        ROOT_DIR="/var/www/html" CONFIG_DIR="/etc/nginx/sites-available"
        TEST_CMD="nginx -t" RELOAD_CMD="systemctl reload nginx"
        CERT_PATH="/opt/nginx/certs/$DOMAIN.pem"
        KEY_PATH="/opt/nginx/certs/$DOMAIN.key"
    fi

    # 4. Backup existing
    local CONFIG_FILE="$CONFIG_DIR/$DOMAIN.conf"
    if [[ -f "$CONFIG_FILE" ]]; then
        local ts backup_file
        ts=$(date +%Y%m%d_%H%M%S)
        backup_file="$CONFIG_FILE.backup.$ts"
        cp "$CONFIG_FILE" "$backup_file"
        print_info "Backup created: $(basename "$backup_file")"
    fi

    # 5. Apply permissions
    if [[ "$NGINX_TYPE" == "docker" ]]; then
        chown 101:101 "/opt/nginx/certs/$DOMAIN.pem" "/opt/nginx/certs/$DOMAIN.key"
        chmod 644 "/opt/nginx/certs/$DOMAIN.pem"
        chmod 600 "/opt/nginx/certs/$DOMAIN.key"
    else
        # Fix perms for www-data
        chown -R root:www-data /opt/nginx/certs
        chmod 750 /opt/nginx/certs
        chmod 640 "/opt/nginx/certs/$DOMAIN.pem"
        chmod 600 "/opt/nginx/certs/$DOMAIN.key"
    fi
    # Determine server names (Subdomain Awareness)
    local SERVER_NAMES="$DOMAIN"
    local dots=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    if [ "$dots" -eq 1 ] && [[ "$DOMAIN" != "localhost" && "$DOMAIN" != "www."* ]]; then
        SERVER_NAMES="$DOMAIN www.$DOMAIN"
    fi

    cat > "$CONFIG_FILE" << EOF
# HTTPS for $DOMAIN ($NGINX_TYPE)
server {
    listen $INT_HTTP_PORT;
    server_name $SERVER_NAMES;

    # Health check endpoint (Directly on HTTP to avoid redirect loops during tests)
    location /health {
        access_log off;
        allow all;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen $INT_HTTPS_PORT ssl;
    http2 on;
    server_name $SERVER_NAMES;

    # Security settings - Rate limiting enabled
    limit_req zone=general burst=40 nodelay;
    limit_conn conn_limit_per_ip 10;

    # SSL configuration
    ssl_certificate ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # OCSP stapling (disabled for staging certificates)
    # ssl_stapling on;
    # ssl_stapling_verify on;
    # resolver 8.8.8.8 8.8.4.4 valid=300s;
    # resolver_timeout 5s;

    # Security headers
    # Use /etc/nginx/conf.d because /opt/nginx/conf.d is mapped to it
    include /etc/nginx/conf.d/security-headers.conf;

    # Root directory
    root $ROOT_DIR; index index.html index.htm;

    # Health check endpoint - MUST BE FIRST
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Block access to sensitive files
    location ~ /\. { deny all; access_log off; log_not_found off; }
    location ~ ~\$ { deny all; access_log off; log_not_found off; }

    # Block access to backup files
    location ~* \.(bak|backup|old|orig|save|tmp)\$ { deny all; access_log off; log_not_found off; }

    # Block access to configuration files
    location ~* \.(conf|config|ini|log|sql|sh|py|pl)\$ { deny all; access_log off; log_not_found off; }

    # Main location
    location / { try_files \$uri \$uri/ =404; }

    # Nginx status (restricted to localhost)
    location /nginx_status {
        stub_status on; access_log off;
        allow 127.0.0.1; allow 172.20.0.0/16; allow ::1; deny all;
    }

    # Error pages
    error_page 500 502 503 504 /50x.html;
    location = /50x.html { root $ROOT_DIR; internal; }

    # Logging
    access_log /var/log/nginx/https_access.log main;
    error_log /var/log/nginx/https_error.log warn;
}
EOF

    # Fix permissions
    if [[ "$NGINX_TYPE" == "docker" ]]; then
        chown 101:101 "$CONFIG_FILE"
    fi
    chmod 644 "$CONFIG_FILE"

    # System nginx: enable site
    [[ "$NGINX_TYPE" == "system" ]] && ln -sf "$CONFIG_FILE" "/etc/nginx/sites-enabled/$DOMAIN.conf"

    # 6. Legacy Cleanup
    if [[ -f "$CONFIG_DIR/https.conf" ]]; then
        print_info "Cleaning up legacy https.conf..."
        mv "$CONFIG_DIR/https.conf" "$CONFIG_DIR/https.conf.legacy_backup"
        [[ "$NGINX_TYPE" == "system" ]] && rm -f /etc/nginx/sites-enabled/https.conf
    fi

    # 7. Test and Reload
    print_info "Testing configuration..."
    if eval "$TEST_CMD"; then
        print_success "Config test passed"
        
        if [[ "$NGINX_TYPE" == "system" ]]; then
            systemctl reload nginx || systemctl start nginx
        else
            # For Docker, 'up -d' is safer than 'reload' if it was previously crashed
            cd /opt/nginx && run_docker_compose up -d nginx
        fi
        print_success "Nginx updated and reloaded"

        # Verify health check
        print_info "Verifying health check (Attempting connection)..."
        local hc_passed=false
        # 3 attempts with 2s delay
        for i in 1 2 3; do
            if curl -f -k -s -H "Host: $DOMAIN" "http://127.0.0.1:$EXT_HTTP_PORT/health" >/dev/null 2>&1 || \
               curl -f -k -s -H "Host: $DOMAIN" "https://127.0.0.1:$EXT_HTTPS_PORT/health" >/dev/null 2>&1; then
                print_success "Health check ✓"
                hc_passed=true
                break
            fi
            [[ $i -lt 3 ]] && sleep 2
        done

        if [[ "$hc_passed" == "false" ]]; then
            print_warning "Health check failed after 3 attempts."
            print_info "Check if $DOMAIN resolves to 127.0.0.1 or check Nginx logs."
        fi
    else
        print_error "Configuration test failed. Restoring previous config..."
        # Find the most recent backup
        local latest_backup
        latest_backup=$(ls -t "$CONFIG_FILE.backup."* 2>/dev/null | head -1)

        if [[ -n "$latest_backup" ]]; then
            cp "$latest_backup" "$CONFIG_FILE"
            print_info "Restored from backup: $latest_backup"
            # Re-test and reload the restored config (optional but nice)
            if eval "$TEST_CMD"; then
                eval "$RELOAD_CMD"
                print_success "Nginx reloaded with restored configuration."
            else
                print_warning "Restored configuration still fails nginx -t. Check logs."
            fi
        else
            print_warning "No backup found to restore"
        fi
        return 1
    fi

        log "HTTPS config regenerated for $DOMAIN ($NGINX_TYPE)"
}

# --- Delete Certificate ---
delete_certificate() {
    print_info "Deleting certificate..."

    # DECLARE ALL VARIABLES UPFRONT
    local active_count=0
    local le_count=0
    local current_display_idx=1
    local found_match=false

    echo "Available Active Certificates (in /opt/nginx/certs/):"
    echo

    # 1. Current active certificates
    local found_active=false
    for cert_file in /opt/nginx/certs/*.pem; do
        [[ ! -f "$cert_file" ]] && continue
        found_active=true
        local domain=$(basename "$cert_file" .pem)
        
        # Detect type
        local issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)
        local cert_type="Self-Signed/Imported"
        [[ "$issuer" == *"Let's Encrypt"* ]] && cert_type="Let's Encrypt"

        if [[ "$domain" == "cert" ]]; then
            echo "  $current_display_idx) LEGACY ACTIVE (cert.pem) - Domain: $domain"
        else
            echo "  $current_display_idx) Active ($cert_type): $domain"
        fi

        eval "active_map_$current_display_idx=\"$domain\""
        active_count=$((active_count + 1))
        current_display_idx=$((current_display_idx + 1))
    done

    if [[ "$found_active" == "false" ]]; then
        echo "  -) No active certificates found in /opt/nginx/certs/"
    fi

    echo
    echo "Source Lineages (Permanently remove from Let's Encrypt storage):"
    if [ -d /etc/letsencrypt/live ]; then
        for lineage in /etc/letsencrypt/live/*; do
            [ ! -d "$lineage" ] && continue
            local domain=$(basename "$lineage")
            [ "$domain" = "README" ] && continue

            echo "  $current_display_idx) Source: $domain"
            eval "mapping_$current_display_idx=\"$domain\""
            le_count=$((le_count + 1))
            current_display_idx=$((current_display_idx + 1))
        done
    fi

    if [ "$active_count" -eq 0 ] && [ "$le_count" -eq 0 ]; then
        print_error "No certificates found to delete."
        return 0
    fi

    echo
    printf '%s\n' "${CYAN}Enter certificate number to delete (0=cancel): ${NC}"
    read -r DELETE_CHOICE
    if [ -z "$DELETE_CHOICE" ] || [ "$DELETE_CHOICE" = "0" ]; then
        print_info "Deletion cancelled."
        return 0
    fi

    # Check if they picked an active cert
    if [[ "$DELETE_CHOICE" -le "$active_count" ]]; then
        local target_domain
        eval "target_domain=\$active_map_$DELETE_CHOICE"
        
        print_warning "You are deleting the ACTIVE certificate and configuration for: $target_domain"
        if confirm "Proceed?"; then
            # 1. Delete the active files
            rm -f "/opt/nginx/certs/$target_domain.pem" "/opt/nginx/certs/$target_domain.key"
            print_success "Active certificate files for $target_domain removed."

            # 2. Remove configuration
            local CONFIG_DIR="/opt/nginx/conf.d"
            if systemctl is-active --quiet nginx 2>/dev/null; then
                CONFIG_DIR="/etc/nginx/sites-available"
                rm -f "/etc/nginx/sites-enabled/$target_domain.conf"
            fi
            
            rm -f "$CONFIG_DIR/$target_domain.conf"
            print_success "HTTPS configuration for $target_domain removed."
            found_match=true
        fi
    else
        # Retrieve the domain from Let's Encrypt mapping
        local target_domain
        eval "target_domain=\$mapping_$DELETE_CHOICE"

        if [ -n "$target_domain" ]; then
            print_warning "Deleting Let's Encrypt lineage: $target_domain"
            if confirm "Are you sure? This deletes ALL source files for $target_domain."; then
                if command -v certbot >/dev/null 2>&1; then
                    certbot delete --cert-name "$target_domain" --non-interactive 2>/dev/null || true
                fi

                # Manual cleanup
                rm -rf "/etc/letsencrypt/live/${target_domain}"
                rm -rf "/etc/letsencrypt/archive/${target_domain}"
                rm -f "/etc/letsencrypt/renewal/${target_domain}.conf"

                print_success "Lineage $target_domain deleted."
                # Note: We don't necessarily reload here unless we also deleted an active cert
            fi
        else
            print_error "Invalid selection: $DELETE_CHOICE"
        fi
    fi

    [ "$found_match" = "true" ] && reload_nginx_service || true
    print_success "Certificate deletion process completed."
}

deploy_existing_lineage() {
    print_info "Deploying an existing Let's Encrypt certificate to Nginx..."

    local le_count=0
    local current_idx=1
    local selected_lineage=""

    # 1. List available lineages
    echo "Select a certificate to activate:"
    echo

    if [ -d /etc/letsencrypt/live ]; then
        for lineage in /etc/letsencrypt/live/*; do
            [ ! -d "$lineage" ] && continue
            local domain=$(basename "$lineage")
            [ "$domain" = "README" ] && continue

            echo "  $current_idx) $domain"
            eval "lineage_map_$current_idx=\"$domain\""
            le_count=$((le_count + 1))
            current_idx=$((current_idx + 1))
        done
    fi

    if [ "$le_count" -eq 0 ]; then
        print_error "No Let's Encrypt certificates found to deploy."
        return 1
    fi

    echo
    printf '%s\n' "${CYAN}Enter selection (0=cancel): ${NC}"
    read -r CHOICE
    [ -z "$CHOICE" ] || [ "$CHOICE" = "0" ] && return 0

    # 2. Retrieve selection
    eval "selected_lineage=\$lineage_map_$CHOICE"

    if [ -n "$selected_lineage" ]; then
        print_info "Activating certificate for: $selected_lineage"

        # Define paths
        local src_dir="/etc/letsencrypt/live/$selected_lineage"
        local target_cert="/opt/nginx/certs/$selected_lineage.pem"
        local target_key="/opt/nginx/certs/$selected_lineage.key"

        # Copy the files
        cp "$src_dir/fullchain.pem" "$target_cert"
        cp "$src_dir/privkey.pem" "$target_key"

        # Apply permissions for unprivileged Nginx (UID 101)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
            chown 101:101 "$target_cert" "$target_key"
        else
            chown root:root "$target_cert" "$target_key"
        fi
        chmod 644 "$target_cert"
        chmod 600 "$target_key"

        # 3. Update Nginx Config
        # Extract the primary domain (stripping -0001 suffixes for the Nginx server_name)
        # Note: We keep the filename as $selected_lineage for uniqueness
        local primary_domain=$(echo "$selected_lineage" | sed 's/-[0-9]\{4\}$//')

        update_nginx_https_config "$selected_lineage"
        reload_nginx_service

        print_success "Successfully deployed $selected_lineage to active Nginx config."
    else
        print_error "Invalid selection."
    fi
}

# Helper function to reload regardless of install type
reload_nginx_service() {
    # Check for Docker Nginx first
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        print_info "Reloading Docker Nginx configuration..."
        # We try 'exec' first, falling back to 'kill -HUP' if exec is restricted
        if ! (cd /opt/nginx && run_docker_compose exec -T nginx nginx -s reload 2>/dev/null); then
            docker kill -s HUP nginx >/dev/null 2>&1 || true
        fi
        print_success "Docker Nginx reloaded."

    # Fallback to System Nginx
    elif systemctl is-active --quiet nginx 2>/dev/null; then
        print_info "Reloading System Nginx service..."
        systemctl reload nginx 2>/dev/null || true
        print_success "System Nginx reloaded."
    else
        print_warning "Nginx is not running; configuration will apply on next start."
    fi
}
