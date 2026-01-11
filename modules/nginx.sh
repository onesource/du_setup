#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Nginx Module
# Handles Nginx installation (containerized or host-based)
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Nginx Installation Function ---
install_nginx() {
    if ! confirm "Install Nginx web server (Optional)?"; then
        print_info "Skipping Nginx installation."
        log "Nginx installation skipped by user."
        return 0
    fi

    print_section "Nginx Installation"

    # Check if Nginx is already installed
    if command -v nginx >/dev/null 2>&1; then
        print_info "Nginx is already installed on the host."
        if confirm "Do you want to remove the host installation and use containerized Nginx instead?"; then
            remove_host_nginx
        else
            print_info "Keeping existing Nginx installation. Skipping container setup."
            log "Existing Nginx installation preserved."
            return 0
        fi
    fi

    # Check for existing Nginx containers
    NGINX_EXISTS=false
    if command -v docker >/dev/null 2>&1 && docker ps -a --format "table {{.Names}}" | grep -q "^nginx$"; then
        print_info "Nginx container already exists."
        NGINX_EXISTS=true
        if confirm "Do you want to remove the existing container and recreate it?"; then
            docker stop nginx >/dev/null 2>&1 || true
            docker rm nginx >/dev/null 2>&1 || true
            print_info "Existing Nginx container removed."
            NGINX_EXISTS=false
        else
            print_info "Keeping existing Nginx container."
            log "Existing Nginx container preserved."
        fi
    fi

    # Only ask for installation method if container doesn't exist
    if [[ "$NGINX_EXISTS" == "false" ]]; then
        # Ask for installation method
        printf '%s\n' "${CYAN}Choose Nginx installation method:${NC}"
        printf '  1) Containerized (recommended) - Docker container with Nginx%s\n' "$NC"
        printf '  2) Host-based - Direct installation on the system%s\n' "$NC"

        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter choice (1-2) [1]: ${NC}")" NGINX_INSTALL_METHOD
            NGINX_INSTALL_METHOD=${NGINX_INSTALL_METHOD:-1}
            case $NGINX_INSTALL_METHOD in
                1|2) break ;;
                *) print_error "Invalid choice. Please enter 1 or 2." ;;
            esac
        done

        case $NGINX_INSTALL_METHOD in
            1) install_nginx_container ;;
            2) install_nginx_host ;;
            esac
    fi

    # Offer security configuration options (always offer, even if container exists)
    if confirm "Configure additional Nginx security features?"; then
        configure_nginx_security
    fi
}

# --- Configure Nginx Security ---
configure_nginx_security() {
    print_section "Nginx Security Configuration"

    printf '%s\n' "${CYAN}Security Configuration Options:${NC}"
    printf '  1) Certificate Management%s\n' "$NC"
    printf '  2) Security Monitoring%s\n' "$NC"
    printf '  3) Vulnerability Scanning%s\n' "$NC"
    printf '  4) All Security Features%s\n' "$NC"

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter choice (1-4): ${NC}")" SECURITY_CHOICE
        case $SECURITY_CHOICE in
            1)
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_cert_manager.sh"
                manage_certificates
                ;;
            2)
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_monitoring.sh"
                setup_nginx_monitoring
                ;;
            3)
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_vuln_scanner.sh"
                manage_vulnerabilities || print_warning "Vulnerability scanning encountered errors"
                ;;
            4)
                # Install all security features
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_cert_manager.sh"
                manage_certificates

                source "$(dirname "${BASH_SOURCE[0]}")/nginx_monitoring.sh"
                setup_nginx_monitoring

                source "$(dirname "${BASH_SOURCE[0]}")/nginx_vuln_scanner.sh"
                manage_vulnerabilities || print_warning "Vulnerability scanning encountered errors"

                print_success "All security features configured."
                ;;
            *) print_error "Invalid choice. Please enter 1-4." ;;
        esac
        break
    done
}

