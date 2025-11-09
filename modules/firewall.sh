#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Firewall Configuration Module
# Handles UFW firewall setup and configuration
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Firewall Configuration Function ---
configure_firewall() {
    print_section "Firewall Configuration (UFW)"
    if ufw status | grep -q "Status: active"; then
        print_info "UFW already enabled."
    else
        print_info "Configuring UFW default policies..."
        ufw default deny incoming
        ufw default allow outgoing
    fi
    if ! ufw status | grep -qw "$SSH_PORT/tcp"; then
        print_info "Adding SSH rule for port $SSH_PORT..."
        ufw allow "$SSH_PORT"/tcp comment 'Custom SSH'
    else
        print_info "SSH rule for port $SSH_PORT already exists."
    fi
    if confirm "Allow HTTP traffic (port 80)?"; then
        if ! ufw status | grep -qw "80/tcp"; then
            ufw allow http comment 'HTTP'
            print_success "HTTP traffic allowed."
        else
            print_info "HTTP rule already exists."
        fi
    fi
    if confirm "Allow HTTPS traffic (port 443)?"; then
        if ! ufw status | grep -qw "443/tcp"; then
            ufw allow https comment 'HTTPS'
            print_success "HTTPS traffic allowed."
        else
            print_info "HTTPS rule already exists."
        fi
    fi

    # Rate limiting for SSH
    if ! ufw status | grep -q "limit $SSH_PORT/tcp"; then
        if confirm "Enable rate limiting for SSH (recommended for security)?"; then
            ufw limit $SSH_PORT/tcp comment 'SSH Rate Limit'
            print_success "SSH rate limiting enabled."
        else
            print_info "SSH rate limiting skipped."
        fi
    fi

    # Protect against common port scans
    if ! ufw status | grep -qw "113/tcp"; then
        if confirm "Block port 113 (identd scans)?"; then
            ufw deny 113/tcp comment 'Block identd scans'
            print_success "Port 113 blocked to prevent identd scans."
        else
            print_info "Port113 blocking skipped."
        fi
    fi
    if confirm "Allow Tailscale traffic (UDP 41641)?"; then
        if ! ufw status | grep -qw "41641/udp"; then
            ufw allow 41641/udp comment 'Tailscale VPN'
            print_success "Tailscale traffic (UDP 41641) allowed."
            log "Added UFW rule for Tailscale (41641/udp)."
        else
            print_info "Tailscale rule (UDP 41641) already exists."
        fi
    fi
    if confirm "Add additional custom ports (e.g., 8080/tcp, 123/udp)?"; then
        while true; do
            local CUSTOM_PORTS # Make variable local to the loop
            read -rp "$(printf '%s' "${CYAN}Enter ports (space-separated, e.g., 8080/tcp 123/udp): ${NC}")" CUSTOM_PORTS
            if [[ -z "$CUSTOM_PORTS" ]]; then
                print_info "No custom ports entered. Skipping."
                break
            fi
            local valid=true
            for port in $CUSTOM_PORTS; do
                if ! validate_ufw_port "$port"; then
                    print_error "Invalid port format: $port. Use <port>[/tcp|/udp]."
                    valid=false
                    break
                fi
            done
            if [[ "$valid" == true ]]; then
                for port in $CUSTOM_PORTS; do
                    if ufw status | grep -qw "$port"; then
                        print_info "Rule for $port already exists."
                    else
                        local CUSTOM_COMMENT
                        read -rp "$(printf '%s' "${CYAN}Enter comment for $port (e.g., 'My App Port'): ${NC}")" CUSTOM_COMMENT
                        if [[ -z "$CUSTOM_COMMENT" ]]; then
                            CUSTOM_COMMENT="Custom port $port"
                        fi
                        # Sanitize comment to avoid breaking UFW command
                        CUSTOM_COMMENT=$(echo "$CUSTOM_COMMENT" | tr -d "'\"\\")
                        ufw allow "$port" comment "$CUSTOM_COMMENT"
                        print_success "Added rule for $port with comment '$CUSTOM_COMMENT'."
                        log "Added UFW rule for $port with comment '$CUSTOM_COMMENT'."
                    fi
                done
                break
            else
                print_info "Please try again."
            fi
        done
    fi

    # --- Enable IPv6 Support if Available ---
    if [[ -f /proc/net/if_inet6 ]]; then
        print_info "IPv6 detected. Ensuring UFW is configured for IPv6..."
        if grep -q '^IPV6=yes' /etc/default/ufw; then
            print_info "UFW IPv6 support is already enabled."
        else
            sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
            if ! grep -q '^IPV6=yes' /etc/default/ufw; then
                echo "IPV6=yes" >> /etc/default/ufw
            fi
            print_success "Enabled IPv6 support in /etc/default/ufw."
            log "Enabled UFW IPv6 support."
        fi
    else
        print_info "No IPv6 detected on this system. Skipping UFW IPv6 configuration."
        log "UFW IPv6 configuration skipped as no kernel support was detected."
    fi

    # Add temporary rule for current SSH port
    if [[ -n "$PREVIOUS_SSH_PORT" && "$PREVIOUS_SSH_PORT" != "$SSH_PORT" ]]; then
        print_info "Temporarily adding UFW rule for current SSH port $PREVIOUS_SSH_PORT for transition..."
        if ! ufw status | grep -qw "$PREVIOUS_SSH_PORT/tcp"; then
            ufw allow "$PREVIOUS_SSH_PORT"/tcp comment 'Temporary SSH for transition'
        fi
    fi
    print_info "Enabling firewall..."
    if ! ufw --force enable; then
        print_error "Failed to enable UFW. Check 'journalctl -u ufw' for details."
        exit 1
    fi
    if ufw status | grep -q "Status: active"; then
        print_success "Firewall is active."
    else
        print_error "UFW failed to activate. Check 'journalctl -u ufw' for details."
        exit 1
    fi
    print_warning "ACTION REQUIRED: Check your VPS provider's edge firewall to allow opened ports (e.g., $SSH_PORT/tcp, 41641/udp for Tailscale)."
    ufw status verbose | tee -a "$LOG_FILE"
    log "Firewall configuration completed."
}