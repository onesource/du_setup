#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Provider Package Cleanup Module
# Removes provider-specific packages and configurations
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Provider Cleanup Function ---
cleanup_provider_packages() {
    print_section "Provider Package Cleanup (Optional)"

    # Validate required variables
    if [[ -z "${LOG_FILE:-}" ]]; then
        LOG_FILE="/var/log/du_setup_$(date +%Y%m%d_%H%M%S).log"
        echo "Warning: LOG_FILE not set, using: $LOG_FILE"
    fi

    if [[ -z "${USERNAME:-}" ]]; then
        USERNAME="${SUDO_USER:-root}"
        log "USERNAME defaulted to '$USERNAME' for cleanup-only mode"
    fi

    if [[ -z "${BACKUP_DIR:-}" ]]; then
        BACKUP_DIR="/root/setup_harden_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        log "Created backup directory: $BACKUP_DIR"
    fi

    # Ensure cleanup mode variables are set
    CLEANUP_PREVIEW="${CLEANUP_PREVIEW:-false}"
    CLEANUP_ONLY="${CLEANUP_ONLY:-false}"
    VERBOSE="${VERBOSE:-true}"

    # Detect environment first
    detect_environment

    # Display environment information
    printf '%s\n' "${CYAN}=== Environment Detection ===${NC}"
    printf 'Virtualization Type: %s\n' "${DETECTED_VIRT_TYPE:-unknown}"
    printf 'System Manufacturer: %s\n' "${DETECTED_MANUFACTURER:-unknown}"
    printf 'Product Name: %s\n' "${DETECTED_PRODUCT:-unknown}"
    printf 'Environment Type: %s\n' "${ENVIRONMENT_TYPE:-unknown}"
    if [[ -n "${DETECTED_BIOS_VENDOR}" && "${DETECTED_BIOS_VENDOR}" != "unknown" ]]; then
        printf 'BIOS Vendor: %s\n' "${DETECTED_BIOS_VENDOR}"
    fi
    if [[ -n "${DETECTED_PROVIDER_NAME}" ]]; then
        printf 'Detected Provider: %s\n' "${DETECTED_PROVIDER_NAME}"
    fi
    printf '\n'

    # Determine recommendation based on three-way detection
    local CLEANUP_RECOMMENDED=false
    local DEFAULT_ANSWER="n"
    local RECOMMENDATION_TEXT=""
    local ENVIRONMENT_CONFIDENCE="${ENVIRONMENT_CONFIDENCE:-low}"

    case "$ENVIRONMENT_TYPE" in
        commercial-cloud)
            CLEANUP_RECOMMENDED=true
            DEFAULT_ANSWER="y"
            printf '%s\n' "${YELLOW}☁  Commercial Cloud VPS Detected${NC}"
            if [[ -n "${DETECTED_PROVIDER_NAME}" ]]; then
                printf 'Provider: %s\n' "${CYAN}${DETECTED_PROVIDER_NAME}${NC}"
            fi
            printf 'This is a commercial VPS from an external provider.\n'
            RECOMMENDATION_TEXT="Provider cleanup is ${BOLD}RECOMMENDED${NC} for security."
            printf '%s\n' "$RECOMMENDATION_TEXT"
            printf 'Providers may install monitoring agents, pre-configured users, and management tools.\n'
            ;;

        uncertain-kvm)
            CLEANUP_RECOMMENDED=false
            DEFAULT_ANSWER="n"
            printf '%s\n' "${YELLOW}⚠  KVM/QEMU Virtualization Detected (Uncertain)${NC}"
            printf 'This environment could be:\n'
            printf '  %s A commercial cloud provider VPS (Hetzner, Vultr, OVH, smaller providers)\n' "${CYAN}•${NC}"
            printf '  %s A personal VM on Proxmox, KVM, or QEMU\n' "${CYAN}•${NC}"
            printf '  %s A VPS from a regional/unlisted provider\n' "${CYAN}•${NC}"
            printf '\n'
            RECOMMENDATION_TEXT="Cleanup is ${BOLD}OPTIONAL${NC} - review packages carefully before proceeding."
            printf '%s\n' "$RECOMMENDATION_TEXT"
            printf 'If this is a commercial VPS, cleanup is recommended.\n'
            printf 'If you control the hypervisor (Proxmox/KVM), cleanup is optional.\n'
            ;;

        personal-vm)
            CLEANUP_RECOMMENDED=false
            DEFAULT_ANSWER="n"
            printf '%s\n' "${CYAN}ℹ  Personal/Private Virtualization Detected${NC}"
            if [[ -n "${DETECTED_PROVIDER_NAME}" ]]; then
                printf 'Platform: %s\n' "${CYAN}${DETECTED_PROVIDER_NAME}${NC}"
            fi
            printf 'This appears to be a personal VM (VirtualBox, VMware Workstation, etc.)\n'
            RECOMMENDATION_TEXT="Provider cleanup is ${BOLD}NOT RECOMMENDED${NC} for trusted environments."
            printf '%s\n' "$RECOMMENDATION_TEXT"
            printf 'If you control the hypervisor/host, you likely don'\''t need cleanup.\n'
            ;;

        bare-metal)
            printf '%s\n' "${GREEN}✓ Bare Metal Server Detected${NC}"
            printf 'This appears to be a physical (bare metal) server.\n'
            RECOMMENDATION_TEXT="Provider cleanup is ${BOLD}NOT NEEDED${NC} for bare metal."
            printf '%s\n' "$RECOMMENDATION_TEXT"
            printf 'No virtualization layer detected - skipping cleanup.\n'
            log "Provider package cleanup skipped: bare metal server detected."
            return 0
            ;;

        uncertain-xen|unknown|*)
            CLEANUP_RECOMMENDED=false
            DEFAULT_ANSWER="n"
            printf '%s\n' "${YELLOW}⚠  Virtualization Environment: Uncertain${NC}"
            printf 'Could not definitively identify the hosting provider or environment.\n'
            RECOMMENDATION_TEXT="Cleanup is ${BOLD}OPTIONAL${NC} - proceed with caution."
            printf '%s\n' "$RECOMMENDATION_TEXT"
            printf 'Review packages carefully before removing anything.\n'
            ;;
    esac
    printf '\n'

    # Decision point based on environment and flags
    if [[ "$CLEANUP_PREVIEW" == "false" ]] && [[ "$CLEANUP_ONLY" == "false" ]]; then
        local PROMPT_TEXT=""

        if [[ "$ENVIRONMENT_TYPE" == "commercial-cloud" ]]; then
            PROMPT_TEXT="Run provider package cleanup? (Recommended for cloud VPS)"
        elif [[ "$ENVIRONMENT_TYPE" == "uncertain-kvm" ]]; then
            PROMPT_TEXT="Run provider package cleanup? (Verify your environment first)"
        else
            PROMPT_TEXT="Run provider package cleanup? (Not recommended for trusted environments)"
        fi

        if ! confirm "$PROMPT_TEXT" "$DEFAULT_ANSWER"; then
            print_info "Skipping provider package cleanup."
            log "Provider package cleanup skipped by user (environment: $ENVIRONMENT_TYPE)."
            return 0
        fi

        # Extra warning for non-cloud environments
        if [[ "$CLEANUP_RECOMMENDED" == "false" ]] && [[ "$ENVIRONMENT_TYPE" != "uncertain-kvm" ]]; then
            echo
            print_warning "⚠  You chose to run cleanup on a trusted/personal environment."
            print_warning "This may remove useful tools or break functionality."
            echo
            if ! confirm "Are you sure you want to continue?" "n"; then
                print_info "Cleanup cancelled."
                log "User cancelled cleanup after warning."
                return 0
            fi
        fi
    fi

    if [[ "$CLEANUP_PREVIEW" == "true" ]]; then
        print_warning "=== PREVIEW MODE ENABLED ==="
        print_info "No changes will be made. This is a simulation only."
        printf '\n'
    fi

    if [[ "$CLEANUP_PREVIEW" == "false" ]]; then
        print_warning "RECOMMENDED: Create a snapshot/backup via provider dashboard before cleanup."
        if ! confirm "Have you created a backup snapshot?" "n"; then
            print_info "Please create a backup first. Exiting cleanup."
            log "User declined to proceed without backup snapshot."
            return 0
        fi
    fi

    print_warning "This will identify packages and configurations installed by your VPS provider."
    if [[ "$CLEANUP_PREVIEW" == "false" ]]; then
        print_warning "Removing critical packages can break system functionality."
    fi

    local PROVIDER_PACKAGES=()
    local PROVIDER_SERVICES=()
    local PROVIDER_USERS=()
    local ROOT_SSH_KEYS=()

    # List of common provider and virtualization packages
    local COMMON_PROVIDER_PKGS=(
        "qemu-guest-agent"
        "virtio-utils"
        "virt-what"
        "cloud-init"
        "cloud-guest-utils"
        "cloud-initramfs-growroot"
        "cloud-utils"
        "open-vm-tools"
        "xe-guest-utilities"
        "xen-tools"
        "hyperv-daemons"
        "oracle-cloud-agent"
        "aws-systems-manager-agent"
        "amazon-ssm-agent"
        "google-compute-engine"
        "google-osconfig-agent"
        "walinuxagent"
        "hetzner-needrestart"
        "digitalocean-agent"
        "do-agent"
        "linode-agent"
        "vultr-monitoring"
        "scaleway-ecosystem"
        "ovh-rtm"
        "openstack-guest-utils"
        "openstack-nova-agent"
    )

    # Common provider-created default users
    local COMMON_PROVIDER_USERS=(
        "ubuntu"
        "debian"
        "admin"
        "cloud-user"
        "ec2-user"
        "linuxuser"
    )

    print_info "Scanning for provider-installed packages..."

    for pkg in "${COMMON_PROVIDER_PKGS[@]}"; do
        if execute_check dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            PROVIDER_PACKAGES+=("$pkg")
        fi
    done

    # Detect associated services
    print_info "Scanning for provider-related services..."
    for pkg in "${PROVIDER_PACKAGES[@]}"; do
        local service_name="${pkg}.service"
        if execute_check systemctl list-unit-files "$service_name" 2>/dev/null | grep -q "$service_name"; then
            if execute_check systemctl is-enabled "$service_name" 2>/dev/null | grep -qE 'enabled|static'; then
                PROVIDER_SERVICES+=("$service_name")
            fi
        fi
    done

    # Check for provider-created users (excluding current admin user and script-managed user)
    print_info "Scanning for default provisioning users..."
    local MANAGED_USER=""
    if [[ -f /root/.du_setup_managed_user ]]; then
        MANAGED_USER=$(tr -d '[:space:]' < /root/.du_setup_managed_user 2>/dev/null)
        log "Script-managed user detected: $MANAGED_USER (will be excluded from cleanup)"
    fi

    for user in "${COMMON_PROVIDER_USERS[@]}"; do
        if execute_check id "$user" &>/dev/null && \
           [[ "$user" != "$USERNAME" ]] && \
           [[ "$user" != "$MANAGED_USER" ]]; then
            PROVIDER_USERS+=("$user")
        fi
    done

    # Audit root SSH keys
    print_info "Auditing /root/.ssh/authorized_keys for unexpected keys..."
    if [[ -f /root/.ssh/authorized_keys ]]; then
        local key_count
        key_count=$( (grep -cE '^ssh-(rsa|ed25519|ecdsa)' /root/.ssh/authorized_keys 2>/dev/null || echo 0) | tr -dc '0-9' )
        if [ "$key_count" -gt 0 ]; then
            print_warning "Found $key_count SSH key(s) in /root/.ssh/authorized_keys"
            ROOT_SSH_KEYS=("present")
        fi
    fi

    # Summary of findings
    echo
    print_info "=== Scan Results ==="
    echo "Packages found: ${#PROVIDER_PACKAGES[@]}"
    echo "Services found: ${#PROVIDER_SERVICES[@]}"
    echo "Default users found: ${#PROVIDER_USERS[@]}"
    echo "Root SSH keys: ${#ROOT_SSH_KEYS[@]}"
    echo

    if [[ ${#PROVIDER_PACKAGES[@]} -eq 0 && ${#PROVIDER_USERS[@]} -eq 0 && ${#ROOT_SSH_KEYS[@]} -eq 0 ]]; then
        print_success "No common provider packages or users detected."
        return 0
    fi

    if [[ ${#PROVIDER_PACKAGES[@]} -gt 0 ]]; then
        printf '  Candidate packages:
'
        printf '    - %s
' "${PROVIDER_PACKAGES[@]}"
    fi
    if [[ ${#PROVIDER_USERS[@]} -gt 0 ]]; then
        printf '  Candidate provisioning users:
'
        printf '    - %s
' "${PROVIDER_USERS[@]}"
    fi
    if [[ ${#ROOT_SSH_KEYS[@]} -gt 0 ]]; then
        print_warning "Root authorized_keys is audit-only and will never be changed automatically."
    fi

    if [[ "$CLEANUP_PREVIEW" == "true" ]]; then
        print_success "Preview completed. Every candidate requires individual confirmation during apply."
        return 0
    fi

    local packages_to_remove=() users_to_remove=() pkg user
    for pkg in "${PROVIDER_PACKAGES[@]}"; do
        if confirm "Remove provider/guest package '$pkg'?" "n"; then
            packages_to_remove+=("$pkg")
        fi
    done

    if [[ ${#packages_to_remove[@]} -gt 0 ]]; then
        print_info "Simulating package purge and dependency changes..."
        if ! apt-get -s purge "${packages_to_remove[@]}" | tee -a "$LOG_FILE"; then
            print_error "APT simulation failed; no provider packages were removed."
            return 1
        fi
        if confirm "Apply exactly this simulated package purge?" "n"; then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}"
            print_success "Selected provider packages removed."
        else
            print_info "Package removal cancelled after simulation."
        fi
    fi

    for user in "${PROVIDER_USERS[@]}"; do
        if pgrep -u "$user" >/dev/null 2>&1; then
            print_warning "Skipping user '$user' because it has running processes."
            continue
        fi
        if confirm "Disable and remove provisioning account '$user' (home preserved)?" "n"; then
            users_to_remove+=("$user")
        fi
    done
    for user in "${users_to_remove[@]}"; do
        usermod --lock --expiredate 1 "$user" 2>/dev/null || true
        userdel "$user"
        print_success "Removed account '$user'; its home directory was preserved."
    done

    log "Provider cleanup completed: packages=${packages_to_remove[*]:-none}, users=${users_to_remove[*]:-none}."
    print_success "Provider cleanup completed with only explicitly confirmed changes."
}