# --- Containerized Nginx Installation ---
install_nginx_container() {
    print_info "Installing containerized Nginx..."

    # Check if Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker is not installed. Cannot install containerized Nginx."
        print_info "Please install Docker first or choose host-based installation."
        log "Docker not available for containerized Nginx installation."
        return 1
    fi

    # Create necessary directories
    print_info "Creating Nginx directories..."
    mkdir -p /opt/nginx/{html,conf.d,logs,certs}
    mkdir -p /opt/nginx/conf.d/{sites-available,sites-enabled}

    # Create secure Nginx configuration
    print_info "Creating secure Nginx configuration..."
    cat > /opt/nginx/nginx.conf << 'EOF'
# Security-hardened Nginx configuration
# Optimized for production deployment on netcup servers
#  (runs as UID 101)

# PID file location for unprivileged user
pid /tmp/nginx.pid;

# Worker processes (auto-detect CPU cores)
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    # Basic settings
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Temp paths for unprivileged user (UID 101)
    # Default paths require root privileges, so we use /tmp
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;

    # Security headers and settings
    server_tokens off;                    # Hide Nginx version
    # Note: more_clear_headers requires nginx-mod-http-headers-more module
    # Not included in standard nginx:alpine Docker image
    # If needed, use a custom Docker image with this module

    # Logging configuration
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for" '
                      'rt=$request_time uct="$upstream_connect_time" '
                      'uht="$upstream_header_time" urt="$upstream_response_time"';

    log_format  security '$remote_addr - $remote_user [$time_local] "$request" '
                         '$status $body_bytes_sent "$http_referer" '
                         '"$http_user_agent" "$http_x_forwarded_for" '
                         '$request_length $request_time $upstream_response_time';

    # Redirect main logs to Docker collector
    access_log /dev/stdout main;
    error_log /dev/stderr warn;

    # Keep security logs in a dedicated file for host-based scanning
    # This path is inside the container, but maps to /opt/nginx/logs/
    access_log  /var/log/nginx/security.log security;

    # Performance settings
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  15;
    keepalive_requests 100;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 128;
    client_max_body_size 16M;
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;
    ignore_invalid_headers on;
    reset_timedout_connection on;

    # Request limiting (DDoS protection)
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=general:10m rate=20r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit_per_ip:10m;

    # Connection limiting
    limit_conn conn_limit_per_ip 20;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;

    # Security headers include
    include /etc/nginx/conf.d/security-headers.conf;

    # Include site configurations
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    # Create security headers configuration
    cat > /opt/nginx/conf.d/security-headers.conf << 'EOF'
# Security headers for all sites
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
# Enhanced CSP to prevent XSS attacks
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self'; connect-src 'self'; frame-ancestors 'self'; form-action 'self'; object-src 'none'; base-uri 'self';" always;
# HSTS for HTTPS sites (only applied on HTTPS connections)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()" always;

# Remove server tokens
proxy_hide_header X-Powered-By;
proxy_hide_header Server;
# Note: To fully hide "Server: nginx" header, you need nginx-mod-http-headers-more module
# This requires building nginx from source with the headers-more module
EOF

    # Create default site configuration with security
    cat > /opt/nginx/conf.d/default.conf << 'EOF'
# Default site with security hardening
# Using nginxinc/nginx-unprivileged:alpine (runs on port 8080)
server {
    listen 8080;
    server_name default.localhost;

    # Security settings - Rate limiting enabled
    limit_req zone=general burst=40 nodelay;
    limit_conn conn_limit_per_ip 10;

    # Hide server information
    server_tokens off;
    # Note: To fully hide "Server: nginx" header, you need nginx-mod-http-headers-more module
    # This requires building nginx from source with the headers-more module
    # Use Dockerfile.headers-more for this functionality

    # Root directory
    root   /usr/share/nginx/html;
    index  index.html index.htm;

    # Health check endpoint - MUST BE FIRST to avoid conflicts with other location blocks
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network (172.20.0.1)
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
    location ~* \.(bak|backup|config|conf|ini|log|old|orig|save|sql|swp|tmp)$ {
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

    # Prevent access to hidden files and directories
    location ~* ^/\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Main location
    location / {
        try_files $uri $uri/ =404;

        # Security: Prevent clickjacking
        add_header X-Frame-Options "SAMEORIGIN" always;

        # Security: Prevent MIME-type sniffing
        add_header X-Content-Type-Options "nosniff" always;

        # Security: XSS protection
        add_header X-XSS-Protection "1; mode=block" always;

        # Security: Enhanced XSS protection via CSP
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self'; connect-src 'self'; frame-ancestors 'self'; form-action 'self'; object-src 'none'; base-uri 'self';" always;
    }

    # Nginx status (restricted to localhost)
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow 172.20.0.0/16; # Allow the Docker bridge network
        deny all;
        limit_req zone=general burst=5 nodelay;
    }

    # Error pages
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
        internal;
    }

    # Logging
    access_log  /var/log/nginx/default_access.log  main;
    error_log   /var/log/nginx/default_error.log warn;
}

