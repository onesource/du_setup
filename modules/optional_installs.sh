#!/bin/bash

# ============================================================================
# du_setup.sh - Optional Installs Module
# Handles Docker and Tailscale installation
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Docker Installation Function ---
install_docker() {
    if ! confirm "Install Docker Engine (Optional)?"; then
        print_info "Skipping Docker installation."
        return 0
    fi
    print_section "Docker Installation"
    if command -v docker >/dev/null 2>&1; then
        print_info "Docker already installed."
        return 0
    fi
    print_info "Removing old container runtimes..."
    apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true
    print_info "Adding Docker's official GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    print_info "Installing Docker packages..."
    if ! apt-get update -qq || ! apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        print_error "Failed to install Docker packages."
        exit 1
    fi
    print_info "Adding '$USERNAME' to docker group..."
    getent group docker >/dev/null || groupadd docker
    if ! groups "$USERNAME" | grep -qw docker; then
        usermod -aG docker "$USERNAME"
        print_success "User '$USERNAME' added to docker group."
    else
        print_info "User '$USERNAME' is already in docker group."
    fi
    print_info "Configuring Docker daemon..."
    local NEW_DOCKER_CONFIG
    NEW_DOCKER_CONFIG=$(mktemp)
    tee "$NEW_DOCKER_CONFIG" > /dev/null <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]] && cmp -s "$NEW_DOCKER_CONFIG" /etc/docker/daemon.json; then
        print_info "Docker daemon configuration already correct. Skipping."
        rm -f "$NEW_DOCKER_CONFIG"
    else
        mv "$NEW_DOCKER_CONFIG" /etc/docker/daemon.json
        chmod 644 /etc/docker/daemon.json
    fi
    systemctl daemon-reload
    systemctl enable --now docker
    print_info "Running Docker sanity check..."
    if sudo -u "$USERNAME" docker run --rm hello-world 2>&1 | tee -a "$LOG_FILE" | grep -q "Hello from Docker"; then
        print_success "Docker sanity check passed."
    else
        print_error "Docker hello-world test failed. Please verify installation."
        exit 1
    fi
    print_warning "NOTE: '$USERNAME' must log out and back in to use Docker without sudo."
    log "Docker installation completed."
}

