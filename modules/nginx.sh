#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Nginx Module
# Handles Nginx installation (containerized or host-based)
# ============================================================================

# Source dependencies
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Nginx Installation Function ---
install_nginx() {
    local installed=false enabled=false desired
    if command -v nginx >/dev/null 2>&1 || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx nginx; then
        installed=true
    fi
    if systemctl is-active --quiet nginx 2>/dev/null || docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx; then
        enabled=true
    fi
    desired=$(prompt_component_desired nginx "Nginx" "$installed" "$enabled") || return 1
    state_set component.nginx "$desired"
    if [[ "$desired" != "true" ]]; then
        print_info "Nginx will remain uninstalled or disabled."
        return 0
    fi
    print_section "Nginx Installation"

    # Check if Docker is available (required for containerized)
    if ! command -v docker >/dev/null 2>&1; then
        print_warning "Docker not found. Host-only installation available."
    fi

    # Check existing system nginx
    if command -v nginx >/dev/null 2>&1; then
        print_info "System Nginx already installed."
        if confirm "Remove host Nginx and use containerized instead?"; then
            remove_host_nginx
        else
            print_info "Keeping system Nginx. Skipping container setup."
            log "Existing system Nginx preserved."
            configure_nginx_security  # Still offer security
            return 0
        fi
    fi

    # Check existing container
    local container_exists=false
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        print_info "Nginx container exists (running/stopped)."
        container_exists=true
        if confirm "Remove existing container and recreate?"; then
            docker stop nginx >/dev/null 2>&1 || true
            docker rm nginx >/dev/null 2>&1 || true
            print_info "Container removed."
            container_exists=false
        else
            print_info "Keeping existing container."
            log "Existing container preserved."
            # An unknown hostname must keep serving the default page. Named sites
            # listen on the same ports and would otherwise become the fallback.
            apply_nginx_default_site || return 1
        fi
    fi

    # Install if no existing setup
    if [[ "$container_exists" == "false" ]]; then
        local backend
        backend=$(state_get nginx.backend container)
        if [[ "$backend" != "container" && "$backend" != "host" ]]; then
            backend=container
        fi
        if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
            printf '%s
' "${CYAN}Choose Nginx backend (current/default: $backend):${NC}"
            printf '  1) Container backend (recommended; requires Compose v2)
'
            printf '  2) Host backend
'
            local method
            read -rp "$(printf '%s' "${CYAN}Enter choice [${backend}]: ${NC}")" method
            case "$method" in
                1|container) backend=container ;;
                2|host) backend=host ;;
                '') ;;
                *) print_error "Invalid Nginx backend."; return 1 ;;
            esac
        fi
        state_set nginx.backend "$backend"
        case "$backend" in
            container) install_nginx_container ;;
            host) install_nginx_host ;;
        esac
    fi

    # Offer security configuration options (always offer, even if container exists)
    if confirm "Configure Nginx security features?"; then
        configure_nginx_security
    fi
}

# --- Configure Nginx Security ---
configure_nginx_security() {
    while true; do
        print_section "Nginx Security Configuration"

        printf '%s\n' "${CYAN}Security Configuration Options:${NC}"
        printf '  0) Return to Main Menu%s\n' "$NC"
        printf '  1) Certificate Management%s\n' "$NC"
        printf '  2) Security Monitoring%s\n' "$NC"
        printf '  3) Vulnerability Scanning%s\n' "$NC"
        printf '  4) All Security Features%s\n' "$NC"

        read -rp "$(printf '%s' "${CYAN}Enter choice (0-4): ${NC}")" SECURITY_CHOICE
        case $SECURITY_CHOICE in
            0)
                print_info "Returning to main menu..."
                return 0
                ;;
            1)
                # shellcheck disable=SC1091
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_cert_manager.sh"
                manage_certificates
                ;;
            2)
                # shellcheck disable=SC1091
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_monitoring.sh"
                setup_nginx_monitoring
                ;;
            3)
                # shellcheck disable=SC1091
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_vuln_scanner.sh"
                manage_vulnerabilities || print_warning "Vulnerability scanning encountered errors"
                ;;
            4)
                # Install all security features
                # shellcheck disable=SC1091
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_cert_manager.sh" 2>/dev/null || true
                manage_certificates

                # shellcheck disable=SC1091
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_monitoring.sh"   2>/dev/null || true
                setup_nginx_monitoring

                # shellcheck disable=SC1091
                source "$(dirname "${BASH_SOURCE[0]}")/nginx_vuln_scanner.sh"  2>/dev/null || true
                manage_vulnerabilities || print_warning "Vulnerability scanning encountered errors"

                print_success "All security features configured."
                ;;
            *) print_error "Invalid choice. Please enter 0-4." ;;
        esac
    done
}

