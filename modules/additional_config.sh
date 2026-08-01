#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Additional Configuration Module
# Handles swap configuration, time sync, and security audit
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Swap Configuration Function ---
configure_swap() {
    if [[ $IS_CONTAINER == true ]]; then
        print_info "Swap configuration skipped in container."
        return 0
    fi
    print_section "Swap Configuration"

    # Detect system RAM for intelligent swap recommendation
    local TOTAL_RAM_MB
    TOTAL_RAM_MB=$(free -m | awk '/Mem/ {print $2}')
    local TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
    local RECOMMENDED_SWAP=""

    # Hardware-aware swap recommendations (optimized for Netcup's 12GB)
    if (( TOTAL_RAM_GB >= 8 && TOTAL_RAM_GB < 16 )); then
        # For systems with 8-16GB RAM (like Netcup's 12GB)
        RECOMMENDED_SWAP="4G"
        print_info "System has ${TOTAL_RAM_GB}GB RAM. Recommended swap size: 4G (for systems with 8-16GB RAM)"
    elif (( TOTAL_RAM_GB >= 4 && TOTAL_RAM_GB < 8 )); then
        # For systems with 4-8GB RAM
        RECOMMENDED_SWAP="2G"
        print_info "System has ${TOTAL_RAM_GB}GB RAM. Recommended swap size: 2G (for systems with 4-8GB RAM)"
    elif (( TOTAL_RAM_GB < 4 )); then
        # For systems with less than 4GB RAM
        RECOMMENDED_SWAP="1G"
        print_info "System has ${TOTAL_RAM_GB}GB RAM. Recommended swap size: 1G (for systems with <4GB RAM)"
    else
        # For systems with16GB+ RAM
        RECOMMENDED_SWAP="8G"
        print_info "System has ${TOTAL_RAM_GB}GB RAM. Recommended swap size: 8G (for systems with >16GB RAM)"
    fi

    # Check for existing swap partition
    if lsblk -r | grep -q '\[SWAP\]'; then
        print_warning "Existing swap partition found. Verify with 'lsblk -f'. Proceed with caution."
    fi
    local existing_swap
    existing_swap=$(swapon --show --noheadings | awk '{print $1}' || true)
    if [[ -n "$existing_swap" ]]; then
        local current_size
        current_size=$(du -h "$existing_swap" | awk '{print $1}')
        print_info "Existing swap file found: $existing_swap ($current_size)"
        if confirm "Modify existing swap file size?"; then
            local SWAP_SIZE
            while true; do
                read -rp "$(printf '%s' "${CYAN}Enter new swap size (e.g., 2G, 512M) [current: $current_size]: ${NC}")" SWAP_SIZE
                SWAP_SIZE=${SWAP_SIZE:-$current_size}
                if validate_swap_size "$SWAP_SIZE"; then
                    break
                else
                    print_error "Invalid size. Use format like '2G' or '512M'."
                fi
            done
            local REQUIRED_SPACE
            REQUIRED_SPACE=$(convert_to_bytes "$SWAP_SIZE")
            local AVAILABLE_SPACE
            AVAILABLE_SPACE=$(df -k / | tail -n 1 | awk '{print $4}')
            if (( AVAILABLE_SPACE < REQUIRED_SPACE / 1024 )); then
                print_error "Insufficient disk space for $SWAP_SIZE swap file. Available: $((AVAILABLE_SPACE / 1024))MB"
                exit 1
            fi
            print_info "Disabling existing swap file..."
            swapoff "$existing_swap" || { print_error "Failed to disable swap file."; exit 1; }
            print_info "Resizing swap file to $SWAP_SIZE..."
            if ! fallocate -l "$SWAP_SIZE" "$existing_swap" || ! chmod 600 "$existing_swap" || ! mkswap "$existing_swap" || ! swapon "$existing_swap"; then
                print_error "Failed to resize or enable swap file."
                exit 1
            fi
            print_success "Swap file resized to $SWAP_SIZE."
        else
            print_info "Keeping existing swap file."
            return 0
        fi
    else
        if ! confirm "Configure a swap file (recommended for < 4GB RAM)?"; then
            print_info "Skipping swap configuration."
            return 0
        fi
        local SWAP_SIZE
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter swap file size (e.g., 2G, 512M) [recommended: $RECOMMENDED_SWAP]: ${NC}")" SWAP_SIZE
            SWAP_SIZE=${SWAP_SIZE:-$RECOMMENDED_SWAP}
            if validate_swap_size "$SWAP_SIZE"; then
                break
            else
                print_error "Invalid size. Use format like '2G' or '512M'."
            fi
        done
        local REQUIRED_SPACE
        REQUIRED_SPACE=$(convert_to_bytes "$SWAP_SIZE")
        local AVAILABLE_SPACE
        AVAILABLE_SPACE=$(df -k / | tail -n 1 | awk '{print $4}')
        if (( AVAILABLE_SPACE < REQUIRED_SPACE / 1024 )); then
            print_error "Insufficient disk space for $SWAP_SIZE swap file. Available: $((AVAILABLE_SPACE / 1024))MB"
            exit 1
        fi
        print_info "Creating $SWAP_SIZE swap file..."
        if ! fallocate -l "$SWAP_SIZE" /swapfile || ! chmod 600 /swapfile || ! mkswap /swapfile || ! swapon /swapfile; then
            print_error "Failed to create or enable swap file."
            rm -f /swapfile || true
            exit 1
        fi
        # Check for existing swap entry in /etc/fstab to prevent duplicates
        if grep -q '^/swapfile ' /etc/fstab; then
            print_info "Swap entry already exists in /etc/fstab. Skipping."
        else
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "Swap entry added to /etc/fstab."
        fi
        print_success "Swap file created: $SWAP_SIZE"

    fi
    print_info "Configuring swap settings..."
    local SWAPPINESS=10
    local CACHE_PRESSURE=50
    if confirm "Customize swap settings (vm.swappiness and vm.vfs_cache_pressure)?"; then
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter vm.swappiness (0-100) [default: $SWAPPINESS]: ${NC}")" INPUT_SWAPPINESS
            INPUT_SWAPPINESS=${INPUT_SWAPPINESS:-$SWAPPINESS}
            if [[ "$INPUT_SWAPPINESS" =~ ^[0-9]+$ && "$INPUT_SWAPPINESS" -ge 0 && "$INPUT_SWAPPINESS" -le 100 ]]; then
                SWAPPINESS=$INPUT_SWAPPINESS
                break
            else
                print_error "Invalid value for vm.swappiness. Must be between 0 and 100."
            fi
        done
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter vm.vfs_cache_pressure (1-1000) [default: $CACHE_PRESSURE]: ${NC}")" INPUT_CACHE_PRESSURE
            INPUT_CACHE_PRESSURE=${INPUT_CACHE_PRESSURE:-$CACHE_PRESSURE}
            if [[ "$INPUT_CACHE_PRESSURE" =~ ^[0-9]+$ && "$INPUT_CACHE_PRESSURE" -ge 1 && "$INPUT_CACHE_PRESSURE" -le 1000 ]]; then
                CACHE_PRESSURE=$INPUT_CACHE_PRESSURE
                break
            else
                print_error "Invalid value for vm.vfs_cache_pressure. Must be between 1 and 1000."
            fi
        done
    else
        print_info "Using default swap settings (vm.swappiness=$SWAPPINESS, vm.vfs_cache_pressure=$CACHE_PRESSURE)."
    fi
    local NEW_SWAP_CONFIG
    NEW_SWAP_CONFIG=$(mktemp)
    tee "$NEW_SWAP_CONFIG" > /dev/null <<EOF
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=$CACHE_PRESSURE
EOF
    # Check if sysctl settings are already correct to prevent duplicates
    if [[ -f /etc/sysctl.d/99-swap.conf ]] && cmp -s "$NEW_SWAP_CONFIG" /etc/sysctl.d/99-swap.conf; then
        print_info "Swap settings already correct in /etc/sysctl.d/99-swap.conf. Skipping."
        rm -f "$NEW_SWAP_CONFIG"
    else
        # Check for conflicting settings in /etc/sysctl.conf or other sysctl files
        local sysctl_conflicts=false
        for file in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
            if [[ -f "$file" && "$file" != "/etc/sysctl.d/99-swap.conf" ]]; then
                if grep -E '^(vm\.swappiness|vm\.vfs_cache_pressure)=' "$file" >/dev/null; then
                    print_warning "Existing swap settings found in $file. Manual review recommended."
                    sysctl_conflicts=true
                fi
            fi
        done
        mv "$NEW_SWAP_CONFIG" /etc/sysctl.d/99-swap.conf
        chmod 644 /etc/sysctl.d/99-swap.conf
        sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
        if [[ $sysctl_conflicts == true ]]; then
            print_warning "Potential conflicting sysctl settings detected. Verify with 'sysctl -a | grep -E \"vm\.swappiness|vm\.vfs_cache_pressure\"'."
        else
            print_success "Swap settings applied to /etc/sysctl.d/99-swap.conf."
        fi
    fi
    print_success "Swap configured successfully."
    swapon --show | tee -a "$LOG_FILE"
    free -h | tee -a "$LOG_FILE"
    log "Swap configuration completed."
}

