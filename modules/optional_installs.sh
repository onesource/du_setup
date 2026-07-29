#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Optional Installs Module
# Handles Docker and Tailscale installation
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Docker Installation Function ---
install_docker() {
    local installed=false enabled=false desired
    command -v docker >/dev/null 2>&1 && installed=true
    if [[ "$installed" == "true" ]] && systemctl is-enabled --quiet docker 2>/dev/null && systemctl is-active --quiet docker; then
        enabled=true
    fi
    desired=$(prompt_component_desired docker "Docker Engine" "$installed" "$enabled") || return 1
    state_set component.docker "$desired"
    if [[ "$desired" != "true" ]]; then
        print_info "Docker will remain uninstalled or disabled."
        return 0
    fi

    print_section "Docker Installation"
    if [[ "$installed" == "true" ]]; then
        if ! docker compose version >/dev/null 2>&1; then
            print_info "Installing the required Docker Compose v2 plugin..."
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin
        fi
        systemctl enable --now docker
        print_info "Docker and Compose v2 are installed; preserving existing daemon configuration."
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
    command -v jq >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
    local MERGED_DOCKER_CONFIG
    MERGED_DOCKER_CONFIG=$(mktemp)
    if [[ -f /etc/docker/daemon.json ]]; then
        if ! jq empty /etc/docker/daemon.json >/dev/null 2>&1; then
            print_error "/etc/docker/daemon.json is not valid JSON; refusing to overwrite it."
            rm -f "$NEW_DOCKER_CONFIG" "$MERGED_DOCKER_CONFIG"
            return 1
        fi
        jq -s '.[0] * .[1]' /etc/docker/daemon.json "$NEW_DOCKER_CONFIG" > "$MERGED_DOCKER_CONFIG"
    else
        cp "$NEW_DOCKER_CONFIG" "$MERGED_DOCKER_CONFIG"
    fi
    rm -f "$NEW_DOCKER_CONFIG"
    if command -v dockerd >/dev/null 2>&1 && ! dockerd --validate --config-file "$MERGED_DOCKER_CONFIG"; then
        print_error "The merged Docker daemon configuration failed validation."
        rm -f "$MERGED_DOCKER_CONFIG"
        return 1
    fi
    if [[ -f /etc/docker/daemon.json ]] && cmp -s "$MERGED_DOCKER_CONFIG" /etc/docker/daemon.json; then
        print_info "Docker daemon configuration already correct. Skipping."
        rm -f "$MERGED_DOCKER_CONFIG"
    else
        install -m 0644 "$MERGED_DOCKER_CONFIG" /etc/docker/daemon.json
        rm -f "$MERGED_DOCKER_CONFIG"
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
    local installed=false enabled=false desired
    command -v tailscale >/dev/null 2>&1 && installed=true
    if [[ "$installed" == "true" ]] && systemctl is-enabled --quiet tailscaled 2>/dev/null && systemctl is-active --quiet tailscaled; then
        enabled=true
    fi
    desired=$(prompt_component_desired tailscale "Tailscale" "$installed" "$enabled") || return 1
    state_set component.tailscale "$desired"
    if [[ "$desired" != "true" ]]; then
        print_info "Tailscale will remain uninstalled or disabled. Enable it on a later run by answering yes."
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
    # Ensure tailscaled service is running before attempting to use tailscale command
    if ! systemctl is-active --quiet tailscaled; then
        print_info "Starting tailscaled service..."
        systemctl enable --now tailscaled
        # Wait a moment for the service to initialize
        sleep 3
    fi

    # Make sure tailscale command is available in PATH
    if ! command -v tailscale >/dev/null 2>&1; then
        # Try to add common Tailscale installation paths to PATH
        export PATH="$PATH:/usr/bin:/usr/local/bin"

        # Check again after updating PATH
        if ! command -v tailscale >/dev/null 2>&1; then
            print_error "Tailscale command not found. Installation may have failed."
            print_info "Please run the installation manually: curl -fsSL https://tailscale.com/install.sh | sh"
            return 1
        fi
    fi

    local -a TS_COMMAND=(tailscale up "--auth-key=$AUTH_KEY" "--operator=$USERNAME")
    [[ "$TS_CONNECTION" == "2" ]] && TS_COMMAND+=("--login-server=$LOGIN_SERVER")
    print_info "Connecting to Tailscale with an auth key (redacted)."
    if ! "${TS_COMMAND[@]}"; then
        print_warning "Failed to connect to Tailscale. Possible issues: invalid pre-auth key, network restrictions, or server unavailability."
        print_info "Please run the following command manually after resolving the issue:"
        printf '%s\n' "${CYAN}  tailscale up --auth-key=REDACTED${NC}"
        log "Tailscale connection failed; authentication key redacted"
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
            log "Tailscale connected successfully; authentication key redacted"
            # Store connection details for summary
            echo "${LOGIN_SERVER:-https://controlplane.tailscale.com}" > /tmp/tailscale_server
            echo "$TS_IPS" > /tmp/tailscale_ips.txt
            echo "None" > /tmp/tailscale_flags
        else
            print_warning "Tailscale connection attempt succeeded, but no IPs assigned."
            print_info "Please verify with 'tailscale ip' and run the following command manually if needed:"
            printf '%s\n' "${CYAN}  tailscale status${NC}"
            log "Tailscale connection succeeded but no address was observed."
            tailscale status > /tmp/tailscale_status.txt 2>&1
            log "Tailscale status output saved to /tmp/tailscale_status.txt for debugging"
        fi
    fi

    # --- Reconcile Additional Flags ---
    local ssh_current exit_current dns_current routes_current
    ssh_current=$(state_get tailscale.ssh false)
    exit_current=$(state_get tailscale.exit_node false)
    dns_current=$(state_get tailscale.accept_dns false)
    routes_current=$(state_get tailscale.accept_routes false)

    local ssh_desired exit_desired dns_desired routes_desired
    ssh_desired=$(prompt_bool_current "Enable Tailscale SSH?" "$ssh_current") || return 1
    exit_desired=$(prompt_bool_current "Advertise this server as an exit node?" "$exit_current") || return 1
    dns_desired=$(prompt_bool_current "Accept Tailscale DNS?" "$dns_current") || return 1
    routes_desired=$(prompt_bool_current "Accept Tailscale routes?" "$routes_current") || return 1

    local -a set_command=(tailscale set
        "--ssh=$ssh_desired"
        "--advertise-exit-node=$exit_desired"
        "--accept-dns=$dns_desired"
        "--accept-routes=$routes_desired")
    if ! "${set_command[@]}"; then
        print_error "Failed to apply Tailscale preferences; existing preferences were left active."
        return 1
    fi
    state_set tailscale.ssh "$ssh_desired"
    state_set tailscale.exit_node "$exit_desired"
    state_set tailscale.accept_dns "$dns_desired"
    state_set tailscale.accept_routes "$routes_desired"
    print_success "Tailscale setup complete."
    print_info "Verify status: tailscale ip"
    log "Tailscale setup completed."
}