# absent: nginx_nginx-network does not exist.
# current: the live network already has ip_range 172.20.128.0/17.
# legacy: the network exists without that range.
nginx_live_network_ipam_state() {
    local config
    if ! config=$(docker network inspect nginx_nginx-network --format '{{json .IPAM.Config}}' 2>/dev/null); then
        printf 'absent\n'
        return 0
    fi
    if [[ "$config" == *172.20.128.0/17* ]]; then
        printf 'current\n'
    else
        printf 'legacy\n'
    fi
}

nginx_compose_ipam_yaml() {
    local state="$1"
    if [[ "$state" == "legacy" ]]; then
        printf '%s\n' '        # Live network has no ip_range. Left unchanged so Compose does not recreate it.' \
            '        - subnet: 172.20.0.0/16'
        return 0
    fi
    printf '%s\n' '        - subnet: 172.20.0.0/16' \
        '          ip_range: 172.20.128.0/17' \
        '          gateway: 172.20.0.1'
}

warn_legacy_nginx_network() {
    print_warning "nginx_nginx-network already exists without ip_range 172.20.128.0/17. Skipping network changes so Compose does not recreate nginx_nginx-network and take Nginx down. The installer never recreates this network."
    print_warning "Applying the range is a planned maintenance-window step and needs George's approval. Do not use 'docker network rm' or 'docker network create'. Follow the README section \"Recreating nginx_nginx-network\"."
}

# Write the container Compose file. An existing network without ip_range keeps
# the subnet-only block so a later `docker compose up` does not recreate it.
write_nginx_container_compose() {
    local dest="$1"
    local network_state ipam_yaml
    network_state=$(nginx_live_network_ipam_state)
    if [[ "$network_state" == "legacy" ]]; then
        warn_legacy_nginx_network
    fi
    ipam_yaml=$(nginx_compose_ipam_yaml "$network_state")
    cat > "$dest" << EOF
services:
  nginx:
    build: .
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:8080"
      - "443:8443"
      - "8080:8082"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./html:/usr/share/nginx/html:ro
      - ./dashboard:/opt/nginx/dashboard:ro
      - ./logs:/var/log/nginx
      - ./certs:/etc/nginx/certs:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro  # Optional LE mount
    networks:
      nginx-network:
        ipv4_address: 172.20.0.2
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
      - /var/cache/nginx
      - /var/run
    ulimits:
      nproc: 65535
      nofile:
        soft: 20000
        hard: 40000
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '0.5'
        reservations:
          cpus: '0.1'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: 3

networks:
  nginx-network:
    driver: bridge
    ipam:
      config:
${ipam_yaml}
EOF
}

