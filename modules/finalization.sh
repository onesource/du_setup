#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Finalization Module
# Handles cleanup, summary, and reboot
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Final Cleanup Function ---
final_cleanup() {
    print_section "Final Reconciliation Check"
    print_info "Package maintenance already ran during package reconciliation; no purge/autoremove is performed automatically."
    systemctl daemon-reload
    print_success "Final systemd reload complete."
    log "Final reconciliation check completed."
}

# --- Generate Summary Function ---
generate_summary() {
    # Create report file and set permissions first
    touch "$REPORT_FILE" && chmod 600 "$REPORT_FILE"

    # Using a subshell to group all output and tee it to report file
    (
    print_section "Setup Complete!"

    printf '\n%s\n\n' "${GREEN}Server setup and hardening script has finished successfully.${NC}"
    printf '%s %s\n' "${CYAN}📋 A detailed report has been saved to:${NC}" "${BOLD}$REPORT_FILE${NC}"
    printf '%s    %s\n' "${CYAN}📜 The full execution log is available at:${NC}" "${BOLD}$LOG_FILE${NC}"
    printf '\n'

    print_separator "Final Service Status Check:"
    for service in "$SSH_SERVICE" fail2ban chrony; do
        if systemctl is-active --quiet "$service"; then
            printf "  %-20s ${GREEN}✓ Active${NC}\n" "$service"
        else
            printf "  %-20s ${RED}✗ INACTIVE${NC}\n" "$service"
            FAILED_SERVICES+=("$service")
        fi
    done

    # Optional services are failures only when the persisted desired state is
    # enabled. Installed-but-disabled is reported as an intentional choice.
    local wazuh_desired docker_desired tailscale_desired
    wazuh_desired=$(state_get component.wazuh false)
    docker_desired=$(state_get component.docker false)
    tailscale_desired=$(state_get component.tailscale false)

    if [[ -x "$WAZUH_CONTROL" ]]; then
        if "$WAZUH_CONTROL" status | grep -q "is running"; then
            printf "  %-20s ${GREEN}Active${NC}\n" "wazuh-manager"
        elif [[ "$wazuh_desired" == "false" ]]; then
            printf "  %-20s ${YELLOW}Installed, intentionally disabled${NC}\n" "wazuh-manager"
        else
            printf "  %-20s ${RED}INACTIVE${NC}\n" "wazuh-manager"
            FAILED_SERVICES+=("wazuh-manager")
        fi
    else
        printf "  %-20s ${YELLOW}Not installed (optional)${NC}\n" "wazuh-manager"
    fi
    if ufw status | grep -q "Status: active"; then
        printf "  %-20s ${GREEN}Active${NC}\n" "ufw (firewall)"
    else
        printf "  %-20s ${RED}INACTIVE${NC}\n" "ufw (firewall)"
        FAILED_SERVICES+=("ufw")
    fi
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            printf "  %-20s ${GREEN}Active${NC}\n" "docker"
        elif [[ "$docker_desired" == "false" ]]; then
            printf "  %-20s ${YELLOW}Installed, intentionally disabled${NC}\n" "docker"
        else
            printf "  %-20s ${RED}INACTIVE${NC}\n" "docker"
            FAILED_SERVICES+=("docker")
        fi
    fi
    if command -v tailscale >/dev/null 2>&1; then
        if systemctl is-active --quiet tailscaled && tailscale ip >/dev/null 2>&1; then
            printf "  %-20s ${GREEN}Active and connected${NC}\n" "tailscaled"
            tailscale ip 2>/dev/null > /tmp/tailscale_ips.txt || true
        elif [[ "$tailscale_desired" == "false" ]]; then
            printf "  %-20s ${YELLOW}Installed, intentionally disabled${NC}\n" "tailscaled"
            TS_COMMAND=""
        else
            printf "  %-20s ${RED}INACTIVE or disconnected${NC}\n" "tailscaled"
            FAILED_SERVICES+=("tailscaled")
            TS_COMMAND="sudo tailscale up"
        fi
    fi
    if [[ "$wazuh_desired" == "false" || "$docker_desired" == "false" || "$tailscale_desired" == "false" ]]; then
        printf '%s\n' "  Re-enable an optional service by rerunning du_setup and answering yes for that component."
    fi
    if [[ "${AUDIT_RAN:-false}" == true ]]; then
        printf "  %-20s ${GREEN}✓ Performed${NC}\n" "Security Audit"
    else
        printf "  %-20s ${YELLOW}⚠ Not Performed${NC}\n" "Security Audit"
    fi
    printf '\n'

    # --- Main Configuration Summary ---
    print_separator "Configuration Summary:"
    printf "  %-15s %s\n" "Admin User:" "$USERNAME"
    printf "  %-15s %s\n" "Hostname:" "$SERVER_NAME"
    printf "  %-15s %s\n" "SSH Port:" "$SSH_PORT"
    if [[ "$SERVER_IP_V4" != "unknown" ]]; then
        printf "  %-15s %s\n" "Server IPv4:" "$SERVER_IP_V4"
    fi
    if [[ "$SERVER_IP_V6" != "not available" ]]; then
        printf "  %-15s %s\n" "Server IPv6:" "$SERVER_IP_V6"
    fi

    # --- Kernel Hardening Status ---
    if [[ -f /etc/sysctl.d/99-du-hardening.conf ]]; then
        printf "  %-20s${GREEN}Applied${NC}\n" "Kernel Hardening:"
    else
        printf "  %-20s${YELLOW}Not Applied${NC}\n" "Kernel Hardening:"
    fi

    # --- Backup Configuration Summary ---
    if [[ -f /root/run_backup.sh ]]; then
        local CRON_SCHEDULE NOTIFICATION_STATUS BACKUP_DEST BACKUP_PORT REMOTE_BACKUP_PATH
        CRON_SCHEDULE=$(crontab -u root -l 2>/dev/null | grep -F "/root/run_backup.sh" | awk '{print $1, $2, $3, $4, $5}' || echo "Not configured")
        NOTIFICATION_STATUS="None"
        BACKUP_DEST=$(grep "^REMOTE_DEST=" /root/run_backup.sh | cut -d'"' -f2 || echo "Unknown")
        BACKUP_PORT=$(grep "^SSH_PORT=" /root/run_backup.sh | cut -d'"' -f2 || echo "Unknown")
        REMOTE_BACKUP_PATH=$(grep "^REMOTE_PATH=" /root/run_backup.sh | cut -d'"' -f2 || echo "Unknown")
        case "$(grep '^NOTIFICATION_SETUP=' /root/run_backup.sh | cut -d'"' -f2)" in
            ntfy) NOTIFICATION_STATUS="ntfy" ;;
            discord) NOTIFICATION_STATUS="Discord" ;;
        esac
        printf '%s\n' "  Remote Backup:      ${GREEN}Enabled${NC}"
        printf "    %-17s%s\n" "- Backup Script:" "/root/run_backup.sh"
        printf "    %-17s%s\n" "- Destination:" "$BACKUP_DEST"
        printf "    %-17s%s\n" "- SSH Port:" "$BACKUP_PORT"
        printf "    %-17s%s\n" "- Remote Path:" "$REMOTE_BACKUP_PATH"
        printf "    %-17s%s\n" "- Cron Schedule:" "$CRON_SCHEDULE"
        printf "    %-17s%s\n" "- Notifications:" "$NOTIFICATION_STATUS"
        if [[ -f "$BACKUP_LOG" ]] && grep -q "Test backup successful" "$BACKUP_LOG" 2>/dev/null; then
            printf "    %-17s%s\n" "- Test Status:" "${GREEN}Successful${NC}"
        elif [[ -f "$BACKUP_LOG" ]]; then
            printf "    %-17s%s\n" "- Test Status:" "Failed (check $BACKUP_LOG)"
        else
            printf "    %-17s%s\n" "- Test Status:" "Not run"
        fi
    else
        printf '%s\n' "  Remote Backup:      ${RED}Not configured${NC}"
    fi

    # --- Tailscale Summary ---
    if command -v tailscale >/dev/null 2>&1; then
        local TS_CONFIGURED=false
        if [[ -f /tmp/tailscale_ips.txt ]] && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' /tmp/tailscale_ips.txt 2>/dev/null; then
            TS_CONFIGURED=true
        fi
        if $TS_CONFIGURED; then
            local TS_SERVER TS_IPS_RAW TS_IPS TS_FLAGS
            TS_SERVER=$(cat /tmp/tailscale_server 2>/dev/null || echo "https://controlplane.tailscale.com")
            TS_IPS_RAW=$(cat /tmp/tailscale_ips.txt 2>/dev/null || echo "Not connected")
            TS_IPS=$(echo "$TS_IPS_RAW" | paste -sd ", " -)
            TS_FLAGS=$(cat /tmp/tailscale_flags 2>/dev/null || echo "None")
            printf '%s\n' "  Tailscale:          ${GREEN}Configured and connected${NC}"
            printf "    %-17s%s\n" "- Server:" "${TS_SERVER:-Not set}"
            printf "    %-17s%s\n" "- Tailscale IPs:" "${TS_IPS:-Not connected}"
            printf "    %-17s%s\n" "- Flags:" "${TS_FLAGS:-None}"
        else
            printf '%s\n' "  Tailscale:          ${YELLOW}Installed but not configured${NC}"
        fi
    else
        printf '%s\n' "  Tailscale:          ${RED}Not installed${NC}"
    fi

    # --- Security Audit Summary ---
    if [[ "${AUDIT_RAN:-false}" == true ]]; then
        printf '%s\n' "  Security Audit:     ${GREEN}Performed${NC}"
        printf "    %-17s%s\n" "- Audit Log:" "${AUDIT_LOG:-N/A}"
        printf "    %-17s%s\n" "- Hardening Index:" "${HARDENING_INDEX:-Unknown}"
        printf "    %-17s%s\n" "- Vulnerabilities:" "${DEBSECAN_VULNS:-N/A}"
        if [[ -s /tmp/lynis_suggestions.txt ]]; then
            printf '%s\n' "    ${YELLOW}- Top Lynis Suggestions:${NC}"
            sed 's/^/      /' /tmp/lynis_suggestions.txt
        fi
    else
        printf '%s\n' "  Security Audit:     ${RED}Not run${NC}"
    fi
    printf '\n'

    print_separator "Environment Information"
    printf "%-20s %s\n" "Virtualization:" "${DETECTED_VIRT_TYPE:-unknown}"
    printf "%-20s %s\n" "Manufacturer:" "${DETECTED_MANUFACTURER:-unknown}"
    printf "%-20s %s\n" "Product:" "${DETECTED_PRODUCT:-unknown}"
    if [[ "$IS_CLOUD_PROVIDER" == "true" ]]; then
        printf "%-20s %s\n" "Environment:" "${YELLOW}Cloud VPS${NC}"
    elif [[ "$DETECTED_VIRT_TYPE" == "none" ]]; then
        printf "%-20s %s\n" "Environment:" "${GREEN}Bare Metal${NC}"
    else
        printf "%-20s %s\n" "Environment:" "${CYAN}Personal VM${NC}"
    fi
    printf '\n'

    # --- Post-Reboot Verification Steps ---
    print_separator "Post-Reboot Verification Steps:"
    printf '  - SSH access:\n'
    if [[ "$SERVER_IP_V4" != "unknown" ]]; then
        printf "    %-26s ${CYAN}%s${NC}\n" "- Using IPv4:" "ssh -p $SSH_PORT $USERNAME@$SERVER_IP_V4"
    fi
    if [[ "$SERVER_IP_V6" != "not available" ]]; then
        printf "    %-26s ${CYAN}%s${NC}\n" "- Using IPv6:" "ssh -p $SSH_PORT $USERNAME@$SERVER_IP_V6"
    fi
    printf "  %-28s ${CYAN}%s${NC}\n" "- Firewall rules:" "sudo ufw status verbose"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Time sync:" "chronyc tracking"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Fail2Ban sshd jail:" "sudo fail2ban-client status sshd"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Fail2Ban ufw jail:" "sudo fail2ban-client status ufw-probes"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Wazuh status:" "sudo /var/ossec/bin/ossec-control status"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Wazuh alerts:" "sudo tail -f /var/ossec/logs/alerts/alerts.log"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Rootkit scan:" "sudo chkrootkit && sudo rkhunter --check"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Swap status:" "sudo swapon --show && free -h"
    printf "  %-28s ${CYAN}%s${NC}\n" "- Kernel settings:" "sudo sysctl fs.protected_hardlinks kernel.yama.ptrace_scope"
    if command -v docker >/dev/null 2>&1; then
        printf "  %-28s ${CYAN}%s${NC}\n" "- Docker status:" "docker ps"
    fi
    if command -v tailscale >/dev/null 2>&1; then
        printf "  %-28s ${CYAN}%s${NC}\n" "- Tailscale status:" "tailscale status"
    fi
    if [[ -f /root/run_backup.sh ]]; then
        printf '  Remote Backup:\n'
        printf "    %-23s ${CYAN}%s${NC}\n" "- Test backup:" "sudo /root/run_backup.sh"
        printf "    %-23s ${CYAN}%s${NC}\n" "- Check logs:" "sudo less $BACKUP_LOG"
    fi
    if [[ "${AUDIT_RAN:-false}" == true ]]; then
        printf '%s\n' "  ${YELLOW}Security Audit:${NC}"
        printf "    %-23s ${CYAN}%s${NC}\n" "- Check results:" "sudo less ${AUDIT_LOG:-/var/log/syslog}"
    fi
    printf '\n'

    # --- Final Warnings and Actions ---
    if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
        print_warning "ACTION REQUIRED: The following services failed: ${FAILED_SERVICES[*]}. Verify with 'systemctl status <service>'."
    fi
    if [[ -n "${TS_COMMAND:-}" ]]; then
        print_warning "ACTION REQUIRED: Tailscale connection failed. Run the following command to connect manually:"
        printf '%s\n' "${CYAN}  $TS_COMMAND${NC}"
    fi
    if [[ -f /root/run_backup.sh ]] && [[ "${KEY_COPY_CHOICE:-2}" != "1" ]]; then
        print_warning "ACTION REQUIRED: Ensure root SSH key (/root/.ssh/id_ed25519.pub) is copied to backup destination."
    fi

    if [[ -f /var/run/reboot-required ]]; then
        print_warning "The operating system reports that a reboot is required."
        if confirm "Reboot now?" "n"; then
            print_info "Rebooting, bye!..."
            sleep 3
            reboot
        else
            print_warning "Please reboot manually with 'sudo reboot' when convenient."
        fi
    else
        print_info "No reboot is currently required."
    fi

    ) | tee -a "$REPORT_FILE"

    log "Script finished successfully. Report generated at $REPORT_FILE"
}