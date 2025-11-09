#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Security Tools Module
# Handles Fail2ban, auto-updates, and kernel hardening
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Fail2Ban Configuration Function ---
configure_fail2ban() {
    print_section "Fail2Ban Configuration"

    # --- Define Desired Configurations ---
    # Define content of config file.
    local UFW_PROBES_CONFIG
    UFW_PROBES_CONFIG=$(cat <<'EOF'
[Definition]
# This regex looks for standard "[UFW BLOCK]" message in /var/log/ufw.log
failregex = \[UFW BLOCK\] IN=.* OUT=.* SRC=<HOST>
ignoreregex =
EOF
)

    local JAIL_LOCAL_CONFIG
    JAIL_LOCAL_CONFIG=$(cat <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
port = $SSH_PORT

# This jail monitors UFW logs for rejected packets (port scans, etc.).
[ufw-probes]
enabled = true
port = all
filter = ufw-probes
logpath = /var/log/ufw.log
maxretry = 3
EOF
)

    local UFW_FILTER_PATH="/etc/fail2ban/filter.d/ufw-probes.conf"
    local JAIL_LOCAL_PATH="/etc/fail2ban/jail.local"

    # --- Idempotency Check ---
    # This checks if on-disk files are already identical to our desired configuration.
    if [[ -f "$UFW_FILTER_PATH" && -f "$JAIL_LOCAL_PATH" ]] && \
       cmp -s "$UFW_FILTER_PATH" <<<"$UFW_PROBES_CONFIG" && \
       cmp -s "$JAIL_LOCAL_PATH" <<<"$JAIL_LOCAL_CONFIG"; then
        print_info "Fail2Ban is already configured correctly. Skipping."
        log "Fail2Ban configuration is already correct."
        return 0
    fi

    # --- Apply Configuration ---
    # If check above fails, we write correct configuration files.
    print_info "Applying new Fail2Ban configuration..."
    mkdir -p /etc/fail2ban/filter.d
    echo "$UFW_PROBES_CONFIG" > "$UFW_FILTER_PATH"
    echo "$JAIL_LOCAL_CONFIG" > "$JAIL_LOCAL_PATH"

    # --- Ensure log file exists BEFORE restarting service ---
    if [[ ! -f /var/log/ufw.log ]]; then
        touch /var/log/ufw.log
        print_info "Created empty /var/log/ufw.log to ensure Fail2Ban starts correctly."
    fi

    # --- Restart and Verify Fail2ban ---
    print_info "Enabling and restarting Fail2Ban to apply new rules..."
    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2 # Give service a moment to initialize.

    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2Ban is active with new configuration."
        # Show status of enabled jails for confirmation.
        fail2ban-client status | tee -a "$LOG_FILE"
    else
        print_error "Fail2Ban service failed to start. Check 'journalctl -u fail2ban' for errors."
        FAILED_SERVICES+=("fail2ban")
    fi
    log "Fail2Ban configuration completed."
}

# --- Auto Updates Configuration Function ---
configure_auto_updates() {
    print_section "Automatic Security Updates"
    if confirm "Enable automatic security updates via unattended-upgrades?"; then
        if ! dpkg -l unattended-upgrades | grep -q ^ii; then
            print_error "unattended-upgrades package is not installed."
            exit 1
        fi
        # Check for existing unattended-upgrades configuration
        if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] && grep -q "Unattended-Upgrade::Allowed-Origins" /etc/apt/apt.conf.d/50unattended-upgrades; then
            print_info "Existing unattended-upgrades configuration found. Verify with 'cat /etc/apt/apt.conf.d/50unattended-upgrades'."
        fi
        print_info "Configuring unattended upgrades..."
        echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades
        print_success "Automatic security updates enabled."
    else
        print_info "Skipping automatic security updates."
    fi
    log "Automatic updates configuration completed."
}