# Write the catch-all site. Host ports 80 and 443 reach this server when a
# hostname has no site of its own, and the page is /opt/nginx/html/index.html.
write_nginx_default_conf() {
    local dest="$1"
    cat > "$dest" << 'EOF'
# Default site for hostnames that do not have their own server block.
# Ports 80 and 443 on the host map to 8080 and 8443. This server is
# default_server so another site cannot answer those requests.
server {
    listen 8080 default_server;
    listen 8443 ssl default_server;
    server_name _;

    ssl_certificate /etc/nginx/certs/default.pem;
    ssl_certificate_key /etc/nginx/certs/default.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Security settings - Rate limiting enabled
    limit_req zone=general burst=40 nodelay;
    limit_conn conn_limit_per_ip 10;

    server_tokens off;

    # /opt/nginx/html is mounted at this path
    root   /usr/share/nginx/html;
    index  index.html index.htm;

    location /health {
        access_log off;
        allow all;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

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

    location ~* \.(bak|backup|config|conf|ini|log|old|orig|save|sql|swp|tmp)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~* \.(conf|config|ini|log|sql|sh|py|pl)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~* ^/\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow 172.20.0.0/16;
        deny all;
        limit_req zone=general burst=5 nodelay;
    }

    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
        internal;
    }

    access_log  /var/log/nginx/default_access.log  main;
    error_log   /var/log/nginx/default_error.log warn;
}
EOF
}

ensure_nginx_default_certificate() {
    local prefix="${NGINX_PREFIX:-/opt/nginx}"
    local cert="$prefix/certs/default.pem"
    local key="$prefix/certs/default.key"
    mkdir -p "$prefix/certs"
    if [[ -s "$cert" && -s "$key" ]]; then
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        print_error "openssl is required to create the default Nginx certificate."
        return 1
    fi
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$key" -out "$cert" -days 3650 \
        -subj "/CN=nginx-default" >/dev/null 2>&1 || return 1
    chown 101:101 "$cert" "$key" 2>/dev/null || true
    chmod 644 "$cert"
    chmod 600 "$key"
}

# Install the catch-all site and reload a running container after nginx -t.
# A failed test restores the previous default.conf.
apply_nginx_default_site() {
    local prefix="${NGINX_PREFIX:-/opt/nginx}"
    local dest="$prefix/conf.d/default.conf"
    local backup=""
    mkdir -p "$prefix/conf.d" "$prefix/html"
    ensure_nginx_default_certificate || return 1
    if [[ -f "$dest" ]]; then
        backup=$(mktemp)
        cp "$dest" "$backup"
    fi
    write_nginx_default_conf "$dest"
    chown 101:101 "$dest" 2>/dev/null || true
    chmod 644 "$dest"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx; then
        if ! docker exec nginx nginx -t; then
            if [[ -n "$backup" ]]; then
                cp "$backup" "$dest"
                print_error "Nginx rejected the default site. The previous default.conf was restored."
            else
                rm -f "$dest"
                print_error "Nginx rejected the default site."
            fi
            rm -f "$backup"
            return 1
        fi
        if ! docker exec nginx nginx -s reload; then
            rm -f "$backup"
            print_error "Nginx accepted the default site but the reload failed."
            return 1
        fi
        print_success "Unknown hostnames now serve the default Nginx page."
    fi
    rm -f "$backup"
}

# --- Containerized Nginx Installation ---
install_nginx_container() {
    if ! docker compose version >/dev/null 2>&1; then
        print_error "The container Nginx backend requires Docker Compose v2."
        return 1
    fi
    state_set nginx.backend container
    print_info "Installing containerized Nginx (nginxinc/nginx-unprivileged:alpine)..."

    # Check if Docker is available
    command -v docker >/dev/null 2>&1 || { print_error "Docker required. Please install first."; return 1; }

    # Create necessary directories
    print_info "Creating Nginx directories..."
    mkdir -p /opt/nginx/{html,conf.d,logs,certs}

    # Pre-create logs to avoid root ownership
    touch /opt/nginx/logs/{access.log,error.log,security.log}

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
    access_log /var/log/nginx/security.log security;

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
}
EOF

    # Create security headers configuration
    cat > /opt/nginx/conf.d/security-headers.conf << 'EOF'
