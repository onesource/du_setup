#!/bin/bash

# ============================================================================
# Debian and Ubuntu Server Hardening Interactive Script (Modular Version)
#
# This is the modular version of du_setup.sh that sources separate modules
# for better maintainability and organization.
# ============================================================================

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source core libraries
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/utils.sh"

# --- --help ---
show_usage() {
    printf "\n"
    printf "%s%s%s\n" "$CYAN" "Debian/Ubuntu Server Setup & Hardening Script (Modular)" "$NC"

    printf "\n%sUsage:%s\n" "$BOLD" "$NC"
    printf "  sudo -E %s [OPTIONS]\n" "$(basename "$0")"

    printf "\n%sDescription:%s\n" "$BOLD" "$NC"
    printf "  This is the modular version of server setup script.\n"
    printf "  It sources separate modules for better organization.\n"

    printf "\n%sOperational Modes:%s\n" "$BOLD" "$NC"
    printf "  %-22s %s\n" "--cleanup-preview" "Show which provider packages/users would be cleaned without making changes."
    printf "  %-22s %s\n" "--cleanup-only" "Run only the provider cleanup function (for existing servers)."
    printf "  %-22s %s\n" "--nginx-security" "Open Nginx security and certificate management only."

    printf "\n%sModifiers:%s\n" "$BOLD" "$NC"
    printf "  %-22s %s\n" "--skip-cleanup" "Skip provider cleanup entirely during a full setup run."
    printf "  %-22s %s\n" "--quiet" "Suppress informational output; prompts are still shown."
    printf "  %-22s %s\n" "--non-interactive" "Keep detected values; fail if a new answer is required."
    printf "  %-22s %s\n" "-h, --help" "Display this help message and exit."

    printf "\n%sUsage Examples:%s\n" "$BOLD" "$NC"
    printf "  # Run the full interactive setup\n"
    printf "  %ssudo -E ./%s%s\n" "$YELLOW" "$(basename "$0")" "$NC"
    printf "  # Preview provider cleanup actions without applying them\n"
    printf "  %ssudo -E ./%s --cleanup-preview%s\n" "$YELLOW" "$(basename "$0")" "$NC"
    printf "  # Manage Nginx sites, certificates, monitoring, and scans only\n"
    printf "  %ssudo -E ./%s --nginx-security%s\n" "$YELLOW" "$(basename "$0")" "$NC"

    printf "\n"
    exit 0
}

# --- PARSE ARGUMENTS ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet) VERBOSE=false; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --cleanup-preview) CLEANUP_PREVIEW=true; shift ;;
        --cleanup-only) CLEANUP_ONLY=true; shift ;;
        --nginx-security) NGINX_SECURITY_ONLY=true; shift ;;
        --skip-cleanup) SKIP_CLEANUP=true; shift ;;
        -h|--help) show_usage ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            printf 'Use --help for supported options.\n' >&2
            exit 2
            ;;
    esac
done

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    printf "\n"
    printf "%s✗ You are running as user '%s'. This script must be run as root.%s\n" "$RED" "$(whoami)" "$NC"
    printf "\n"
    printf "This script makes system-level changes including:\n"
    printf "  - Package installation/removal\n"
    printf "  - Firewall configuration\n"
    printf "  - SSH hardening\n"
    printf "  - User account management\n"
    printf "\n"
    printf "Choose one of the following methods to run this script:\n"
    printf "\n"
    printf "%s%sRun with sudo (-E preserves environment):%s\n" "$BOLD" "$GREEN" "$NC"
    if [[ -n "$ORIGINAL_ARGS" ]]; then
        printf "  %ssudo -E %s %s%s\n" "$CYAN" "$0" "$ORIGINAL_ARGS" "$NC"
    else
        printf "  %ssudo -E %s%s\n" "$CYAN" "$0" "$NC"
    fi
    printf "\n"
    printf "%s%sAlternative methods:%s\n" "$BOLD" "$YELLOW" "$NC"
    printf "  %ssudo su %s    # Switch to root\n" "$CYAN" "$NC"
    if [[ -n "$ORIGINAL_ARGS" ]]; then
        printf "  And run: %s%s %s%s\n" "$CYAN" "$0" "$ORIGINAL_ARGS" "$NC"
    else
        printf "  And run: %s%s%s\n" "$CYAN" "$0" "$NC"
    fi
    printf "\n"
    exit 1
fi

# --- Initialize Configuration ---
init_config

# --- Source All Modules ---
#
# NOTE: All modules are sourced here to make their functions available.
# This does NOT execute them - it only loads the function definitions.
# The actual execution order is controlled in the main() function below.
#
# Module Dependencies (execution order matters):
# 1. Core libraries (already sourced above)
# 2. environment.sh - No dependencies
# 3. system_config.sh - No dependencies
# 4. user_management.sh - Depends on system_config.sh
# 5. ssh_config.sh - Depends on user_management.sh (for SSH keys)
# 6. firewall.sh - Depends on ssh_config.sh (for SSH port)
# 7. security_tools.sh - No dependencies
# 8. optional_installs.sh - No dependencies
# 9. nginx.sh - Depends on optional_installs.sh (for Docker)
# 10. backup_config.sh - No dependencies
# 11. additional_config.sh - No dependencies
# 12. database_security.sh - No dependencies (optional, runs only if databases detected)
# 13. provider_cleanup.sh - No dependencies
# 14. finalization.sh - Depends on all other modules
#
# Each module can be enabled/disabled by commenting/uncommenting the source line
# AND the corresponding function calls in main() below.

