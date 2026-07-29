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
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
[Definition]
# This regex looks for standard "[UFW BLOCK]" message in /var/log/ufw.log
failregex = \[UFW BLOCK\] IN=.* OUT=.* SRC=<HOST>
ignoreregex =
EOF
)

    local JAIL_LOCAL_CONFIG
    JAIL_LOCAL_CONFIG=$(cat <<EOF
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
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
    local JAIL_LOCAL_PATH="/etc/fail2ban/jail.d/99-du-setup.local"

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
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d
    echo "$UFW_PROBES_CONFIG" > "$UFW_FILTER_PATH"
    echo "$JAIL_LOCAL_CONFIG" > "$JAIL_LOCAL_PATH"

    # --- Ensure log file exists BEFORE restarting service ---
    if [[ ! -f /var/log/ufw.log ]]; then
        touch /var/log/ufw.log
        print_info "Created empty /var/log/ufw.log to ensure Fail2Ban starts correctly."
    fi

    # --- Restart and Verify Fail2ban ---
    print_info "Enabling and restarting Fail2Ban to apply new rules..."

    # Suppress Python SyntaxWarning messages during fail2ban restart
    export PYTHONWARNINGS="ignore::SyntaxWarning"
    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 5 # Give service more time to initialize and apply SSH port changes.
    # Reset Python warnings to default
    unset PYTHONWARNINGS

    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2Ban is active with new configuration."
        # Show status of enabled jails for confirmation.
        fail2ban-client status | tee -a "$LOG_FILE"

        # Verify SSH jail is using the correct port
        local ssh_jail_port=$(fail2ban-client get sshd port 2>/dev/null || echo "unknown")
        if [[ "$ssh_jail_port" == "$SSH_PORT" ]]; then
            print_success "SSH jail is correctly monitoring port $SSH_PORT"
        else
            print_warning "SSH jail is monitoring port $ssh_jail_port (expected $SSH_PORT)"
            print_info "Attempting to update SSH jail port..."
            # Use correct fail2ban-client syntax to set port
            fail2ban-client set sshd addport "$SSH_PORT" 2>/dev/null || true
            # If that doesn't work, restart fail2ban to reapply configuration
            if [[ "$ssh_jail_port" != "$SSH_PORT" ]]; then
                print_info "Restarting Fail2Ban to apply port configuration..."
                systemctl restart fail2ban
                sleep 3
            fi
        fi
    else
        print_error "Fail2Ban service failed to start. Check 'journalctl -u fail2ban' for errors."
        FAILED_SERVICES+=("fail2ban")
    fi
    log "Fail2Ban configuration completed."

    # Configure log rotation for Fail2Ban (idempotent)
    local FAIL2BAN_LOGROTATE="/etc/logrotate.d/fail2ban"
    if [ ! -f "${FAIL2BAN_LOGROTATE}" ]; then
        print_info "Configuring log rotation for Fail2Ban..."
        tee "${FAIL2BAN_LOGROTATE}" > /dev/null <<'EOF'
/var/log/fail2ban.log {
    weekly
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
        chmod 644 "${FAIL2BAN_LOGROTATE}"
    else
        print_info "Fail2Ban logrotate already configured."
    fi
}

# --- Auto Updates Configuration Function ---
configure_auto_updates() {
    print_section "Automatic Security Updates"
    local current=false desired periodic=/etc/apt/apt.conf.d/20auto-upgrades
    if apt-config dump 2>/dev/null | grep -Eq 'APT::Periodic::Unattended-Upgrade[[:space:]]+"1"'; then
        current=true
    fi
    desired=$(prompt_bool_current "Enable automatic security updates?" "$current") || return 1
    state_set auto_updates "$desired"
    if [[ "$desired" == "$current" ]]; then
        print_info "Automatic security update state is unchanged ($current)."
        return 0
    fi
    if [[ "$desired" == "true" ]]; then
        is_installed unattended-upgrades || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
        cat > "$periodic" <<'EOF'
// MANAGED BY du_setup. Manual edits may be overwritten on the next run.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
        print_success "Automatic security updates enabled."
    else
        cat > "$periodic" <<'EOF'
// MANAGED BY du_setup. Manual edits may be overwritten on the next run.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOF
        print_success "Automatic installation of security updates disabled; package-list refresh remains enabled."
    fi
}

# --- Kernel Hardening Function ---
configure_kernel_hardening() {
    print_section "Kernel Parameter Hardening (sysctl)"
    local current=false desired
    [[ -f /etc/sysctl.d/99-du-hardening.conf ]] && current=true
    desired=$(prompt_bool_current "Apply du_setup kernel security settings?" "$current") || return 1
    state_set kernel_hardening "$desired"
    if [[ "$desired" != "true" ]]; then
        if [[ "$current" == "true" ]]; then
            rm -f /etc/sysctl.d/99-du-hardening.conf
            sysctl --system >/dev/null 2>&1 || true
            print_success "Removed the du_setup-owned kernel hardening file."
        else
            print_info "Kernel hardening remains unmanaged."
        fi
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
            # Apply sysctl settings with error handling
            if sysctl -p "$AMD_EPYC_SYSCTL" >/dev/null 2>&1; then
                print_success "AMD EPYC optimizations applied."
                log "Applied AMD EPYC specific kernel optimizations."
            else
                print_warning "Some AMD EPYC optimizations could not be applied (this is normal in virtualized environments)."
                log "Some AMD EPYC optimizations failed to apply."
            fi
        else
            print_info "AMD EPYC optimizations already exist."
        fi
    fi
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
