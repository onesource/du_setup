# Changelog for du_setup_modular.sh

## Version 0.74-modular | 2025-11-08

### Modular Architecture
- Refactored original monolithic script into modular architecture
- Separated functionality into individual modules for better maintainability
- Created lib/ directory for shared configuration and utilities
- Created modules/ directory for specialized functionality

### New Modules Added
- **Nginx Web Server Module** (`nginx.sh`)
  - Containerized Nginx deployment with Docker (recommended)
  - Host-based Nginx installation option
  - Security-hardened configuration with headers and rate limiting
  - SSL/TLS support with automatic HTTPS redirect template
- **Nginx Certificate Management** (`nginx_cert_manager.sh`)
  - Self-signed certificate generation for testing
  - Let's Encrypt integration with automatic renewal
  - Certificate import functionality for existing certificates
  - Certificate expiration monitoring and alerts
- **Nginx Security Monitoring** (`nginx_monitoring.sh`)
  - Log analysis with attack pattern detection
  - Fail2Ban integration for Nginx-specific rules
  - Real-time security dashboard with metrics visualization
  - Performance monitoring with resource usage tracking
- **Nginx Vulnerability Scanner** (`nginx_vuln_scanner.sh`)
  - Configuration security analysis
  - CVE monitoring and alerting
  - Container security scanning
  - Automated scanning with scheduled reports
- **Advanced Security Tools** (enhancements to `security_tools.sh`)
  - AIDE (Advanced Intrusion Detection Environment) for file integrity monitoring
  - AppArmor security profiles for application confinement
  - Extended kernel hardening with AMD EPYC optimizations

### Key Improvements
- **Better Organization**: Each module handles specific functionality
- **Easier Maintenance**: Modules can be updated independently
- **Cleaner Code**: Separated concerns into focused files
- **Reusability**: Common functions centralized in lib/

### Module Structure
- **lib/**: Core configuration and utilities
  - `config.sh`: Global variables and configuration
  - `utils.sh`: Common utility functions
- **modules/**: Specialized functionality
  - `environment.sh`: Environment detection
  - `system_config.sh`: System configuration and update checks
  - `user_management.sh`: User creation and management
  - `ssh_config.sh`: SSH hardening
  - `firewall.sh`: Firewall configuration
  - `security_tools.sh`: Security tools installation
  - `optional_installs.sh`: Optional software installation
  - `nginx.sh`: Nginx configuration and management
  - `backup_config.sh`: Backup system setup
  - `additional_config.sh`: Additional configurations
  - `provider_cleanup.sh`: Cloud provider cleanup
  - `finalization.sh`: Final cleanup and summary

### Update System
- Maintains same update functionality as original script
- Uses single checksum file for integrity verification
- Supports automatic updates from GitHub

### Compatibility
- Maintains compatibility with original script's functionality
- Preserves all command-line options and operational modes
- Compatible with Debian 12/13 and Ubuntu 20.04/22.04/24.04

### Migration from Original
- Drop-in replacement for `du_setup.sh`
- All familiar options and workflows preserved
- Enhanced modular architecture for better maintainability

## Previous Versions (from original du_setup.sh by buildplan)

### v0.73 | 2025-10-22
- Revised/improved logic in .bashrc for memory and system updates.
- Added configure_custom_bashrc() function that creates and installs a feature-rich .bashrc file during user creation.

### v0.72 | 2025-10-22
- Simplify test backup function to work reliably with Hetzner storagebox

### v0.71 | 2025-10-22
- Fix SSH port validation and improve firewall handling during SSH port transitions.

### v0.70.1 | 2025-10-22
- Option to remove cloud VPS provider packages (like cloud-init).
- New operational modes: --cleanup-preview, --cleanup-only, --skip-cleanup.
- Add help and usage instructions with --help flag.
- Improve SSH port validation and rollback logic.

### v0.70 | 2025-10-22
- Ensure .ssh directory ownership is set for new user.
- While configuring and in the summary, display both IPv6 and IPv4.

### v0.69 | 2025-10-22
- Ensure .ssh directory ownership is set for new user.

### v0.68 | 2025-10-22
- Enable UFW IPv6 support if available
- Do not log tailscale auth key in log file

### v0.67 | 2025-10-22
- While configuring and in the summary, display both IPv6 and IPv4.
- If reconfigure locales - apply newly configured locale to the current environment.

### v0.66 | 2025-10-22
- If reconfigure locales - apply newly configured locale to the current environment.

### v0.65 | 2025-10-22
- If reconfigure locales - apply newly configured locale to the current environment.

### v0.64 | 2025-10-22
- Tested at Debian 13 to confirm it works as expected

### v0.63 | 2025-10-22
- Added ssh install in key packages

### v0.62 | 2025-10-22
- Added fix for fail2ban by creating empty ufw log file

### v0.61 | 2025-10-22
- Display Lynis suggestions in summary, hide tailscale auth key, cleanup temp files

### v0.60 | 2025-10-22
- CI for shellcheck

### v0.59 | 2025-10-22
- Add a new optional function that applies a set of recommended sysctl security settings to harden the kernel.
- Script can now check for update and can run self-update.

### v0.58 | 2025-10-22
- improved fail2ban to parse ufw logs

### v0.57 | 2025-10-22
- Fix for silent failure at test_backup()
- Option to choose which directories to back up.
- Added tailscale config to connect to tailscale or headscale server.

### v0.56 | 2025-10-22
- Make tailscale config optional
- Improving setup_user() - ssh-keygen replaced the option to skip ssh key

### v0.55 | 2025-10-22
- Improving setup_user() - ssh-keygen replaced the option to skip ssh key

### v0.54 | 2025-10-22
- Fix for rollback_ssh_changes() - more reliable on newer Ubuntu
- Better error message if script is executed by non-root or without sudo

### v0.53 | 2025-10-22
- Fix for test_backup() - was failing if run as non root sudo user

### v0.52 | 2025-10-22
- Roll-back SSH config on failure to configure SSH port, confirmed SSH config support for Ubuntu 24.10

### v0.51 | 2025-10-22
- corrected repo links

### v0.50 | 2025-10-22
- versioning format change and repo name change

### v4.3 | 2025-10-22
- Add SHA256 integrity verification

### v4.2 | 2025-10-22
- Added Security Audit Tools (Integrating Lynis and Optionally Debsecan) & option to do Backup Testing
- Fixed debsecan compatibility (Debian-only), added global BACKUP_LOG, added backup testing

### v4.1 | 2025-10-22
- Added tailscale config to connect to tailscale or headscale server

### v4.0 | 2025-10-22
- Added automated backup config. Mainly for Hetzner Storage Box but can be used for any rsync/SSH enabled remote solution.

### v3.*: Improvements to script flow and fixed bugs which were found in tests at Oracle Cloud

#
# Description:
# This script provisions and hardens a fresh Debian 12 or Ubuntu server with essential security
# configurations, user management, SSH hardening, firewall setup, and optional features
# like Docker and Tailscale and automated backups to Hetzner storage box or any rsync location.
# It is designed to be idempotent, safe.
# README at GitHub: https://github.com/onesource/du_setup/blob/main/README.md