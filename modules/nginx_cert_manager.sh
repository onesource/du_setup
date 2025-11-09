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
    print_section "SSL/TLS Certificate Management"

    # Check if certificates directory exists
    if [[ ! -d /opt/nginx/certs ]]; then
        mkdir -p /opt/nginx/certs
        chown root:root /opt/nginx/certs
        chmod 755 /opt/nginx/certs
    fi

    printf '%s\n' "${CYAN}Certificate Management Options:${NC}"
    printf '  1) Generate Self-Signed Certificate (for testing)%s\n' "$NC"
    printf '  2) Setup Let'\''s Encrypt Certificate%s\n' "$NC"
    printf '  3) Import Existing Certificate%s\n' "$NC"
    printf '  4) View Certificate Status%s\n' "$NC"
    printf '  5) Setup Auto-Renewal%s\n' "$NC"

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter choice (1-5): ${NC}")" CERT_CHOICE
        case $CERT_CHOICE in
            1) generate_self_signed_cert ;;
            2) setup_letsencrypt ;;
            3) import_certificate ;;
            4) view_certificate_status ;;
            5) setup_auto_renewal ;;
            *) print_error "Invalid choice. Please enter 1-5." ;;
        esac
        break
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
        apt-get install -y certbot python3-certbot-nginx
    fi

    # Get domain information
    read -rp "$(printf '%s' "${CYAN}Enter domain name: ${NC}")" DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        print_error "Domain name is required."
        return 1
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
    if docker ps --format "table {{.Names}}" | grep -q "^nginx$"; then
        print_info "Temporarily stopping Nginx container..."
        cd /opt/nginx && docker-compose stop
        NGINX_STOPPED=true
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

        # Update nginx configuration for HTTPS
        update_nginx_https_config "$DOMAIN"

        # Restart nginx
        if [[ "$NGINX_STOPPED" == "true" ]]; then
            print_info "Restarting Nginx container..."
            cd /opt/nginx && docker-compose start
        fi

        # Setup auto-renewal
        setup_certbot_renewal "$DOMAIN"

        log "Let's Encrypt certificate generated for $DOMAIN"
    else
        print_error "Failed to generate Let's Encrypt certificate."
        # Restart nginx if it was stopped
        if [[ "$NGINX_STOPPED" == "true" ]]; then
            cd /opt/nginx && docker-compose start
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
        for cert_dir in /etc/letsencrypt/live/*; do
            if [[ -d "$cert_dir" ]]; then
                domain=$(basename "$cert_dir")
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
        done
    fi
}

# --- Setup Auto-Renewal ---
setup_auto_renewal() {
    print_info "Setting up certificate auto-renewal..."

    # Check if certbot is installed
    if ! command -v certbot >/dev/null 2>&1; then
        print_error "Certbot is not installed. Cannot setup auto-renewal."
        return 1
    fi

    # Create renewal hook
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

    # Reload Nginx
    cd /opt/nginx && docker-compose exec nginx nginx -s reload

    echo "Certificate renewed for $DOMAIN at $(date)"
fi
EOF

    chmod +x /opt/nginx/certs/renewal_hook.sh

    # Setup cron job for renewal
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet --post-hook '/opt/nginx/certs/renewal_hook.sh'") | crontab -
        print_success "Auto-renewal cron job created."
    else
        print_info "Auto-renewal cron job already exists."
    fi

    # Test renewal configuration
    print_info "Testing renewal configuration..."
    if certbot renew --dry-run; then
        print_success "Auto-renewal setup completed successfully."
    else
        print_error "Renewal test failed. Please check configuration."
        return 1
    fi
}

# --- Setup Certbot Renewal ---
setup_certbot_renewal() {
    local domain="$1"

    # Create renewal configuration
    cat > "/etc/letsencrypt/renewal/$domain.conf" << EOF
renew_before_expiry = 30 days
[renewalparams]
authenticator = standalone
installer = nginx
account = $(certbot register --agree-tos --email "$EMAIL" 2>/dev/null | grep -o 'Account [^ ]*' | cut -d' ' -f2)
post_hook = /opt/nginx/certs/renewal_hook.sh
EOF

    log "Certbot renewal configured for $domain"
}

# --- Update Nginx HTTPS Configuration ---
update_nginx_https_config() {
    local domain="$1"

    # Create HTTPS configuration
    cat > /opt/nginx/conf.d/https.conf << EOF
# HTTPS configuration for $domain
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain www.$domain;

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

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
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

    print_success "HTTPS configuration created for $domain."
    print_info "Configuration file: /opt/nginx/conf.d/https.conf"
    print_info "Please reload Nginx to apply changes:"
    print_info "  cd /opt/nginx && docker-compose exec nginx nginx -s reload"
}