# --- Tailscale Installation Function ---
install_tailscale() {
    if ! confirm "Install and configure Tailscale VPN (Optional)?"; then
        print_info "Skipping Tailscale installation."
        log "Tailscale installation skipped by user."
        return 0
    fi
    print_section "Tailscale VPN Installation and Configuration"

    # Check if Tailscale is already installed and active
    if command -v tailscale >/dev/null 2>&1; then
        if systemctl is-active --quiet tailscaled && tailscale ip >/dev/null 2>&1; then
            local TS_IPS TS_IPV4
            TS_IPS=$(tailscale ip 2>/dev/null || echo "Unknown")
            TS_IPV4=$(echo "$TS_IPS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || echo "Unknown")
            print_success "Service tailscaled is active and connected. Node IPv4 in tailnet: $TS_IPV4"
            echo "$TS_IPS" > /tmp/tailscale_ips.txt
        else
            print_warning "Service tailscaled is installed but not active or connected."
            FAILED_SERVICES+=("tailscaled")
            TS_COMMAND=$(grep "Tailscale connection failed: tailscale up" "$LOG_FILE" | tail -1 | sed 's/.*Tailscale connection failed: //')
            TS_COMMAND=${TS_COMMAND:-""}
        fi
    else
        print_info "Installing Tailscale..."
        # Gracefully handle download failures
        if ! curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale_install.sh; then
            print_error "Failed to download Tailscale installation script."
            print_info "After setup completes, please try installing it manually: curl -fsSL https://tailscale.com/install.sh | sh"
            rm -f /tmp/tailscale_install.sh # Clean up partial download
            return 0 # Exit function without exiting main script
        fi

        # Execute downloaded script with 'sh'
        if ! sh /tmp/tailscale_install.sh; then
            print_error "Tailscale installation script failed to execute."
            log "Tailscale installation failed."
            rm -f /tmp/tailscale_install.sh # Clean up
            return 0 # Exit function gracefully
        fi

        rm -f /tmp/tailscale_install.sh # Clean up successful install
        print_success "Tailscale installation complete."
        log "Tailscale installation completed."
    fi

    if systemctl is-active --quiet tailscaled && tailscale ip >/dev/null 2>&1; then
        local TS_IPS TS_IPV4
        TS_IPS=$(tailscale ip 2>/dev/null || echo "Unknown")
        TS_IPV4=$(echo "$TS_IPS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || echo "Unknown")
        print_info "Tailscale is already connected. Node IPv4 in tailnet: $TS_IPV4"
        echo "$TS_IPS" > /tmp/tailscale_ips.txt
        return 0
    fi

    if ! confirm "Configure Tailscale now?"; then
        print_info "You can configure Tailscale later by running: sudo tailscale up"
        print_info "If you are using a custom Tailscale server, use: sudo tailscale up --login-server=<your_server_url>"
        return 0
    fi

    print_info "Configuring Tailscale connection..."
    printf '%s\n' "${CYAN}Choose Tailscale connection method:${NC}"
    printf '  1) Standard Tailscale (requires pre-auth key from https://login.tailscale.com/admin)\n'
    printf '  2) Custom Tailscale server (requires server URL and pre-auth key)\n'
    read -rp "$(printf '%s' "${CYAN}Enter choice (1-2) [1]: ${NC}")" TS_CONNECTION
    TS_CONNECTION=${TS_CONNECTION:-1}
    local AUTH_KEY LOGIN_SERVER=""
    if [[ "$TS_CONNECTION" == "2" ]]; then
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter Tailscale server URL (e.g., https://ts.mydomain.cloud): ${NC}")" LOGIN_SERVER
            if [[ "$LOGIN_SERVER" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then break; else print_error "Invalid URL. Must start with https://. Try again."; fi
        done
    fi
    while true; do
        read -rsp "$(printf '%s' "${CYAN}Enter Tailscale pre-auth key: ${NC}")" AUTH_KEY
        printf '\n'
        if [[ "$TS_CONNECTION" == "1" && "$AUTH_KEY" =~ ^tskey-auth- ]]; then break
        elif [[ "$TS_CONNECTION" == "2" && -n "$AUTH_KEY" ]]; then
            print_warning "Ensure pre-auth key is valid for your custom Tailscale server ($LOGIN_SERVER)."
            break
        else
            print_error "Invalid key format. For standard connection, key must start with 'tskey-auth-'. For custom server, key cannot be empty."
        fi
    done
    local TS_COMMAND="tailscale up"
    if [[ "$TS_CONNECTION" == "2" ]]; then
        TS_COMMAND="$TS_COMMAND --login-server=$LOGIN_SERVER"
    fi
    TS_COMMAND="$TS_COMMAND --auth-key=$AUTH_KEY --operator=$USERNAME"
    TS_COMMAND_SAFE=$(echo "$TS_COMMAND" | sed -E 's/--auth-key=[^[:space:]]+/--auth-key=REDACTED/g')
    print_info "Connecting to Tailscale with: $TS_COMMAND_SAFE"
    if ! $TS_COMMAND; then
        print_warning "Failed to connect to Tailscale. Possible issues: invalid pre-auth key, network restrictions, or server unavailability."
        print_info "Please run the following command manually after resolving the issue:"
        printf '%s\n' "${CYAN}  $TS_COMMAND_SAFE${NC}"
        log "Tailscale connection failed: $TS_COMMAND_SAFE"
    else
        # Verify connection status with retries
        local RETRIES=3
        local DELAY=5
        local CONNECTED=false
        local TS_IPS TS_IPV4
        for ((i=1; i<=RETRIES; i++)); do
            if tailscale ip >/dev/null 2>&1; then
                TS_IPS=$(tailscale ip 2>/dev/null || echo "Unknown")
                TS_IPV4=$(echo "$TS_IPS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || echo "Unknown")
                if [[ -n "$TS_IPV4" && "$TS_IPV4" != "Unknown" ]]; then
                    CONNECTED=true
                    break
                fi
            fi
            print_info "Waiting for Tailscale to connect ($i/$RETRIES)..."
            sleep $DELAY
        done
        if $CONNECTED; then
            print_success "Tailscale connected successfully. Node IPv4 in tailnet: $TS_IPV4"
            log "Tailscale connected: $TS_COMMAND_SAFE"
            # Store connection details for summary
            echo "${LOGIN_SERVER:-https://controlplane.tailscale.com}" > /tmp/tailscale_server
            echo "$TS_IPS" > /tmp/tailscale_ips.txt
            echo "None" > /tmp/tailscale_flags
        else
            print_warning "Tailscale connection attempt succeeded, but no IPs assigned."
            print_info "Please verify with 'tailscale ip' and run the following command manually if needed:"
            printf '%s\n' "${CYAN}  $TS_COMMAND_SAFE${NC}"
            log "Tailscale connection not verified: $TS_COMMAND_SAFE"
            tailscale status > /tmp/tailscale_status.txt 2>&1
            log "Tailscale status output saved to /tmp/tailscale_status.txt for debugging"
        fi
    fi

    # --- Configure Additional Flags ---
    print_info "Select additional Tailscale options to configure (comma-separated, e.g., 1,3):"
    printf '%s\n' "${CYAN}  1) SSH (--ssh) - WARNING: May restrict server access to Tailscale connections only${NC}"
    printf '%s\n' "${CYAN}  2) Advertise as Exit Node (--advertise-exit-node)${NC}"
    printf '%s\n' "${CYAN}  3) Accept DNS (--accept-dns)${NC}"
    printf '%s\n' "${CYAN}  4) Accept Routes (--accept-routes)${NC}"
    printf '%s\n' "${CYAN}  Enter numbers (1-4) or leave blank to skip:${NC}"
    read -rp "  " TS_FLAG_CHOICES
    local TS_FLAGS=""
    if [[ -n "$TS_FLAG_CHOICES" ]]; then
        if echo "$TS_FLAG_CHOICES" | grep -q "1"; then
            TS_FLAGS="$TS_FLAGS --ssh"
        fi
        if echo "$TS_FLAG_CHOICES" | grep -q "2"; then
            TS_FLAGS="$TS_FLAGS --advertise-exit-node"
        fi
        if echo "$TS_FLAG_CHOICES" | grep -q "3"; then
            TS_FLAGS="$TS_FLAGS --accept-dns"
        fi
        if echo "$TS_FLAG_CHOICES" | grep -q "4"; then
            TS_FLAGS="$TS_FLAGS --accept-routes"
        fi
        if [[ -n "$TS_FLAGS" ]]; then
            TS_COMMAND="tailscale up"
            if [[ "$TS_CONNECTION" == "2" ]]; then
                TS_COMMAND="$TS_COMMAND --login-server=$LOGIN_SERVER"
            fi
            TS_COMMAND="$TS_COMMAND --auth-key=$AUTH_KEY --operator=$USERNAME $TS_FLAGS"
            TS_COMMAND_SAFE=$(echo "$TS_COMMAND" | sed -E 's/--auth-key=[^[:space:]]+/--auth-key=REDACTED/g')
            print_info "Reconfiguring Tailscale with additional options: $TS_COMMAND_SAFE"
            if ! $TS_COMMAND; then
                print_warning "Failed to reconfigure Tailscale with additional options."
                print_info "Please run the following command manually after resolving the issue:"
                printf '%s\n' "${CYAN}  $TS_COMMAND_SAFE${NC}"
                log "Tailscale reconfiguration failed: $TS_COMMAND_SAFE"
            else
                # Verify reconfiguration status with retries
                local RETRIES=3
                local DELAY=5
                local CONNECTED=false
                local TS_IPS TS_IPV4
                for ((i=1; i<=RETRIES; i++)); do
                    if tailscale ip >/dev/null 2>&1; then
                        TS_IPS=$(tailscale ip 2>/dev/null || echo "Unknown")
                        TS_IPV4=$(echo "$TS_IPS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || echo "Unknown")
                        if [[ -n "$TS_IPV4" && "$TS_IPV4" != "Unknown" ]]; then
                            CONNECTED=true
                            break
                        fi
                    fi
                    print_info "Waiting for Tailscale to connect ($i/$RETRIES)..."
                    sleep $DELAY
                done
                if $CONNECTED; then
                    print_success "Tailscale reconfigured with additional options. Node IPv4 in tailnet: $TS_IPV4"
                    log "Tailscale reconfigured: $TS_COMMAND_SAFE"
		    # Store flags and IPs for summary
                    echo "$TS_FLAGS" | sed 's/ --/ /g' | sed 's/^ *//' > /tmp/tailscale_flags
                    echo "$TS_IPS" > /tmp/tailscale_ips.txt
                else
                    print_warning "Tailscale reconfiguration attempt succeeded, but no IPs assigned."
                    print_info "Please verify with 'tailscale ip' and run the following command manually if needed:"
                    printf '%s\n' "${CYAN}  $TS_COMMAND_SAFE${NC}"
                    log "Tailscale reconfiguration not verified: $TS_COMMAND"
                    tailscale status > /tmp/tailscale_status.txt 2>&1
                    log "Tailscale status output saved to /tmp/tailscale_status.txt for debugging"
                fi
            fi
        else
            print_info "No valid Tailscale options selected."
            log "No valid Tailscale options selected."
        fi
    else
        print_info "No additional Tailscale options selected."
        log "No additional Tailscale options applied."
    fi
    print_success "Tailscale setup complete."
    print_info "Verify status: tailscale ip"
    log "Tailscale setup completed."
}