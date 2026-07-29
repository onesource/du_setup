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
    local current_timezone
    current_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || printf 'Etc/UTC')
    TIMEZONE=$(prompt_value_current "Desired timezone" "$current_timezone" validate_timezone)
    if [[ "$TIMEZONE" != "$current_timezone" ]]; then
        timedatectl set-timezone "$TIMEZONE"
        print_success "Timezone changed from $current_timezone to $TIMEZONE."
        log "Timezone changed from $current_timezone to $TIMEZONE."
    else
        print_info "Keeping current timezone: $TIMEZONE."
    fi
    state_set timezone "$TIMEZONE"

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
        if ! dpkg -l openssh-server | grep -q "^ii"; then
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
        print_section "Checking for Repository Updates"
        local latest_version remote_commit archive temp_root extracted parent
        local install_name backup_path installed_commit="" local_commit="" apply_update

        command -v curl >/dev/null 2>&1 || {
            print_warning "curl is unavailable; skipping repository update check."
            return 0
        }
        latest_version=$(curl -fsSL --connect-timeout 10 "$CONFIG_URL" 2>/dev/null |
            awk -F'"' '/^CURRENT_VERSION=/{print $2; exit}' || true)
        remote_commit=$(curl -fsSL --connect-timeout 10 "$REPOSITORY_API_URL" 2>/dev/null |
            awk -F'"' '/"sha"[[:space:]]*:/{print $4; exit}' || true)
        [[ -n "$latest_version" && "$remote_commit" =~ ^[0-9a-f]{40}$ ]] || {
            print_warning "Could not determine the remote repository version and commit."
            return 0
        }

        if [[ -d "$SCRIPT_DIR/.git" ]]; then
            local_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)
            if [[ "$local_commit" == "$remote_commit" ]]; then
                print_info "Git checkout is current at commit $local_commit."
            elif [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]]; then
                print_warning "This is a modified Git worktree; self-update was skipped to preserve local changes."
            else
                print_warning "A repository update is available ($latest_version, $remote_commit). Update this Git checkout through Git, review it, then rerun."
            fi
            return 0
        fi

        [[ -r "$SCRIPT_DIR/.du_setup_commit" ]] && read -r installed_commit < "$SCRIPT_DIR/.du_setup_commit"
        if [[ "$installed_commit" == "$remote_commit" ]]; then
            print_info "Installed repository is current at commit $remote_commit."
            return 0
        fi
        print_success "Repository update available: $latest_version at commit $remote_commit."
        apply_update=$(prompt_bool_current "Atomically replace the complete installed repository?" false) || return 1
        [[ "$apply_update" == "true" ]] || return 0

        parent=$(dirname "$SCRIPT_DIR")
        install_name=$(basename "$SCRIPT_DIR")
        temp_root=$(mktemp -d "$parent/.du-setup-update.XXXXXX")
        archive="$temp_root/repository.tar.gz"
        if ! curl -fL "${REPOSITORY_ARCHIVE_BASE}/${remote_commit}.tar.gz" -o "$archive"; then
            rm -rf -- "$temp_root"
            return 1
        fi
        if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
            print_error "Repository archive contains an unsafe path."
            rm -rf -- "$temp_root"
            return 1
        fi
        tar -xzf "$archive" -C "$temp_root"
        extracted=$(find "$temp_root" -mindepth 1 -maxdepth 1 -type d -name 'du_setup-*' | head -n1)
        [[ -n "$extracted" && -f "$extracted/du_setup_modular.sh" ]] || {
            print_error "Downloaded repository is incomplete."
            rm -rf -- "$temp_root"
            return 1
        }
        while IFS= read -r -d '' script; do
            bash -n "$script" || {
                print_error "Downloaded repository failed syntax validation: $script"
                rm -rf -- "$temp_root"
                return 1
            }
        done < <(find "$extracted" -type f -name '*.sh' -print0)
        printf '%s\n' "$remote_commit" > "$extracted/.du_setup_commit"

        backup_path="$parent/${install_name}.previous.$(date +%Y%m%d_%H%M%S)"
        if ! mv -- "$SCRIPT_DIR" "$backup_path"; then
            rm -rf -- "$temp_root"
            return 1
        fi
        if ! mv -- "$extracted" "$SCRIPT_DIR"; then
            mv -- "$backup_path" "$SCRIPT_DIR" || true
            print_error "Atomic repository replacement failed and rollback was attempted."
            rm -rf -- "$temp_root"
            return 1
        fi
        rm -rf -- "$temp_root"
        print_success "Complete repository updated atomically to commit $remote_commit."
        print_info "Previous repository retained at $backup_path. Rerun the installer."
        exit 0
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
        local discovered_admin="" current_hostname current_pretty

        if discovered_admin=$(discover_managed_admin); then
            USERNAME=$(prompt_value_current "Managed administrator" "$discovered_admin" validate_username)
        elif [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
            print_error "No managed administrator exists; supply one during an interactive first run."
            return 1
        else
            while true; do
                read -rp "$(printf '%s' "${CYAN}Enter username for the managed administrator: ${NC}")" USERNAME
                if validate_username "$USERNAME"; then
                    if id "$USERNAME" &>/dev/null; then
                        print_warning "User '$USERNAME' already exists and will be reconciled as the managed administrator."
                        USER_EXISTS=true
                    else
                        USER_EXISTS=false
                    fi
                    break
                fi
                print_error "Invalid username. Use lowercase letters, numbers, hyphens, or underscores (max 32)."
            done
        fi
        id "$USERNAME" &>/dev/null && USER_EXISTS=true || USER_EXISTS=false

        current_hostname=$(hostnamectl --static 2>/dev/null || hostname)
        SERVER_NAME=$(prompt_value_current "Server hostname" "$current_hostname" validate_hostname)
        current_pretty=$(hostnamectl --pretty 2>/dev/null || true)
        current_pretty=${current_pretty:-$current_hostname}
        PRETTY_NAME=$(prompt_value_current "Pretty hostname" "$current_pretty")

        PREVIOUS_SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
        if [[ -z "$PREVIOUS_SSH_PORT" ]] && command -v ss >/dev/null 2>&1; then
            PREVIOUS_SSH_PORT=$(ss -H -tlpn 2>/dev/null | awk '/sshd/ {sub(/^.*:/, "", $4); print $4; exit}' || true)
        fi
        PREVIOUS_SSH_PORT=${PREVIOUS_SSH_PORT:-22}
        SSH_PORT=$(prompt_value_current "SSH port" "$PREVIOUS_SSH_PORT" validate_ssh_port)
        [[ "$SSH_PORT" == "22" ]] || validate_port "$SSH_PORT" || {
            print_error "SSH port must be 22 or between 1024 and 65535."
            return 1
        }

        if command -v curl >/dev/null 2>&1; then
            SERVER_IP_V4=$(curl -4 -fsS --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "unknown")
            SERVER_IP_V6=$(curl -6 -fsS --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "not available")
        fi

        printf '
%s
' "${YELLOW}Configuration Summary:${NC}"
        printf "  %-15s %s
" "Username:" "$USERNAME"
        printf "  %-15s %s
" "Hostname:" "$SERVER_NAME"
        printf "  %-15s %s
" "SSH Port:" "$SSH_PORT"
        if ! confirm $'
Apply this desired configuration?' "y"; then
            print_info "Exiting without changing configuration."
            exit 0
        fi

        state_set server_name "$SERVER_NAME"
        state_set pretty_name "$PRETTY_NAME"
        state_set ssh_port "$SSH_PORT"
        log "Configuration collected: USER=$USERNAME, HOST=$SERVER_NAME, PORT=$SSH_PORT"
    }

    install_packages() {
        print_section "Package Installation"
        print_info "Updating package lists and upgrading system..."
        if ! apt-get update -qq || ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq; then
            print_error "Failed to update or upgrade system packages."
            exit 1
        fi

        # Create chrony log directory before installation to prevent dpkg-statoverride warning
        print_info "Pre-creating chrony log directory..."
        mkdir -p /var/log/chrony 2>/dev/null || true

        print_info "Installing essential packages..."
        if ! apt-get install -y -qq \
            ufw fail2ban unattended-upgrades chrony \
            rsync wget vim htop iotop nethogs netcat-openbsd ncdu \
            tree rsyslog cron jq gawk coreutils perl skopeo git \
            ssh openssh-client openssh-server; then
            print_error "Failed to install one or more essential packages."
            exit 1
        fi

        print_success "Essential packages installed."
        log "Package installation completed."
    }