# HTTPS redirect template (uncomment and configure for production)
# server {
#     listen 8080;
#     server_name your-domain.com;
#     return 301 https://$server_name$request_uri;
# }
#
# server {
#     listen 8443 ssl http2;
#     server_name your-domain.com;
#
#     # SSL configuration
#     ssl_certificate /etc/nginx/certs/cert.pem;
#     ssl_certificate_key /etc/nginx/certs/key.pem;
#     ssl_session_timeout 1d;
#     ssl_session_cache shared:SSL:50m;
#     ssl_session_tickets off;
#
#     # Modern SSL configuration
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
#     ssl_prefer_server_ciphers off;
#
#     # HSTS
#     add_header Strict-Transport-Security "max-age=63072000" always;
#
#     # Other security headers included from security-headers.conf
#
#     # Root and other configurations same as above
#     root /usr/share/nginx/html;
#     index  index.html index.htm;
#
#     # Health check endpoint - MUST BE FIRST to avoid conflicts with other location blocks
#     location /health {
#         access_log off;
#         allow all;  # Allow all IPs including Docker bridge network (172.20.0.1)
#         return 200 "healthy\n";
#         add_header Content-Type text/plain;
#     }
#
#     # ... (other location blocks)
# }
EOF

    # Create a simple index.html
    cat > /opt/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to Nginx</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin-top: 50px; }
        .container { max-width: 600px; margin: 0 auto; }
        .success { color: #4CAF50; }
    </style>
</head>
<body>
    <div class="container">
        <h1 class="success">Nginx is running successfully!</h1>
        <p>This page is served by Nginx running in a Docker container.</p>
        <p>Server time: <span id="time"></span></p>
    </div>
    <script>
        document.getElementById('time').textContent = new Date().toLocaleString();
    </script>
</body>
</html>
EOF

    # Create secure Dockerfile
    print_info "Creating secure Dockerfile..."
    cat > /opt/nginx/Dockerfile << 'EOF'
# Security-hardened Nginx Dockerfile
# Using nginxinc/nginx-unprivileged:alpine (runs as UID 101)
FROM nginxinc/nginx-unprivileged:alpine

# Update base packages and install security tools
USER root
RUN apk update && apk upgrade && \
    apk add --no-cache curl ca-certificates && \
    # Create temp directories and set ownership BEFORE switching users
    mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp && \
    chown -R 101:101 /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx && \
    rm -rf /var/cache/apk/*

# Switch back to unprivileged user
USER 101

# Copy custom configuration
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/
COPY html/ /usr/share/nginx/html/

# Note: Container runs as UID 101 (unprivileged)
# - Cannot bind to ports below 1024, so we use 8080/8443
# - PID file is in /tmp/nginx.pid (writable by unprivileged user)
# - No user directive needed in nginx.conf (handled by image)

# Health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose ports (unprivileged ports)
EXPOSE 8080 8443

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
EOF

    # Create Dockerfile with headers-more module (optional)
    cat > /opt/nginx/Dockerfile.headers-more << 'EOF'
# Security-hardened Nginx Dockerfile with headers-more module
# This version includes nginx-mod-http-headers-more for more_clear_headers directive
# Using nginxinc/nginx-unprivileged:alpine as base (runs as UID 101)
FROM nginxinc/nginx-unprivileged:alpine

# Update base packages and build tools
USER root
RUN apk update && apk upgrade && \
    apk add --no-cache \
        build-base \
        pcre-dev \
        openssl-dev \
        zlib-dev \
        linux-headers \
        curl \
        ca-certificates \
        git \
    && rm -rf /var/cache/apk/*

# Clone and build nginx with headers-more module
RUN git clone --depth 1 https://github.com/openresty/headers-more-nginx-module.git /tmp/headers-more && \
    git clone --depth 1 https://github.com/nginx/nginx.git /tmp/nginx && \
    cd /tmp/nginx && \
    git checkout $(git tag -l "release-*" | sort -V | tail -1) && \
    ./auto/configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/tmp/nginx.pid \
        --lock-path=/tmp/nginx.lock \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_gzip_static_module \
        --with-file-aio \
        --with-http_realip_module \
        --with-stream \
        --with-pcre \
        --add-module=/tmp/headers-more && \
    make -j$(nproc) && \
    make install && \
    cd / && \
    rm -rf /tmp/nginx /tmp/headers-more && \
    apk del build-base pcre-dev openssl-dev zlib-dev linux-headers git

# Switch back to unprivileged user
USER 101

# Copy custom configuration
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/
COPY html/ /usr/share/nginx/html/

# Note: Container runs as UID 101 (unprivileged)
# - Cannot bind to ports below 1024, so we use 8080/8443
# - PID file is in /tmp/nginx.pid (writable by unprivileged user)
# - No user directive needed in nginx.conf (handled by image)

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose ports (unprivileged ports)
EXPOSE 8080 8443

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
EOF

    print_info "Note: Standard Dockerfile uses nginxinc/nginx-unprivileged:alpine image (recommended for security)."
    print_info "      Dockerfile.headers-more includes headers-more module for more_clear_headers directive."
    print_info "      To use headers-more module, uncomment 'more_clear_headers' directives in configs"
    print_info "      and use: docker build -f Dockerfile.headers-more -t nginx-nginx ."

    # Create secure Docker Compose file
    print_info "Creating secure Docker Compose configuration..."
    cat > /opt/nginx/docker-compose.yml << 'EOF'
services:
  nginx:
    build: .
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:8080"
      - "443:8443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./html:/usr/share/nginx/html:ro
      - ./logs:/var/log/nginx
      - ./certs:/etc/nginx/certs:ro
    networks:
      - nginx-network
    security_opt:
      - no-new-privileges:true
    # Note: read_only and tmpfs removed to fix permission issues with nginx user (UID 101)
    # The nginx user needs write access to /var/cache/nginx and /var/run
    ulimits:
      nproc: 65535
      nofile:
        soft: 20000
        hard: 40000
    pids_limit: 100
    cpu_shares: 512
    mem_limit: 512m
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  nginx-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF

    # Create Docker Compose file for headers-more module (optional)
    cat > /opt/nginx/docker-compose.headers-more.yml << 'EOF'
services:
  nginx:
    build:
      context: .
      dockerfile: Dockerfile.headers-more
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:8080"
      - "443:8443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./html:/usr/share/nginx/html:ro
      - ./logs:/var/log/nginx
      - ./certs:/etc/nginx/certs:ro
    networks:
      - nginx-network
    security_opt:
      - no-new-privileges:true
    # Note: read_only and tmpfs removed to fix permission issues with nginx user (UID 101)
    # The nginx user needs write access to /var/cache/nginx and /var/run
    ulimits:
      nproc: 65535
      nofile:
        soft: 20000
        hard: 40000
    pids_limit: 100
    cpu_shares: 512
    mem_limit: 512m
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  nginx-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF

    # --- Prepare for Deployment ---
    print_info "Preparing Nginx environment..."

    # Create the directory first if it doesn't exist
    mkdir -p /opt/nginx/logs
    mkdir -p /opt/nginx/certs

    # 1. Pre-create log files to prevent Docker from creating them as root directories
    # This prevents Docker from auto-creating them as root-owned directories
    touch /opt/nginx/logs/security.log
    touch /opt/nginx/logs/access.log
    touch /opt/nginx/logs/error.log

    # 2. Set proper permissions for unprivileged nginx (UID 101)
    print_info "Applying file permissions for unprivileged user..."
    chown -R "$USERNAME:$USERNAME" /opt/nginx
    chmod -R 755 /opt/nginx

    # Logs MUST be writable by nginx user (UID 101) inside container
    chown -R 101:101 /opt/nginx/logs
    chmod -R 775 /opt/nginx/logs

    # Certs MUST be readable by container's nginx user (UID 101)
    if [[ -d /opt/nginx/certs ]]; then
        chown -R 101:101 /opt/nginx/certs
        # Ensure files are readable but directory remains searchable
        find /opt/nginx/certs -type f -exec chmod 644 {} +
        chmod 755 /opt/nginx/certs
    fi

    # 3. Start Nginx container
    print_info "Starting Nginx container..."
    cd /opt/nginx || { print_error "Failed to enter /opt/nginx"; return 1; }

    if docker compose up -d; then
        print_success "Nginx container started successfully."

        # Wait for container to be ready
        local retries=20
        local delay=5
        local health_passed=false

        for ((i=1; i<=retries; i++)); do
            # Check if container is running
            if docker ps --format "table {{.Names}}" | grep -q "^nginx$"; then
                # Check health from within container (using port 8080)
                if docker exec nginx curl -f http://localhost:8080/health >/dev/null 2>&1; then
                    print_success "Nginx is responding to health checks."
                    health_passed=true
                    break
                fi
            fi

            # Also try from host (using port 80)
            if curl -f http://localhost/health >/dev/null 2>&1; then
                print_success "Nginx is responding to health checks from host."
                health_passed=true
                break
            fi

            if [[ $i -eq $retries ]]; then
                print_warning "Nginx container started but health check failed after $retries attempts."
                print_info "Container may still be initializing. Check logs with: cd /opt/nginx && docker compose logs -f"
            fi
            sleep $delay
        done

        # Show container status
        if [[ "$health_passed" == "false" ]]; then
            print_info "Container status:"
            docker ps --filter name=nginx --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        fi

        # Configure firewall if UFW is available
        if command -v ufw >/dev/null 2>&1; then
            print_info "Configuring firewall for Nginx..."
            ufw allow 80/tcp >/dev/null 2>&1 && print_success "Allowed HTTP traffic (port 80)."
            ufw allow 443/tcp >/dev/null 2>&1 && print_success "Allowed HTTPS traffic (port 443)."
        fi

        print_info "Nginx container management commands:"
        print_info "  Start: cd /opt/nginx && docker compose up -d"
        print_info "  Stop: cd /opt/nginx && docker compose down"
        print_info "  Restart: cd /opt/nginx && docker compose restart"
        print_info "  Logs: cd /opt/nginx && docker compose logs -f"
        print_info "  Config location: /opt/nginx/"
        print_info ""
        print_info "Configuration files are mounted from host to container:"
        print_info "  Main config: /opt/nginx/nginx.conf"
        print_info "  Site configs: /opt/nginx/conf.d/"
        print_info "  Web files: /opt/nginx/html/"
        print_info "  Logs: /opt/nginx/logs/"
        print_info "  SSL certs: /opt/nginx/certs/"
        print_info ""
        print_info "If previous Nginx container was unhealthy, it may have been left in a broken state."
        print_info "After unhealthy container removal and reinstallation, you may need to rebuild and restart:"
        print_info "  cd /opt/nginx && docker compose down && docker compose up -d --build"
        print_info ""
        print_info "Edit files on the host and reload Nginx: cd /opt/nginx && docker compose exec nginx nginx -s reload"
        print_info ""
        print_info "SECURITY NOTE: This setup uses nginxinc/nginx-unprivileged:alpine (runs as UID 101)."
        print_info "  - Container runs as non-root user for enhanced security"
        print_info "  - Nginx listens on port 8080/8443 inside container"
        print_info "  - Docker maps host ports 80/443 to container ports 8080/8443"
        print_info "  - PID file is in /tmp/nginx.pid (writable by unprivileged user)"
        print_info ""
        print_info "To use more_clear_headers directive (requires headers-more module):"
        print_info "  1. Uncomment 'more_clear_headers' lines in /opt/nginx/nginx.conf"
        print_info "  2. Uncomment 'more_clear_headers' lines in /opt/nginx/conf.d/default.conf"
        print_info "  3. Build custom image: cd /opt/nginx && docker build -f Dockerfile.headers-more -t nginx-nginx ."
        print_info "  4. Use custom compose: cd /opt/nginx && docker compose -f docker-compose.headers-more.yml up -d"

        log "Containerized Nginx installation completed successfully."
    else
        print_error "Failed to start Nginx container."
        log "Containerized Nginx installation failed."
        return 1
    fi
}

# --- Host-based Nginx Installation ---
install_nginx_host() {
    print_info "Installing Nginx on the host..."

    # Update package index
    print_info "Updating package index..."
    apt-get update -qq

    # Install Nginx
    print_info "Installing Nginx package..."
    if ! apt-get install -y -qq nginx; then
        print_error "Failed to install Nginx package."
        log "Host-based Nginx installation failed."
        return 1
    fi

    # Enable and start Nginx service
    print_info "Enabling and starting Nginx service..."
    systemctl enable nginx
    systemctl start nginx

    # Wait for service to start
    local retries=10
    local delay=2
    for ((i=1; i<=retries; i++)); do
        if systemctl is-active --quiet nginx; then
            print_success "Nginx service is running."
            break
        fi
        if [[ $i -eq $retries ]]; then
            print_error "Nginx service failed to start after $retries attempts."
            log "Host-based Nginx service failed to start."
            return 1
        fi
        sleep $delay
    done

    # Configure firewall if UFW is available
    if command -v ufw >/dev/null 2>&1; then
        print_info "Configuring firewall for Nginx..."
        ufw allow 'Nginx Full' >/dev/null 2>&1 && print_success "Allowed Nginx traffic (HTTP/HTTPS)."
    fi

    # Test Nginx installation
    print_info "Testing Nginx installation..."
    if curl -f http://localhost >/dev/null 2>&1; then
        print_success "Nginx is responding correctly."
    else
        print_warning "Nginx is running but not responding to requests."
    fi

    print_info "Nginx host management commands:"
    print_info "  Start: sudo systemctl start nginx"
    print_info "  Stop: sudo systemctl stop nginx"
    print_info "  Restart: sudo systemctl restart nginx"
    print_info "  Status: sudo systemctl status nginx"
    print_info "  Config location: /etc/nginx/"
    print_info "  Web root: /var/www/html/"

    log "Host-based Nginx installation completed successfully."
}

# --- Remove Host-based Nginx ---
remove_host_nginx() {
    print_info "Removing host-based Nginx installation..."

    # Stop and disable service
    systemctl stop nginx >/dev/null 2>&1 || true
    systemctl disable nginx >/dev/null 2>&1 || true

    # Remove package
    apt-get remove --purge -y nginx nginx-common nginx-full >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    # Remove configuration files (preserve user data)
    print_info "Backing up existing Nginx configuration..."
    if [[ -d /etc/nginx ]]; then
        mv /etc/nginx /etc/nginx.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    fi

    print_success "Host-based Nginx installation removed."
    log "Host-based Nginx installation removed."
}
