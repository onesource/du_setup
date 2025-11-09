#!/bin/bash

# ============================================================================
# du_setup_modular.sh - System Configuration Module
# Configures timezone, hostname, and system optimizations
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- System Configuration Function ---
configure_system() {
    print_section "System Configuration"

    # Warn about /tmp being a RAM-backed filesystem on Debian 13+
    print_info "Note: Debian 13 uses tmpfs for /tmp by default (stored in RAM)"
    print_info "Large temporary files may consume system memory"

    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    log "Backing up script itself for audit trail"
    cp "${SCRIPT_DIR}/$(basename "$0")" "$BACKUP_DIR/du_setup_v${CURRENT_VERSION}.sh"
    cp /etc/hosts "$BACKUP_DIR/hosts.backup"
    cp /etc/fstab "$BACKUP_DIR/fstab.backup"
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.backup" 2>/dev/null || true

    print_info "Configuring timezone..."
    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter desired timezone (e.g., Europe/London, America/New_York) [Etc/UTC]: ${NC}")" TIMEZONE
        TIMEZONE=${TIMEZONE:-Etc/UTC}
        if validate_timezone "$TIMEZONE"; then
            if [[ $(timedatectl status | grep "Time zone" | awk '{print $3}') != "$TIMEZONE" ]]; then
                timedatectl set-timezone "$TIMEZONE"
                print_success "Timezone set to $TIMEZONE."
                log "Timezone set to $TIMEZONE."
            else
                print_info "Timezone already set to $TIMEZONE."
            fi
            break
        else
            print_error "Invalid timezone. View list with 'timedatectl list-timezones'."
        fi
    done

    if confirm "Configure system locales interactively?"; then
        dpkg-reconfigure locales
        print_info "Applying new locale settings to current session..."
        if [[ -f /etc/default/locale ]]; then
            # shellcheck disable=SC1091
            . /etc/default/locale
            # shellcheck disable=SC2046
            export $(grep -v '^#' /etc/default/locale | cut -d= -f1)
            print_success "Locale environment updated for this session."
            log "Sourced /etc/default/locale to update script's environment."
        else
            print_warning "Could not find /etc/default/locale to update session environment."
        fi
    else
        print_info "Skipping locale configuration."
    fi

    print_info "Configuring hostname..."
    if [[ $(hostnamectl --static) != "$SERVER_NAME" ]]; then
        hostnamectl set-hostname "$SERVER_NAME"
        hostnamectl set-hostname "$PRETTY_NAME" --pretty
        if grep -q "^127.0.1.1" /etc/hosts; then
            sed -i "s/^127.0.1.1.*/127.0.1.1\t$SERVER_NAME/" /etc/hosts
        else
            echo "127.0.1.1 $SERVER_NAME" >> /etc/hosts
        fi
        print_success "Hostname configured: $SERVER_NAME"
    else
        print_info "Hostname already set to $SERVER_NAME."
    fi

    # AMD EPYC processor optimizations
    print_info "Optimizing for AMD EPYC processor..."
    if command -v cpupower >/dev/null 2>&1; then
        # Check if cpupower can actually control CPU frequency
        if cpupower frequency-info 2>/dev/null | grep -q "driver:.*intel_pstate\|driver:.*amd_pstate"; then
            if cpupower frequency-set -g performance 2>/dev/null; then
                print_success "CPU governor set to performance mode for AMD EPYC."
            else
                print_warning "Failed to set CPU governor to performance mode (this is normal in virtualized environments)."
            fi
        else
            print_info "CPU frequency control not available (common in virtualized environments)."
        fi
    else
        print_info "cpupower not available. Skipping CPU optimization."
    fi

    # Check for CPU vulnerabilities (informational only)
    if [ -d /sys/devices/system/cpu/vulnerabilities ]; then
        local vuln_found=false
        for vuln in /sys/devices/system/cpu/vulnerabilities/*; do
            if [ -f "$vuln" ] && grep -q "Vulnerable" "$vuln" 2>/dev/null; then
                print_info "CPU vulnerability detected: $(basename "$vuln") (this is normal and mitigated by the kernel)"
                vuln_found=true
            fi
        done
        if [ "$vuln_found" = false ]; then
            print_success "No CPU vulnerabilities detected."
        fi
    fi

    # NVMe SSD optimizations
    print_info "Configuring NVMe SSD optimizations..."
    if lsblk -d -o name,rota | grep -q '0$' && lsblk -d -o name,rota | grep -q 'nvme'; then
        print_info "NVMe SSD detected. Applying optimizations..."

        # Set I/O scheduler for NVMe (deadline or mq-deadline is recommended)
        local scheduler_set=false
        for nvme in /sys/block/nvme*; do
            if [ -f "$nvme/queue/scheduler" ]; then
                echo 'mq-deadline' > "$nvme/queue/scheduler"
                print_success "Set mq-deadline scheduler for $(basename "$nvme")"
                scheduler_set=true
            fi
        done

        if [ "$scheduler_set" = true ]; then
            print_success "I/O scheduler optimization applied to NVMe devices."
        else
            print_warning "No NVMe devices found for I/O scheduler optimization."
        fi

        # Ensure TRIM is enabled for SSD
        if ! systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
            systemctl enable fstrim.timer --now
            print_success "Enabled periodic TRIM for NVMe SSD."
        else
            print_info "TRIM is already enabled."
        fi

        # Add NVMe-specific sysctl optimizations
        local NVME_SYSCTL="/etc/sysctl.d/99-nvme-optimizations.conf"
        if [ ! -f "$NVME_SYSCTL" ]; then
            cat > "$NVME_SYSCTL" <<'EOF'
# NVMe SSD Optimizations
# Reduce dirty writeback cache to improve performance on NVMe
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_writeback_centisecs = 500
EOF
            sysctl -p "$NVME_SYSCTL" >/dev/null 2>&1
            print_success "NVMe sysctl optimizations applied."
        else
            print_info "NVMe sysctl optimizations already exist."
        fi
    else
        print_info "No NVMe SSD detected. Skipping NVMe optimizations."
    fi
}
    # --- PRELIMINARY CHECKS ---
    check_system() {
        print_section "System Compatibility Check"

        if [[ $(id -u) -ne 0 ]]; then
            print_error "This script must be run as root (e.g., sudo ./du_setup_modular.sh)."
            exit 1
        fi
        print_success "Running with root privileges."

        if [[ -f /proc/1/cgroup ]] && grep -qE '(docker|lxc|kubepod)' /proc/1/cgroup; then
            IS_CONTAINER=true
            print_warning "Container environment detected. Some features (like swap) will be skipped."
        fi

        if [[ -f /etc/os-release ]]; then
            source /etc/os-release
            # ID is already populated from /etc/os-release
 if [[ $ID == "debian" && $VERSION_ID =~ ^(12|13)$ ]] || \
           [[ $ID == "ubuntu" && $VERSION_ID =~ ^(20.04|22.04|24.04)$ ]]; then
            print_success "Compatible OS detected: $PRETTY_NAME"
        else
            print_warning "Script not tested on $PRETTY_NAME. This is for Debian 12/13 or Ubuntu 20.04/22.04/24.04 LTS."
            if ! confirm "Continue anyway?"; then exit 1; fi
        fi
    else
        print_error "This does not appear to be a Debian or Ubuntu system."
        exit 1
    fi

        # Preliminary SSH service check
        if ! dpkg -l openssh-server | grep -q ^ii; then
            print_warning "openssh-server not installed. It will be installed in the next step."
        else
            if systemctl is-enabled ssh.service >/dev/null 2>&1 || systemctl is-active ssh.service >/dev/null 2>&1; then
                print_info "Preliminary check: ssh.service detected."
            elif systemctl is-enabled sshd.service >/dev/null 2>&1 || systemctl is-active sshd.service >/dev/null 2>&1; then
                print_info "Preliminary check: sshd.service detected."
            elif pgrep -q sshd; then
                print_warning "Preliminary check: SSH daemon running but no standard service detected."
            else
                print_warning "No SSH service or daemon detected. Ensure SSH is working after package installation."
            fi
        fi

        if command -v curl >/dev/null 2>&1; then
            if curl -s --connect-timeout 10 --head https://deb.debian.org >/dev/null 2>&1 || curl -s --connect-timeout 10 --head https://archive.ubuntu.com >/dev/null 2>&1; then
                print_success "Internet connectivity confirmed."
            else
                print_warning "Could not verify internet connectivity. Continuing anyway..."
                log "Warning: Internet connectivity check failed"
            fi
        else
            print_warning "curl command not found. Skipping connectivity check."
            log "Warning: curl command not available for connectivity check"
        fi

        if [[ ! -w /var/log ]]; then
            print_error "Failed to write to /var/log. Cannot create log file."
            exit 1
        fi

        # Check /etc/shadow permissions
        if [[ ! -w /etc/shadow ]]; then
            print_error "/etc/shadow is not writable. Check permissions (should be 640, root:shadow)."
            exit 1
        fi
        local SHADOW_PERMS
        SHADOW_PERMS=$(stat -c %a /etc/shadow)
        if [[ "$SHADOW_PERMS" != "640" ]]; then
            print_info "Fixing /etc/shadow permissions to 640..."
            chmod 640 /etc/shadow
            chown root:shadow /etc/shadow
            log "Fixed /etc/shadow permissions to 640."
        fi

        log "System compatibility check completed."
    }

    run_update_check() {
        print_section "Checking for Script Updates"
        local latest_version

        # Fetch the latest script from GitHub and parse version number from it.
        if command -v curl >/dev/null 2>&1; then
            if ! latest_version=$(curl -sL --connect-timeout 10 "$CONFIG_URL" 2>/dev/null | grep '^CURRENT_VERSION=' | head -n 1 | awk -F'"' '{print $2}'); then
                print_warning "Could not check for updates. Please check your internet connection."
                log "Update check failed: Could not fetch script from $CONFIG_URL"
                return
            fi
        else
            print_warning "curl command not found. Skipping update check."
            log "Update check failed: curl command not available"
            return
        fi

        if [[ -z "$latest_version" ]]; then
            print_warning "Failed to find version number in remote script."
            log "Update check failed: Could not parse version string from remote script."
            return
        fi

        local lower_version
        lower_version=$(printf '%s\n' "$CURRENT_VERSION" "$latest_version" | sort -V | head -n 1)

        if [[ "$lower_version" == "$CURRENT_VERSION" && "$CURRENT_VERSION" != "$latest_version" ]]; then
            print_success "A new version ($latest_version) is available!"

            if ! confirm "Would you like to update to version $latest_version now?"; then
                return
            fi

            local temp_dir
            if ! temp_dir=$(mktemp -d); then
                print_error "Failed to create temporary directory. Update aborted."
                exit 1
            fi
            trap 'rm -rf -- "$temp_dir"' EXIT

            local temp_script="$temp_dir/du_setup_modular.sh"
            local temp_checksum="$temp_dir/checksum.sha256"

            print_info "Downloading new script version..."
            if ! curl -sL "$SCRIPT_URL" -o "$temp_script"; then
                print_error "Failed to download new script. Update aborted."
                exit 1
            fi

            print_info "Downloading checksum..."
            if ! curl -sL "$CHECKSUM_URL" -o "$temp_checksum"; then
                print_error "Failed to download checksum file. Update aborted."
                exit 1
            fi

            print_info "Verifying checksum..."
            if ! (cd "$temp_dir" && sha256sum -c "checksum.sha256" --quiet); then
                print_error "Checksum verification failed! The downloaded file may be corrupt. Update aborted."
                exit 1
            fi

            print_success "Checksum verified successfully."

            if ! mv "$temp_script" "$0"; then
                print_error "Failed to replace old script file. You may need to do this manually."
                exit 1
            fi
            chmod +x "$0"

            trap - EXIT
            rm -rf -- "$temp_dir"

            print_success "Update successful. Please run the script again to use the new version."
            exit 0
        else
            print_info "You are running the latest version ($CURRENT_VERSION)."
            log "No new version found. Current: $CURRENT_VERSION, Latest: $latest_version"
        fi
    }

    check_dependencies() {
        print_section "Checking Dependencies"
        local missing_deps=()
        command -v curl >/dev/null || missing_deps+=("curl")
        command -v sudo >/dev/null || missing_deps+=("sudo")
        command -v gpg >/dev/null || missing_deps+=("gpg")

        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            print_info "Installing missing dependencies: ${missing_deps[*]}"
            if ! apt-get update -qq || ! apt-get install -y -qq "${missing_deps[@]}"; then
                print_error "Failed to install dependencies: ${missing_deps[*]}"
                exit 1
            fi
            print_success "Dependencies installed."
        else
            print_success "All essential dependencies are installed."
        fi
        log "Dependency check completed."
    }

    collect_config() {
        print_section "Configuration Setup"
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter username for new admin user: ${NC}")" USERNAME
            if validate_username "$USERNAME"; then
                if id "$USERNAME" &>/dev/null; then
                    print_warning "User '$USERNAME' already exists."
                    if confirm "Use this existing user?"; then USER_EXISTS=true; break; fi
                else
                    USER_EXISTS=false; break
                fi
            else
                print_error "Invalid username. Use lowercase letters, numbers, hyphens, underscores (max 32 chars)."
            fi
        done
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter server hostname: ${NC}")" SERVER_NAME
            if validate_hostname "$SERVER_NAME"; then break; else print_error "Invalid hostname."; fi
        done
        read -rp "$(printf '%s' "${CYAN}Enter a 'pretty' hostname (optional): ${NC}")" PRETTY_NAME
        [[ -z "$PRETTY_NAME" ]] && PRETTY_NAME="$SERVER_NAME"
        # Try to detect current SSH port with error handling
        if command -v ss >/dev/null 2>&1; then
            PREVIOUS_SSH_PORT=$(ss -tlpn 2>/dev/null | grep sshd | grep -oP ':\K\d+' | head -n 1 || echo "")
        else
            PREVIOUS_SSH_PORT=""
        fi
        local PROMPT_DEFAULT_PORT=${PREVIOUS_SSH_PORT:-2222}
        [[ -z "$PRETTY_NAME" ]] && PRETTY_NAME="$SERVER_NAME"
        while true; do
            read -rp "$(printf '%s' "${CYAN}Enter custom SSH port (1024-65535) [$PROMPT_DEFAULT_PORT]: ${NC}")" SSH_PORT
            SSH_PORT=${SSH_PORT:-$PROMPT_DEFAULT_PORT}
            if validate_port "$SSH_PORT" || [[ -n "$PREVIOUS_SSH_PORT" && "$SSH_PORT" == "$PREVIOUS_SSH_PORT" ]]; then break; else print_error "Invalid port. Choose a port between 1024-65535."; fi
        done

        # Detect server IPs with error handling
        if command -v curl >/dev/null 2>&1; then
            SERVER_IP_V4=$(curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "unknown")
            SERVER_IP_V6=$(curl -6 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "not available")
        else
            SERVER_IP_V4="unknown"
            SERVER_IP_V6="not available"
        fi
        if [[ "$SERVER_IP_V4" != "unknown" ]]; then
            print_info "Detected server IPv4: $SERVER_IP_V4"
        fi
        if [[ "$SERVER_IP_V6" != "not available" ]]; then
            print_info "Detected server IPv6: $SERVER_IP_V6"
        fi

        printf '\n%s\n' "${YELLOW}Configuration Summary:${NC}"
        printf "  %-15s %s\n" "Username:" "$USERNAME"
        printf "  %-15s %s\n" "Hostname:" "$SERVER_NAME"

        if [[ -n "$PREVIOUS_SSH_PORT" && "$SSH_PORT" != "$PREVIOUS_SSH_PORT" ]]; then
            printf "  %-15s %s (change from current: %s)\n" "SSH Port:" "$SSH_PORT" "$PREVIOUS_SSH_PORT"
        else
            printf "  %-15s %s\n" "SSH Port:" "$SSH_PORT"
        fi

        if [[ "$SERVER_IP_V4" != "unknown" ]]; then
            printf "  %-15s %s\n" "Server IPv4:" "$SERVER_IP_V4"
        fi
        if [[ "$SERVER_IP_V6" != "not available" ]]; then
            printf "  %-15s %s\n" "Server IPv6:" "$SERVER_IP_V6"
        fi
        if ! confirm $'\nContinue with this configuration?' "y"; then print_info "Exiting."; exit 0; fi
        log "Configuration collected: USER=$USERNAME, HOST=$SERVER_NAME, PORT=$SSH_PORT, IPV4=$SERVER_IP_V4, IPV6=$SERVER_IP_V6"
    }

    install_packages() {
        print_section "Package Installation"
        print_info "Updating package lists and upgrading system..."
        if ! apt-get update -qq || ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq; then
            print_error "Failed to update or upgrade system packages."
            exit 1
        fi
        print_info "Installing essential packages..."
        if ! apt-get install -y -qq \
            ufw fail2ban unattended-upgrades chrony \
            rsync wget vim htop iotop nethogs netcat-traditional ncdu \
            tree rsyslog cron jq gawk coreutils perl skopeo git \
            ssh openssh-client openssh-server; then
            print_error "Failed to install one or more essential packages."
            exit 1
        fi
        print_success "Essential packages installed."
        log "Package installation completed."
    }