source "$SCRIPT_DIR/modules/environment.sh"
source "$SCRIPT_DIR/modules/system_config.sh"
source "$SCRIPT_DIR/modules/user_management.sh"
source "$SCRIPT_DIR/modules/ssh_config.sh"
source "$SCRIPT_DIR/modules/firewall.sh"
source "$SCRIPT_DIR/modules/security_tools.sh"
source "$SCRIPT_DIR/modules/intrusion_detection.sh"
source "$SCRIPT_DIR/modules/optional_installs.sh"
source "$SCRIPT_DIR/modules/nginx.sh"
source "$SCRIPT_DIR/modules/backup_config.sh"
source "$SCRIPT_DIR/modules/additional_config.sh"
source "$SCRIPT_DIR/modules/provider_cleanup.sh"
source "$SCRIPT_DIR/modules/database_security.sh"
source "$SCRIPT_DIR/modules/finalization.sh"

# --- Error Handler ---
handle_error() {
    local exit_code=$?
    local line_no="$1"
    print_error "An error occurred on line $line_no (exit code: $exit_code)."
    print_info "Log file: $LOG_FILE"
    print_info "Backups: $BACKUP_DIR"
    exit $exit_code
}

# --- Main Function ---
main() {
    trap 'handle_error $LINENO' ERR

    # Initialize logging
    log "Starting modular Debian/Ubuntu hardening script."

    # Print header
    print_header

    # This maintenance mode intentionally skips the full server installer.
    if [[ "$NGINX_SECURITY_ONLY" == "true" ]]; then
        if ! command -v nginx >/dev/null 2>&1 &&
           ! { command -v docker >/dev/null 2>&1 && docker inspect nginx >/dev/null 2>&1; }; then
            print_error "No existing system or containerized Nginx installation was found."
            print_info "Run the full setup once before using --nginx-security."
            return 1
        fi
        print_info "Running Nginx security maintenance only; the full server setup will be skipped."
        configure_nginx_security
        print_success "Nginx security maintenance completed."
        return 0
    fi

    # --- PRELIMINARY CHECKS ---
    check_system
    run_update_check
    check_dependencies

    # --- HANDLE SPECIAL OPERATIONAL MODES ---
    if [[ "$CLEANUP_ONLY" == "true" ]]; then
        print_info "Running in cleanup-only mode..."
        detect_environment
        cleanup_provider_packages
        print_success "Cleanup-only mode completed."
        exit 0
    fi

    if [[ "$CLEANUP_PREVIEW" == "true" ]]; then
        print_info "Running cleanup preview mode..."
        detect_environment
        cleanup_provider_packages
        print_success "Cleanup preview completed."
        exit 0
    fi

    # --- NORMAL EXECUTION FLOW ---
    # Detect environment used for summary report at end.
    detect_environment

    # --- CORE SETUP AND HARDENING ---
    # Execution order is critical due to dependencies:
    # 1. collect_config() - Get user configuration
    # 2. install_packages() - Install base packages
    # 3. setup_user() - Create user and SSH keys
    # 4. configure_system() - Set hostname, timezone, etc.
    # 5. configure_firewall() - Set basic firewall rules
    # 6. configure_fail2ban() - Configure intrusion detection
    # 7. configure_ssh() - Harden SSH (depends on user setup)
    # 8. configure_auto_updates() - Set up automatic updates
    # 9. configure_time_sync() - Configure time synchronization
    # 10. configure_kernel_hardening() - Apply kernel security settings
    # 11. check_apparmor() - Check AppArmor profiles
    # 12. install_docker() - Optional Docker installation
    # 13. install_tailscale() - Optional Tailscale installation
    # 14. install_nginx() - Optional Nginx installation (container/host)
    # 15. configure_intrusion_detection() - Set up intrusion detection (Wazuh, AIDE, etc.)
    # 16. setup_backup() - Configure backup system
    # 17. configure_swap() - Configure swap space
    # 18. configure_security_audit() - Set up security auditing
    # 19. configure_database_security() - Optional database security (runs only if databases detected)

    collect_config
    install_packages
    setup_user
    configure_system
    configure_firewall
    configure_fail2ban
    configure_ssh
    configure_auto_updates
    configure_time_sync
    configure_kernel_hardening
    check_apparmor
    install_docker
    install_tailscale
    install_nginx
    configure_intrusion_detection
    setup_backup
    configure_swap
    configure_security_audit
    configure_database_security

    # --- PROVIDER PACKAGE CLEANUP ---
    if [[ "$SKIP_CLEANUP" == "false" ]]; then
        cleanup_provider_packages
    else
        print_info "Skipping provider cleanup (--skip-cleanup flag set)."
        log "Provider cleanup skipped via --skip-cleanup flag."
    fi

    # --- FINAL STEPS ---
    final_cleanup
    generate_summary

    print_success "Modular script execution completed."
    log "Modular script finished successfully."
}

# Run main function
main "$@"
