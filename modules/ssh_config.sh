#!/bin/bash

# ============================================================================
# du_setup_modular.sh - SSH Configuration Module
# Handles SSH hardening, port changes, and service management
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- SSH Configuration Function ---
configure_ssh() {
    trap cleanup_and_exit ERR

    print_section "SSH Hardening"
    local CURRENT_SSH_PORT USER_HOME SSH_DIR SSH_KEY AUTH_KEYS

    # Ensure openssh-server is installed
    if ! dpkg -l openssh-server | grep -q "^ii"; then
        print_error "openssh-server package is not installed."
        return 1
    fi

    # Detect SSH service name
    if [[ $ID == "ubuntu" ]] && systemctl is-active ssh.socket >/dev/null 2>&1; then
        SSH_SERVICE="ssh.socket"
        print_info "Using SSH socket activation: $SSH_SERVICE"
    elif [[ $ID == "ubuntu" ]] && { systemctl is-enabled ssh.service >/dev/null 2>&1 || systemctl is-active ssh.service >/dev/null 2>&1; }; then
        SSH_SERVICE="ssh.service"
    elif systemctl is-enabled sshd.service >/dev/null 2>&1 || systemctl is-active sshd.service >/dev/null 2>&1; then
        SSH_SERVICE="sshd.service"
    else
        print_error "No SSH service or daemon detected."
        return 1
    fi
    print_info "Using SSH service: $SSH_SERVICE"
    log "Detected SSH service: $SSH_SERVICE"

    print_info "Backing up original SSH config..."
    SSHD_BACKUP_FILE="$BACKUP_DIR/sshd_config.backup_$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"

    # Check globally detected port, falling back to 22 if detection failed
    if [[ -z "$PREVIOUS_SSH_PORT" ]]; then
        print_warning "Could not detect an active SSH port. Assuming port 22 for initial test."
        log "Could not detect active SSH port, fell back to 22."
        PREVIOUS_SSH_PORT="22"
    fi
    CURRENT_SSH_PORT=$PREVIOUS_SSH_PORT
    USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
    SSH_DIR="$USER_HOME/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    if [[ $LOCAL_KEY_ADDED == false ]] && [[ ! -s "$AUTH_KEYS" ]]; then
        print_info "No local key provided. Generating new SSH key..."
        mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"; chown "$USERNAME:$USERNAME" "$SSH_DIR"
        sudo -u "$USERNAME" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -q
        cat "$SSH_DIR/id_ed25519.pub" >> "$AUTH_KEYS"
        # Verify key was added
        if [[ ! -s "$AUTH_KEYS" ]]; then
            print_error "Failed to create authorized_keys file."
            return 1
        fi
        chmod 600 "$AUTH_KEYS"; chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
        print_success "SSH key generated."
        printf '%s\n' "${YELLOW}Public key for remote access:${NC}"; cat "$SSH_DIR/id_ed25519.pub"
    fi

    print_warning "SSH Key Authentication Required for Next Steps!"
    printf '%s\n' "${CYAN}Test SSH access from a SEPARATE terminal now:${NC}"
    if [[ -n "$SERVER_IP_V4" && "$SERVER_IP_V4" != "unknown" ]]; then
        printf '%s\n' "${CYAN}  Using IPv4: ssh -p $CURRENT_SSH_PORT $USERNAME@$SERVER_IP_V4${NC}"
    fi
    if [[ -n "$SERVER_IP_V6" && "$SERVER_IP_V6" != "not available" ]]; then
        printf '%s\n' "${CYAN}  Using IPv6: ssh -p $CURRENT_SSH_PORT $USERNAME@$SERVER_IP_V6${NC}"
    fi

    if ! confirm "Can you successfully log in using your SSH key?"; then
        print_error "SSH key authentication is mandatory to proceed."
        return 1
    fi

    # Apply port change
    print_info "Configuring SSH to listen on port $SSH_PORT..."

    # Open the new SSH port in the host firewall if applicable to avoid locking out remote access
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        print_info "Adding UFW rule to allow SSH on port $SSH_PORT..."
        ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || print_warning "Failed to add UFW rule for $SSH_PORT (check UFW)."
        # Ensure rule applied immediately
        ufw status numbered | grep -E "${SSH_PORT}|22" || true
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        print_info "Adding firewalld rule to allow SSH on port $SSH_PORT..."
        firewall-cmd --permanent --add-port=${SSH_PORT}/tcp >/dev/null 2>&1 || print_warning "Failed to add firewalld rule for $SSH_PORT (check firewalld)."
        firewall-cmd --reload >/dev/null 2>&1 || print_warning "Failed to reload firewalld after adding SSH port $SSH_PORT."
    else
        print_warning "No host firewall (UFW/firewalld) detected or active — ensure your VPS provider's edge firewall allows port $SSH_PORT/tcp."
    fi

    if grep -q "^Port\s" /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    else
        # Add Port directive at the beginning of the file
        sed -i "1i Port $SSH_PORT" /etc/ssh/sshd_config
    fi

    # Handle systemd socket activation for Ubuntu 24.04+
    if [[ "$SSH_SERVICE" == "ssh.socket" ]]; then
        print_info "Updating SSH socket configuration for Ubuntu 24.04+..."
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$SSH_PORT
ListenStream=[::]:$SSH_PORT
EOF
        systemctl daemon-reload
        log "Created socket override for port $SSH_PORT"

        # CRITICAL: Stop the socket to release the old port binding
        if systemctl is-active --quiet ssh.socket; then
            if systemctl stop ssh.socket 2>/dev/null; then
                print_info "Stopped ssh.socket to release old port binding."
                log "Stopped ssh.socket successfully"
            else
                print_error "Failed to stop ssh.socket"
                log "ERROR: Failed to stop ssh.socket"
            fi
        fi

        # Restart ssh.service to ensure sshd is ready with new config
        print_info "Restarting ssh.service with new configuration..."
        if systemctl restart ssh.service 2>/dev/null; then
            print_info "Restarted ssh.service successfully."
            log "Restarted ssh.service successfully"
        else
            print_error "Failed to restart ssh.service. Checking status..."
            systemctl status ssh.service --no-pager | tail -20
            log "ERROR: Failed to restart ssh.service"
            # Try to start it instead
            if systemctl start ssh.service 2>/dev/null; then
                print_info "Started ssh.service (restart failed but start succeeded)."
                log "Started ssh.service after restart failed"
            else
                print_error "Failed to start ssh.service. Manual intervention may be required."
            fi
        fi

        # Restart ssh.socket to apply new port configuration
        print_info "Restarting ssh.socket on new port $SSH_PORT..."
        if systemctl restart ssh.socket 2>/dev/null; then
            print_info "Restarted ssh.socket with new port $SSH_PORT."
            log "Restarted ssh.socket successfully on port $SSH_PORT"
        else
            print_error "Failed to restart ssh.socket. Checking status..."
            systemctl status ssh.socket --no-pager | tail -20
            log "ERROR: Failed to restart ssh.socket"
            # Try to start it instead
            if systemctl start ssh.socket 2>/dev/null; then
                print_info "Started ssh.socket (restart failed but start succeeded)."
                log "Started ssh.socket after restart failed"
            else
                print_error "Failed to start ssh.socket. Manual intervention may be required."
            fi
        fi
    else
        # Remove any existing systemd overrides that might conflict on non-socket systems
        print_info "Removing any conflicting systemd overrides..."
        rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null || true
        rm -rf /etc/systemd/system/ssh.service.d 2>/dev/null || true
        rm -rf /etc/systemd/system/sshd.service.d 2>/dev/null || true
    fi

    # Apply additional hardening
    mkdir -p /etc/ssh/sshd_config.d
    tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 6
ClientAliveInterval 300
X11Forwarding no
PrintMotd no
Banner /etc/issue.net
MaxStartups 10:30:60
MaxSessions 3
ClientAliveCountMax 3
AllowTcpForwarding no
AllowAgentForwarding no
TrustedUserCAKeys no
PermitTunnel no
AddressFamily any
EOF
    tee /etc/issue.net > /dev/null <<'EOF'
******************************************************************************
                       🔒AUTHORIZED ACCESS ONLY
             ════ all attempts are logged and reviewed ════
******************************************************************************
EOF

    print_info "Testing SSH configuration syntax..."
    mkdir -p /run/sshd
    chmod 755 /run/sshd
	if ! sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        print_warning "SSH configuration test detected potential issues (see above)."
        print_info "This may be due to existing configuration files on system."
        if ! confirm "Continue despite configuration warnings?"; then
            print_error "Aborting SSH configuration."
            rm -f /etc/ssh/sshd_config.d/99-hardening.conf
            rm -f /etc/issue.net
            rm -f /etc/systemd/system/ssh.socket.d/override.conf 2>/dev/null || true
            rm -f "/etc/systemd/system/${SSH_SERVICE}.d/override.conf" 2>/dev/null || true
            systemctl daemon-reload
            return 1
        fi
    fi
    # For socket-activated systems, we already restarted services above
    if [[ "$SSH_SERVICE" != "ssh.socket" ]]; then
        print_info "Reloading systemd and restarting SSH service..."
        systemctl daemon-reload

        # Try to restart SSH service with fallback options
        if ! systemctl restart "$SSH_SERVICE"; then
            print_warning "Failed to restart $SSH_SERVICE. Trying alternative methods..."

            # Try alternative service names
            if [[ "$SSH_SERVICE" == "ssh.service" ]] && ! systemctl restart sshd.service; then
                print_warning "Failed to restart sshd.service as well."
            elif [[ "$SSH_SERVICE" == "sshd.service" ]] && ! systemctl restart ssh.service; then
                print_warning "Failed to restart ssh.service as well."
            fi

            # Try manual start as last resort
            print_info "Attempting manual SSH daemon start..."
            pkill -f "sshd:.*" || true  # Kill existing sshd processes
            timeout 5 /usr/sbin/sshd -D -f /etc/ssh/sshd_config &
            sleep 3
        fi
    fi

    sleep 5
    # Diagnostic: Check what ports are actually listening
    print_info "Checking listening ports for SSH..."
    ss -tuln | grep -E ":(22|$SSH_PORT) " || print_warning "No SSH ports found listening"
    print_info "Checking for IPv4 and IPv6 bindings..."
    ss -tuln | grep -E ":(22|$SSH_PORT) " | grep -E "0.0.0.0|::" || print_warning "No IPv4 or IPv6 bindings found"

    # Diagnostic: Check service status
    print_info "Checking SSH service status..."
    systemctl status ssh.socket --no-pager -l | head -15
    systemctl status ssh.service --no-pager -l | head -15

    if ! ss -tuln | grep -q ":$SSH_PORT "; then
        print_error "SSH not listening on port $SSH_PORT after restart!"
        print_warning "Attempting to restore SSH on original port $PREVIOUS_SSH_PORT..."

        # Try to restore original port immediately
        sed -i "s/^Port .*/Port $PREVIOUS_SSH_PORT/" /etc/ssh/sshd_config
        systemctl restart "$SSH_SERVICE" 2>/dev/null || {
            pkill -f "sshd:.*" || true
            timeout 5 /usr/sbin/sshd -D -f /etc/ssh/sshd_config &
        }
        sleep 3

        if ss -tuln | grep -q ":$PREVIOUS_SSH_PORT "; then
            print_success "SSH restored on original port $PREVIOUS_SSH_PORT."
            return 1
        else
            print_error "Failed to restore SSH on both ports. Manual intervention required."
            return 1
        fi
    fi
    print_success "SSH service restarted on port $SSH_PORT."

    # Verify root SSH is disabled
    print_info "Verifying root SSH login is disabled..."
    sleep 2
    if ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no root@localhost true 2>/dev/null; then
        print_error "Root SSH login is still possible! Check configuration."
        return 1
    else
        print_success "Confirmed: Root SSH login is disabled."
    fi

    print_warning "CRITICAL: Test new SSH connection in a SEPARATE terminal NOW!"
    print_warning "ACTION REQUIRED: Check your VPS provider's edge/network firewall to allow $SSH_PORT/tcp."

    # Check UFW firewall status
    print_info "Checking UFW firewall rules..."
    ufw status numbered | grep -E "Status|${SSH_PORT}|22" || print_warning "UFW may not be active"

    if [[ -n "$SERVER_IP_V4" && "$SERVER_IP_V4" != "unknown" ]]; then
        print_info "Use IPv4: ssh -p $SSH_PORT $USERNAME@$SERVER_IP_V4"
    fi
    if [[ -n "$SERVER_IP_V6" && "$SERVER_IP_V6" != "not available" ]]; then
        print_info "Use IPv6: ssh -p $SSH_PORT $USERNAME@$SERVER_IP_V6"
    fi

    # Retry loop for SSH connection test
    local retry_count=0
    local max_retries=3
    while (( retry_count < max_retries )); do
        if confirm "Was new SSH connection successful?"; then
            print_success "SSH hardening confirmed and finalized."
            # Remove temporary UFW rule
            if [[ -n "$PREVIOUS_SSH_PORT" && "$PREVIOUS_SSH_PORT" != "$SSH_PORT" ]]; then
                print_info "Removing temporary UFW rule for old SSH port $PREVIOUS_SSH_PORT..."
                ufw delete "$PREVIOUS_SSH_PORT"/tcp 2>/dev/null || true
            fi
            break
        else
            (( retry_count++ ))
            if (( retry_count < max_retries )); then
                print_info "Retrying SSH connection test ($retry_count/$max_retries)..."
                sleep 5
            else
                print_error "All retries failed. Initiating rollback to port $PREVIOUS_SSH_PORT..."
                rollback_ssh_changes
                if ! ss -tuln | grep -q ":$PREVIOUS_SSH_PORT "; then
                    print_error "Rollback failed. SSH not restored on original port $PREVIOUS_SSH_PORT."
                else
                    print_success "Rollback successful. SSH restored on original port $PREVIOUS_SSH_PORT."
                fi
                return 1
            fi
        fi
    done

    trap - ERR
    log "SSH hardening completed."
}