# Security headers for all sites
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
# Enhanced CSP to prevent XSS attacks (allows Chart.js CDN for dashboard)
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; img-src 'self' data: https:; font-src 'self' https://cdn.jsdelivr.net; connect-src 'self' https://cdn.jsdelivr.net; frame-ancestors 'self'; form-action 'self'; object-src 'none'; base-uri 'self';" always;
# HSTS for HTTPS sites (only applied on HTTPS connections)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()" always;

# Remove server tokens
proxy_hide_header X-Powered-By;
proxy_hide_header Server;
# Note: To fully hide "Server: nginx" header, you need nginx-mod-http-headers-more module
# This requires building nginx from source with the headers-more module
EOF

    # Unknown hostnames serve /opt/nginx/html/index.html on ports 80 and 443.
    apply_nginx_default_site || return 1
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
RUN apk update && apk upgrade && apk add --no-cache curl ca-certificates && \
    # Create temp directories and set ownership BEFORE switching users
    mkdir -p /tmp/client_temp /var/cache/nginx /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp && \
    chown -R 101:101 /tmp/client_temp /var/cache/nginx /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp && \
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

    print_info "Note: Standard Dockerfile uses nginxinc/nginx-unprivileged:alpine image (recommended for security)."

    # Create secure Docker Compose file. A live network without ip_range keeps
    # its current IPAM so Compose does not recreate the network on rerun.
    print_info "Creating secure Docker Compose configuration..."
    write_nginx_container_compose /opt/nginx/docker-compose.yml



    # --- Prepare for Deployment ---
    print_info "Setting up permissions..."

    # Set proper permissions AFTER all files exist for unprivileged nginx (UID 101)
    print_info "Applying file permissions for unprivileged user..."
    # Ensure nginx can read its own configuration files
    chown -R 101:101 /opt/nginx/{conf.d,logs,certs,html,nginx.conf}
    chmod -R 755 /opt/nginx

    # MUST be writable by nginx user (UID 101) inside container
    chmod -R 775 /opt/nginx/logs
    chmod 644 /opt/nginx/nginx.conf /opt/nginx/conf.d/* /opt/nginx/html/*

    # Start Nginx container
    print_info "Starting Nginx container..."
    cd /opt/nginx || { print_error "Failed to enter /opt/nginx"; return 1; }
    if ! run_docker_compose up -d --build; then
        print_error "Failed to start Nginx container."
        log "Containerized Nginx installation failed."
        return 1
    fi
    print_success "Nginx container started successfully."

        # Wait for container to be ready
        local retries=20 delay=5 health_passed=false
        for ((i=1; i<=retries; i++)); do
            # Check if container is running
            if docker ps --format '{{.Names}}' | grep -qx 'nginx' && \
                # Check health from within container (using port 8080)
                docker exec nginx curl -f http://localhost:8080/health >/dev/null 2>&1; then
                    print_success "Nginx is responding to health checks."
                    health_passed=true
                    break
            fi
            sleep $delay
        done

        [[ "$health_passed" == "true" ]] || print_warning "Health check failed after $retries attempts. Check: docker compose logs"

            # Show container status
            if [[ "$health_passed" == "false" ]]; then
                print_info "Container status:"
                docker ps --filter name=nginx --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                print_success "Containerized Nginx ready."
            fi

            # Configure firewall if UFW is available
            if command -v ufw >/dev/null 2>&1; then
                print_info "Configuring firewall for Nginx..."
                ufw allow 8080/tcp >/dev/null 2>&1 && print_success "HTTP (8080) allowed"
                ufw allow 8443/tcp >/dev/null 2>&1 && print_success "HTTPS (8443) allowed"
            fi

            print_info "Nginx container management commands:"
            print_info "  Start: cd /opt/nginx && docker compose up -d"
            print_info "  Stop: cd /opt/nginx && docker compose down"
            print_info "  Restart: cd /opt/nginx && docker compose restart"
            print_info "  Logs: cd /opt/nginx && docker compose logs -f --tail 50"
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

            log "Containerized Nginx installed successfully."
}

# --- Host-based Nginx Installation ---
install_nginx_host() {
    state_set nginx.backend host
    print_info "Installing Nginx on the host..."

    # Unified setup FIRST
    mkdir -p /opt/nginx/{conf.d,html,logs,certs}

    # Remove existing /etc/nginx if it exists
    rm -rf /etc/nginx

    # Create symbolic link to unified directory
    ln -sfn /opt/nginx /etc/nginx

    # Set ownership and permissions
    chown -R www-data:www-data /opt/nginx
    chmod -R 755 /opt/nginx
    chmod -R 775 /opt/nginx/logs
    chmod 644 /opt/nginx/conf.d/* /opt/nginx/certs/*.pem 2>/dev/null || true

    print_info "Updating package index..."
    # apt install
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
    local retries=10 delay=2
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
        ufw allow 80/tcp  >/dev/null 2>&1 && print_success "HTTP ✓"
        ufw allow 443/tcp >/dev/null 2>&1 && print_success "HTTPS ✓"
        ufw reload >/dev/null 2>&1
    fi

    # Test Nginx installation
    print_info "Testing Nginx installation..."
    if nginx -t && curl -f http://localhost >/dev/null 2>&1; then
        print_success "Unified config + response"
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
    print_info "  Unified: /opt/nginx/{conf.d/,certs/,logs/}"

    log "Host nginx unified install done."
}

# --- Remove Host-based Nginx ---
remove_host_nginx() {
    print_info "Removing host nginx (preserves /opt/nginx/ data)..."

    # Stop and disable nginx if present
    if command -v systemctl >/dev/null; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
    fi

    # Remove nginx package (Debian/Ubuntu or Alpine)
    if command -v apt-get >/dev/null; then
        apt-get remove --purge -y nginx nginx-common nginx-core >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    fi

    # Backup legacy /etc/nginx if it exists and is NOT a symlink
    if [[ -d /etc/nginx && ! -L /etc/nginx ]]; then
        local backup
        backup="/etc/nginx.backup.$(date +%Y%m%d_%H%M%S)"
        mv /etc/nginx "$backup" 2>/dev/null || true
        print_info "Backed up legacy configs: $backup"
    fi

    # Clean known nginx paths (safe)
    rm -rf /var/log/nginx /var/www/html 2>/dev/null || true

    # Remove empty /etc/nginx dir only if it still exists and is empty
    if [[ -d /etc/nginx && -z "$(ls -A /etc/nginx 2>/dev/null)" ]]; then
        rmdir /etc/nginx 2>/dev/null || true
    fi

    print_success "Host Nginx installation removed ( /opt/nginx/ preserved )."
    log "Host nginx removed."
}

# --- Remove Nginx Docker Container ---
remove_container_nginx() {
    local CONTAINER_NAME="nginx"

    print_info "Removing nginx Docker container (unprivileged image, data preserved)..."

    # Docker installed?
    if ! command -v docker >/dev/null; then
        print_warning "Docker not installed. Skipping container removal."
        return 0
    fi

    # Docker daemon running?
    if ! docker info >/dev/null 2>&1; then
        print_warning "Docker daemon not running. Skipping container removal."
        return 0
    fi

    # Stop container if running
    if docker ps -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
        print_info "Stopping container: $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Remove container if it exists
    if docker ps -aq -f name="^/${CONTAINER_NAME}$" | grep -q .; then
        print_info "Removing container: $CONTAINER_NAME"
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Remove image only if unused
    docker system prune -f -q >/dev/null 2>&1 || true

    print_success "Container nginx removed (/opt/nginx/ preserved)."
    log "Nginx Docker container removed."
}