# --- Kernel Hardening Function ---
configure_kernel_hardening() {
    print_section "Kernel Parameter Hardening (sysctl)"
    if ! confirm "Apply recommended kernel security settings (sysctl)?"; then
        print_info "Skipping kernel hardening."
        log "Kernel hardening skipped by user."
        return 0
    fi

    local KERNEL_HARDENING_CONFIG
    KERNEL_HARDENING_CONFIG=$(mktemp)
    # create config in a temporary file
    tee "$KERNEL_HARDENING_CONFIG" > /dev/null <<'EOF'
# Recommended Security Settings managed by du_setup_modular.sh
# For details, see: https://www.kernel.org/doc/Documentation/sysctl/

# --- IPV4 Networking ---
# Protect against IP spoofing
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
# Block SYN-FLOOD attacks
net.ipv4.tcp_syncookies=1
# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=1
net.ipv4.conf.default.secure_redirects=1
# Ignore source-routed packets
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
# Log martian packets (packets with impossible source addresses)
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1

# --- IPV6 Networking (if enabled) ---
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0

# --- Kernel Security ---
# Enable ASLR (Address Space Layout Randomization) for better security
kernel.randomize_va_space=2
# Restrict access to kernel pointers in /proc to prevent leaks
kernel.kptr_restrict=2
# Restrict access to dmesg for unprivileged users
kernel.dmesg_restrict=1
# Restrict ptrace scope to prevent process injection attacks
kernel.yama.ptrace_scope=1

# --- Filesystem Security ---
# Protect against TOCTOU (Time-of-Check to Time-of-Use) race conditions
fs.protected_hardlinks=1
fs.protected_symlinks=1
EOF

    local SYSCTL_CONF_FILE="/etc/sysctl.d/99-du-hardening.conf"

    # Idempotency check: only update if file doesn't exist or has changed
    if [[ -f "$SYSCTL_CONF_FILE" ]] && cmp -s "$KERNEL_HARDENING_CONFIG" "$SYSCTL_CONF_FILE"; then
        print_info "Kernel security settings are already configured correctly."
        rm -f "$KERNEL_HARDENING_CONFIG"
        log "Kernel hardening settings already in place."
        return 0
    fi

    print_info "Applying settings to $SYSCTL_CONF_FILE..."
    # Move new config into place
    mv "$KERNEL_HARDENING_CONFIG" "$SYSCTL_CONF_FILE"
    chmod 644 "$SYSCTL_CONF_FILE"

    print_info "Loading new settings..."
    if sysctl -p "$SYSCTL_CONF_FILE" >/dev/null 2>&1; then
        print_success "Kernel security settings applied successfully."
        log "Applied kernel hardening settings."
    else
        print_error "Failed to apply kernel settings. Check for kernel compatibility."
        log "sysctl -p failed for kernel hardening config."
    fi

    # Additional kernel hardening for AMD EPYC
    if grep -q "AMD" /proc/cpuinfo; then
        print_info "Applying AMD EPYC specific kernel optimizations..."

        # Create additional sysctl configuration for EPYC optimizations
        local AMD_EPYC_SYSCTL="/etc/sysctl.d/99-amd-epyc.conf"
        if [ ! -f "$AMD_EPYC_SYSCTL" ]; then
            cat > "$AMD_EPYC_SYSCTL" <<'EOF'
# AMD EPYC Processor Optimizations
# Optimize for NUMA awareness
kernel.numa_balancing=1

# Optimize scheduler for EPYC
kernel.sched_migration_cost_ns=5000000

# Optimize for workloads typical of server environments
kernel.sched_min_granularity_ns=10000000

# Enable transparent hugepages for better performance with large memory workloads
vm.nr_hugepages=1
vm.nr_overcommit_hugepages=1

# Optimize network stack for server workloads
net.core.netdev_max_backlog=5000
net.core.somaxconn=1024
net.ipv4.tcp_max_syn_backlog=4096
EOF
            sysctl -p "$AMD_EPYC_SYSCTL" >/dev/null 2>&1
            print_success "AMD EPYC optimizations applied."
            log "Applied AMD EPYC specific kernel optimizations."
        else
            print_info "AMD EPYC optimizations already exist."
        fi
    fi
}

# --- AIDE Installation Function ---
install_aide() {
    if ! confirm "Install AIDE for intrusion detection?"; then
        return 0
    fi

    print_section "Installing AIDE"
    apt-get install -y aide

    # Initialize AIDE database
    aide --init
    mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

    # Create cron job for daily checks
    echo "0 5 * * * /usr/bin/aide --check" > /etc/cron.daily/aide

    print_success "AIDE installed and configured"
}

# --- AppArmor Check Function ---
check_apparmor() {
    print_section "Checking AppArmor status"
    if aa-status --enabled >/dev/null 2>&1; then
        print_success "AppArmor is enabled and running"
    else
        print_error "AppArmor is disabled — consider enabling it"
    fi
}