# --- SSH Rollback Function ---
rollback_ssh_changes() {
    print_info "Rolling back SSH configuration changes to port $PREVIOUS_SSH_PORT..."

    # Ensure SSH_SERVICE is set and valid
    local SSH_SERVICE=${SSH_SERVICE:-"sshd.service"}
    local USE_SOCKET=false
    # Check if socket activation is used
    if systemctl list-units --full -all --no-pager | grep -E "[[:space:]]ssh.socket[[:space:]]" >/dev/null 2>&1; then
        USE_SOCKET=true
        SSH_SERVICE="ssh.socket"
        print_info "Detected SSH socket activation: using ssh.socket."
        log "Rollback: Using ssh.socket for SSH service."
    elif ! systemctl list-units --full -all --no-pager | grep -E "[[:space:]]${SSH_SERVICE}[[:space:]]" >/dev/null 2>&1; then
        local initial_service_check="$SSH_SERVICE"
        SSH_SERVICE="ssh.service" # Fallback for Ubuntu
        print_warning "SSH service '$initial_service_check' not found, falling back to '$SSH_SERVICE'."
        log "Rollback warning: Using fallback SSH service ssh.service."
        # Verify fallback service exists
        if ! systemctl list-units --full -all --no-pager | grep -E "[[:space:]]ssh.service[[:space:]]" >/dev/null 2>&1; then
            print_error "No valid SSH service (sshd.service or ssh.service) found."
            log "Rollback failed: No valid SSH service detected."
            print_info "Action: Verify SSH service with 'systemctl list-units --full -all | grep ssh' and manually configure /etc/ssh/sshd_config."
            return 0
        fi
    fi

    # Remove systemd overrides for both service and socket
    if ! rm -rf /etc/systemd/system/ssh.socket.d /etc/systemd/system/sshd.service.d /etc/systemd/system/ssh.service.d 2>/dev/null; then
        print_warning "Could not remove one or more systemd override directories."
        log "Rollback warning: Failed to remove systemd overrides."
    else
        log "Removed all potential systemd override directories for SSH."
    fi

    # Remove custom SSH configuration
    if ! rm -f /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null; then
        print_warning "Failed to remove /etc/ssh/sshd_config.d/99-hardening.conf."
        log "Rollback warning: Failed to remove SSH hardening config."
    else
        log "Removed /etc/ssh/sshd_config.d/99-hardening.conf."
    fi

    # Restore original sshd_config
    if [[ -f "$SSHD_BACKUP_FILE" ]]; then
        if ! cp "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config 2>/dev/null; then
            print_error "Failed to restore sshd_config from $SSHD_BACKUP_FILE."
            log "Rollback failed: Cannot copy $SSHD_BACKUP_FILE to /etc/ssh/sshd_config."
            print_info "Action: Manually restore with 'cp $SSHD_BACKUP_FILE /etc/ssh/sshd_config' and verify with 'sshd -t'."
            return 0
        fi
        print_info "Restored original sshd_config from $SSHD_BACKUP_FILE."
        log "Restored sshd_config from $SSHD_BACKUP_FILE."
        # Ensure correct port rollback if already using custom port
        print_info "Applying a systemd override to ensure rollback to port $PREVIOUS_SSH_PORT..."
        log "Rollback: Creating override to enforce port $PREVIOUS_SSH_PORT."
        if [[ "$USE_SOCKET" == true ]]; then
            mkdir -p /etc/systemd/system/ssh.socket.d
            cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$PREVIOUS_SSH_PORT
ListenStream=[::]:$PREVIOUS_SSH_PORT
EOF
        else
            local service_for_rollback="ssh.service"
            if systemctl list-units --full -all --no-pager | grep -qE "[[:space:]]sshd.service[[:space:]]"; then
                service_for_rollback="sshd.service"
            fi
            mkdir -p "/etc/systemd/system/${service_for_rollback}.d"
            cat > "/etc/systemd/system/${service_for_rollback}.d/override.conf" << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/sshd -D -p $PREVIOUS_SSH_PORT
EOF
        fi
    else
        print_error "Backup file not found at $SSHD_BACKUP_FILE."
        log "Rollback failed: $SSHD_BACKUP_FILE not found."
        print_info "Action: Manually configure /etc/ssh/sshd_config to use port $PREVIOUS_SSH_PORT and verify with 'sshd -t'."
        return 0
    fi

    # Remove any firewall rules added for the new SSH port
    if command -v ufw >/dev/null 2>&1; then
        print_info "Removing UFW rule for port $SSH_PORT if present..."
        ufw delete allow "$SSH_PORT"/tcp 2>/dev/null || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        print_info "Removing firewalld rule for port $SSH_PORT if present..."
        firewall-cmd --permanent --remove-port=${SSH_PORT}/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi

    # Validate restored sshd_config
    if ! /usr/sbin/sshd -t >/tmp/sshd_config_test.log 2>&1; then
        print_error "Restored sshd_config is invalid. Check /tmp/sshd_config_test.log for details."
        log "Rollback failed: Invalid sshd_config after restoration."
        print_info "Action: Fix /etc/ssh/sshd_config manually and test with 'sshd -t'."
        return 0
    fi

    # Reload systemd
    print_info "Reloading systemd..."
    if ! systemctl daemon-reload 2>/dev/null; then
        print_warning "Failed to reload systemd. Continuing with restart attempt..."
        log "Rollback warning: Failed to reload systemd."
    fi

    # Handle socket activation or direct service restart
    if [[ "$USE_SOCKET" == true ]]; then
        # Stop ssh.socket to avoid conflicts
        if systemctl is-active --quiet ssh.socket; then
            if ! systemctl stop ssh.socket 2>/tmp/ssh_socket_stop.log; then
                print_warning "Failed to stop ssh.socket. May affect port binding."
                log "Rollback warning: Failed to stop ssh.socket. See /tmp/ssh_socket_stop.log."
            else
                log "Stopped ssh.socket to ensure correct port binding."
            fi
        fi
        # Restart ssh.service to ensure sshd starts
        print_info "Restarting ssh.service..."
        if ! systemctl restart ssh.service 2>/tmp/sshd_restart.log; then
            print_warning "Failed to restart ssh.service. Attempting manual start..."
            log "Rollback warning: Failed to restart ssh.service. See /tmp/sshd_restart.log."
            # Ensure no other sshd processes are running
            pkill -f "sshd:.*" 2>/dev/null || true
            # Manual start in foreground to verify
            timeout 5 /usr/sbin/sshd -D -f /etc/ssh/sshd_config >/tmp/sshd_manual_start.log 2>&1
            local TIMEOUT_EXIT=$?
            if [[ $TIMEOUT_EXIT -eq 0 || $TIMEOUT_EXIT -eq 124 ]]; then
                log "Manual SSH start succeeded (exit code $TIMEOUT_EXIT)."
                # Restart service to ensure systemd management
                if ! systemctl restart ssh.service 2>/tmp/sshd_restart_manual.log; then
                    print_error "Failed to restart ssh.service after manual start."
                    log "Rollback failed: Failed to restart ssh.service after manual start. See /tmp/sshd_restart_manual.log."
                else
                    log "Restarted ssh.service to ensure systemd management."
                fi
            else
                print_error "Manual SSH start failed (exit code $TIMEOUT_EXIT). Check /tmp/sshd_manual_start.log."
                log "Rollback failed: Manual SSH start failed (exit code $TIMEOUT_EXIT). See /tmp/sshd_manual_start.log."
            fi
        fi
        # Restart ssh.socket to re-enable socket activation
        print_info "Restarting ssh.socket..."
        if ! systemctl restart ssh.socket 2>/tmp/ssh_socket_restart.log; then
            print_warning "Failed to restart ssh.socket. SSH service may still be running."
            log "Rollback warning: Failed to restart ssh.socket. See /tmp/ssh_socket_restart.log."
        else
            log "Restarted ssh.socket for socket activation."
        fi
    else
        # Direct service restart for non-socket systems
        print_info "Restarting $SSH_SERVICE..."
        if ! systemctl restart "$SSH_SERVICE" 2>/tmp/sshd_restart.log; then
            print_warning "Failed to restart $SSH_SERVICE. Attempting manual start..."
            log "Rollback warning: Failed to restart $SSH_SERVICE. See /tmp/sshd_restart.log."
            # Ensure no other sshd processes are running
            pkill -f "sshd:.*" 2>/dev/null || true
            # Manual start in foreground to verify
            timeout 5 /usr/sbin/sshd -D -f /etc/ssh/sshd_config >/tmp/sshd_manual_start.log 2>&1
            local TIMEOUT_EXIT=$?
            if [[ $TIMEOUT_EXIT -eq 0 || $TIMEOUT_EXIT -eq 124 ]]; then
                log "Manual SSH start succeeded (exit code $TIMEOUT_EXIT)."
                # Restart service to ensure systemd management
                if ! systemctl restart "$SSH_SERVICE" 2>/tmp/sshd_restart_manual.log; then
                    print_error "Failed to restart $SSH_SERVICE after manual start."
                    log "Rollback failed: Failed to restart $SSH_SERVICE after manual start. See /tmp/sshd_restart_manual.log."
                else
                    log "Restarted $SSH_SERVICE to ensure systemd management."
                fi
            else
                print_error "Manual SSH start failed (exit code $TIMEOUT_EXIT). Check /tmp/sshd_manual_start.log."
                log "Rollback failed: Manual SSH start failed (exit code $TIMEOUT_EXIT). See /tmp/sshd_manual_start.log."
            fi
        fi
    fi

    # Verify rollback with retries
    local rollback_verified=false
    print_info "Verifying SSH rollback to port $PREVIOUS_SSH_PORT..."
    for ((i=1; i<=10; i++)); do
        if ss -tuln | grep -q ":$PREVIOUS_SSH_PORT "; then
            rollback_verified=true
            break
        fi
        log "Rollback verification attempt $i/10: SSH not listening on port $PREVIOUS_SSH_PORT."
        sleep 3
    done

    if [[ $rollback_verified == true ]]; then
        print_success "Rollback successful. SSH is now listening on port $PREVIOUS_SSH_PORT."
        log "Rollback successful: SSH listening on port $PREVIOUS_SSH_PORT."
    else
        print_error "Rollback failed. SSH service is not listening on port $PREVIOUS_SSH_PORT."
        log "Rollback failed: SSH not listening on port $PREVIOUS_SSH_PORT. See /tmp/sshd_config_test.log, /tmp/sshd_restart.log, /tmp/sshd_manual_start.log, /tmp/ssh_socket_stop.log, /tmp/ssh_socket_restart.log."
        print_info "Action: Check service status with 'systemctl status ssh.service' or 'systemctl status ssh.socket' and logs with 'journalctl -u ssh.service' or 'journalctl -u ssh.socket'."
        print_info "Manually verify port with 'ss -tuln | grep :$PREVIOUS_SSH_PORT'."
        print_info "Try starting SSH with 'sudo systemctl start ssh.service' or 'sudo systemctl start ssh.socket'."
    fi

    return 0
}

# --- Cleanup and Exit Function ---
cleanup_and_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && $(type -t rollback_ssh_changes) == "function" ]]; then
        print_error "An error occurred. Rolling back SSH changes to port $PREVIOUS_SSH_PORT..."
        print_info "Rolling back firewall rules..."
        ufw delete allow "$SSH_PORT"/tcp 2>/dev/null || true
        if [[ -n "$PREVIOUS_SSH_PORT" ]]; then
            ufw allow "$PREVIOUS_SSH_PORT"/tcp comment 'SSH Rollback' 2>/dev/null || true
            print_info "Firewall rolled back to allow port $PREVIOUS_SSH_PORT."
        else
            print_warning "Could not determine previous SSH port for firewall rollback."
        fi

        rollback_ssh_changes
        if ! rollback_ssh_changes; then
            print_error "Rollback failed. SSH may not be accessible. Please check 'systemctl status $SSH_SERVICE' and 'journalctl -u $SSH_SERVICE'."
        else
            print_success "Rollback successful. SSH restored on original port $PREVIOUS_SSH_PORT."
        fi
    fi
    trap - ERR
    exit $exit_code
}