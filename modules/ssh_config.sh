#!/bin/bash

# ============================================================================
# du_setup_modular.sh - SSH Configuration Module
# Handles SSH hardening, port changes, and service management
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- SSH Configuration Reconciler ---
# /etc/ssh/sshd_config remains package-owned. du_setup only ensures that the
# snippet directory is included before other directives and owns one snippet.
configure_ssh() {
    print_section "SSH Hardening"
    local main_config=/etc/ssh/sshd_config
    local snippet_dir=/etc/ssh/sshd_config.d
    local managed_snippet="$snippet_dir/00-du-setup.conf"
    local main_backup="$BACKUP_DIR/sshd_config.before-du-setup"
    local snippet_backup="$BACKUP_DIR/00-du-setup.conf.before-du-setup"
    local staged changed=false service current_effective_port

    command -v sshd >/dev/null 2>&1 || {
        print_error "openssh-server is not installed."
        return 1
    }
    mkdir -p "$snippet_dir"
    cp -a "$main_config" "$main_backup"
    [[ -f "$managed_snippet" ]] && cp -a "$managed_snippet" "$snippet_backup"

    # OpenSSH uses the first obtained value for most keywords. Keep the
    # managed include first so manual snippets remain separate but cannot
    # silently override policy owned by this reconciler.
    if [[ "$(awk 'NF && $1 !~ /^#/ {print; exit}' "$main_config")" != "Include /etc/ssh/sshd_config.d/*.conf" ]]; then
        staged=$(mktemp)
        {
            printf '%s\n' '# Managed include added by du_setup. Keep local settings in sshd_config.d.'
            printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
            cat "$main_config"
        } > "$staged"
        install -m 0600 -o root -g root "$staged" "$main_config"
        rm -f "$staged"
        changed=true
    fi

    staged=$(mktemp)
    cat > "$staged" <<EOF
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
# Put unrelated local SSH settings in a different sshd_config.d snippet.
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 6
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
PrintMotd no
Banner /etc/issue.net
MaxStartups 10:30:60
MaxSessions 3
AllowTcpForwarding yes
AllowAgentForwarding no
PermitTunnel no
EOF
    if install_if_changed "$staged" "$managed_snippet" 0600 root root; then
        changed=true
    fi
    rm -f "$staged"

    cat > /etc/issue.net <<'EOF'
******************************************************************************
                         AUTHORIZED ACCESS ONLY
                  All attempts are logged and reviewed
******************************************************************************
EOF
    chmod 0644 /etc/issue.net

    if ! sshd -t; then
        print_error "Staged SSH configuration is invalid; restoring previous files before any reload."
        cp -a "$main_backup" "$main_config"
        if [[ -f "$snippet_backup" ]]; then
            cp -a "$snippet_backup" "$managed_snippet"
        else
            rm -f "$managed_snippet"
        fi
        return 1
    fi

    current_effective_port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    if [[ "$current_effective_port" != "$SSH_PORT" ]]; then
        print_error "Effective SSH port is $current_effective_port, expected $SSH_PORT. No reload performed."
        cp -a "$main_backup" "$main_config"
        [[ -f "$snippet_backup" ]] && cp -a "$snippet_backup" "$managed_snippet" || rm -f "$managed_snippet"
        return 1
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$SSH_PORT"/tcp comment 'du_setup managed SSH' >/dev/null
    fi

    if [[ "$changed" == "false" ]]; then
        print_info "Effective SSH configuration already matches the desired state."
        return 0
    fi

    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        SSH_SERVICE=ssh.socket
        systemctl daemon-reload
        if ! systemctl restart ssh.socket; then
            rollback_ssh_changes "$main_backup" "$snippet_backup" "$managed_snippet"
            return 1
        fi
    elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        SSH_SERVICE=ssh.service
        if ! systemctl reload ssh.service; then
            rollback_ssh_changes "$main_backup" "$snippet_backup" "$managed_snippet"
            return 1
        fi
    else
        SSH_SERVICE=sshd.service
        if ! systemctl reload sshd.service; then
            rollback_ssh_changes "$main_backup" "$snippet_backup" "$managed_snippet"
            return 1
        fi
    fi

    if ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$SSH_PORT$"; then
        print_error "SSH is not listening on the desired port after reload."
        rollback_ssh_changes "$main_backup" "$snippet_backup" "$managed_snippet"
        return 1
    fi

    if [[ "$PREVIOUS_SSH_PORT" != "$SSH_PORT" ]]; then
        print_warning "Test a new SSH connection on port $SSH_PORT in a separate terminal."
        if ! confirm "Was the new SSH connection successful?" "n"; then
            rollback_ssh_changes "$main_backup" "$snippet_backup" "$managed_snippet"
            return 1
        fi
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow "$PREVIOUS_SSH_PORT"/tcp >/dev/null 2>&1 || true
        fi
    fi

    state_set ssh_port "$SSH_PORT"
    print_success "SSH configuration reconciled and validated."
}

rollback_ssh_changes() {
    local main_backup="$1" snippet_backup="$2" managed_snippet="$3"
    print_warning "Rolling back the complete du_setup SSH change set."
    cp -a "$main_backup" /etc/ssh/sshd_config
    if [[ -f "$snippet_backup" ]]; then
        cp -a "$snippet_backup" "$managed_snippet"
    else
        rm -f "$managed_snippet"
    fi
    sshd -t || {
        print_error "The pre-change SSH configuration backup is invalid; refusing another restart."
        return 1
    }
    systemctl daemon-reload
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl reload ssh.service
    else
        systemctl reload sshd.service
    fi
    command -v ufw >/dev/null 2>&1 && ufw allow "$PREVIOUS_SSH_PORT"/tcp comment 'du_setup SSH rollback' >/dev/null 2>&1 || true
    print_success "SSH configuration rollback completed."
}