# --- Time Synchronization Function ---
configure_time_sync() {
    print_section "Time Synchronization"
    print_info "Ensuring chrony is active..."
    systemctl enable --now chrony
    sleep 2
    if systemctl is-active --quiet chrony; then
        print_success "Chrony is active for time synchronization."
        chronyc tracking | tee -a "$LOG_FILE"
    else
        print_error "Chrony service failed to start."
        exit 1
    fi
    log "Time synchronization completed."
}

# --- Security Audit Configuration Function ---
configure_security_audit() {
    print_section "Security Audit Configuration"
    if ! confirm "Run a security audit with Lynis (and optionally debsecan on Debian)?"; then
        print_info "Security audit skipped."
        log "Security audit skipped by user."
        AUDIT_RAN=false
        return 0
    fi

    AUDIT_LOG="${DU_SETUP_LOG_DIR}/setup_harden_security_audit_$(date +%Y%m%d_%H%M%S).log"
    touch "$AUDIT_LOG" && chmod 600 "$AUDIT_LOG"
    AUDIT_RAN=true
    HARDENING_INDEX=""
    DEBSECAN_VULNS="Not run"

    # Install and run Lynis
    print_info "Installing Lynis..."
    if ! apt-get update -qq; then
        print_error "Failed to update package lists. Cannot install Lynis."
        log "apt-get update failed for Lynis installation."
        return 1
    elif ! apt-get install -y -qq lynis; then
        print_warning "Failed to install Lynis. Skipping Lynis audit."
        log "Lynis installation failed."
    else
        print_info "Running Lynis audit (non-interactive mode, this will take a few minutes)..."
	print_warning "Review audit results in $AUDIT_LOG for security recommendations."
        if lynis audit system --quick >> "$AUDIT_LOG" 2>&1; then
            print_success "Lynis audit completed. Check $AUDIT_LOG for details."
            log "Lynis audit completed successfully."
            # Extract hardening index
            HARDENING_INDEX=$(grep -oP "Hardening index : \K\d+" "$AUDIT_LOG" || echo "Unknown")
            #Extract top suggestions
            grep "Suggestion:" /var/log/lynis-report.dat | head -n 5 > /tmp/lynis_suggestions.txt 2>/dev/null || true
            # Append Lynis system log for persistence
            cat /var/log/lynis.log >> "$AUDIT_LOG" 2>/dev/null
        else
            print_error "Lynis audit failed. Check $AUDIT_LOG for details."
            log "Lynis audit failed."
        fi
    fi

    # Check if system is Debian before running debsecan
    source /etc/os-release
    if [[ "$ID" == "debian" ]]; then
        if confirm "Also run debsecan to check for package vulnerabilities?"; then
            print_info "Installing debsecan..."
            if ! apt-get install -y -qq debsecan; then
                print_warning "Failed to install debsecan. Skipping debsecan audit."
                log "debsecan installation failed."
            else
                print_info "Running debsecan audit..."
                if debsecan --suite "$VERSION_CODENAME" >> "$AUDIT_LOG" 2>&1; then
                    DEBSECAN_VULNS=$(grep -c "CVE-" "$AUDIT_LOG" || echo "0")
                    print_success "debsecan audit completed. Found $DEBSECAN_VULNS vulnerabilities."
                    log "debsecan audit completed with $DEBSECAN_VULNS vulnerabilities."
                else
                    print_error "debsecan audit failed. Check $AUDIT_LOG for details."
                    log "debsecan audit failed."
                    DEBSECAN_VULNS="Failed"
                fi
            fi
        else
            print_info "debsecan audit skipped."
            log "debsecan audit skipped by user."
            DEBSECAN_VULNS="Not run"
        fi
    else
        print_info "debsecan is not supported on Ubuntu. Skipping debsecan audit."
        log "debsecan audit skipped (Ubuntu detected)."
        DEBSECAN_VULNS="Not supported on Ubuntu"
    fi

    print_warning "Review audit results in $AUDIT_LOG for security recommendations."
    log "Security audit configuration completed."
}
