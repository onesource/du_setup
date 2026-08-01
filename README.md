# Debian & Ubuntu Server Setup & Hardening Script

[![Debian Compatibility](https://img.shields.io/badge/Compatibility–Debian%2012%7C13-%23A81D33?style=flat&labelColor=555&logo=debian&logoColor=white)](https://www.debian.org/releases/)
[![Ubuntu Compatibility](https://img.shields.io/badge/Compatibility–Ubuntu%2022.04%7C24.04-%23E95420?style=flat&labelColor=555&logo=ubuntu&logoColor=white)](https://ubuntu.com/download/server)
[![Shell Script Linter](https://github.com/onesource/du_setup/actions/workflows/lint.yml/badge.svg)](https://github.com/onesource/du_setup/actions/workflows/lint.yml)
[![Codacy Security Scan](https://github.com/onesource/du_setup/actions/workflows/codacy.yml/badge.svg?branch=main)](https://github.com/onesource/du_setup/actions/workflows/codacy.yml)

-----

**Version:** v0.75.3_modular

**Last Updated:** 2026-08-01

**Compatible With:**

* Debian 12, 13
* Ubuntu 20.04, 22.04, 24.04 (24.10 & 25.04 experimental)

## Overview

This repository implements a first-run installer and a declarative reconciler for Debian and Ubuntu servers. On later runs it observes live state, presents current values as defaults, and changes settings only after an explicit new choice. Treat releases as production candidates only after reviewing the generated plan and testing remote-access changes on a disposable server.

## Reconciliation and ownership model

- Live system state supplies prompt defaults; pressing Enter preserves it.
- Explicit intent is stored under `/etc/du-setup/state/` in root-owned files.
- Secrets are stored separately under `/etc/du-setup/credentials/`.
- The managed administrator is stored as `managed_admin`, migrated from `/root/.du_setup_managed_user`, and revalidated against the live account and sudo group every run.
- Files headed `MANAGED BY du_setup` may be overwritten. Put application-specific settings in separate include/snippet files.
- Installed-but-disabled optional services are treated as intentionally disabled and reported with instructions to opt back in.
- `--quiet` controls output only. `--non-interactive` keeps valid observed values and fails closed when first-run input is required.


### v0.75-modular - Declarative Reconciler Architecture

Version 0.74-modular introduces a significant architectural improvement with a modular design that separates functionality into distinct components:

* **Core Script**: The main script (`du_setup_modular.sh`) handles orchestration and user interaction
* **Library Components**: Shared utilities and configuration management in the `lib/` directory
* **Functional Modules**: Individual feature modules in the `modules/` directory for easy maintenance and extensibility
* **Improved Maintainability**: Each module can be updated independently without affecting the entire codebase
* **Enhanced Testing**: Modular structure allows for better unit testing of individual components
* **Easier Customization**: Users can now selectively enable/disable or modify specific modules

The modular version deliberately owns generated snippets and state; direct edits to du_setup-managed files are not a supported compatibility path.

-----

## Features

* **Secure User Management**: Creates a new `sudo` user and disables root SSH access. Optionally installs a custom .bashrc for enhanced terminal experience.
* **SSH Hardening**: Configures a custom SSH port, enforces key-based authentication, and applies security best practices.
* **Firewall Configuration**: Sets up UFW with secure defaults and customizable rules.
* **Intrusion Prevention**: Installs and configures **Fail2Ban** to block malicious IPs.
* **Host Intrusion Detection**: Optionally installs a manager-only **Wazuh** server and keeps its custom configuration isolated and validation-gated.
* **Kernel Hardening**: Optionally applies a set of recommended `sysctl` security settings to harden the kernel against common network and memory-related threats.
* **Automated Security Updates**: Enables `unattended-upgrades` for automatic security patches.
* **System Stability**: Configures NTP time synchronization with `chrony` and optional swap file setup for low-RAM systems.
* **Remote rsync Backups**: Configures automated `rsync` backups over SSH to any compatible server (e.g., Hetzner Storage Box), with SSH key automation (`sshpass` or manual), cron scheduling, ntfy/Discord notifications, and a customizable exclude file.
* **Backup Testing**: Includes an optional test backup to verify the rsync configuration before scheduling.
* **Tailscale VPN**: Installs Tailscale and connects to the standard Tailscale network (pre-auth key required) or a custom server (URL and key required). Configures optional flags (`--ssh`, `--advertise-exit-node`, `--accept-dns`, `--accept-routes`).
* **Security Auditing**: Optionally runs **Lynis** for system hardening audits and **debsecan** for package vulnerability checks, with results logged for review.
* **Nginx Web Server**: Installs and configures Nginx with two deployment options:
  * **Containerized Nginx** (recommended): Docker-based deployment with security-hardened configuration, SSL/TLS support, and resource limits
  * **Host-based Nginx**: Direct installation on the system for traditional deployments
  * Includes security headers, rate limiting, access controls, and performance optimizations
* **Nginx Certificate Management**: Automated SSL/TLS certificate handling:
  * Self-signed certificate generation for testing
  * Let's Encrypt integration with automatic renewal
  * Certificate import functionality for existing certificates
  * Certificate expiration monitoring and alerts
* **Nginx Security Monitoring**: Comprehensive monitoring and alerting:
  * Log analysis with attack pattern detection
  * Fail2Ban integration for Nginx-specific rules
  * Real-time security dashboard with metrics visualization
  * Performance monitoring with resource usage tracking
* **Nginx Vulnerability Scanner**: Automated security assessment:
  * Configuration security analysis
  * CVE monitoring and alerting
  * Container security scanning
  * Automated scanning with scheduled reports
* **Advanced Security Tools**: Enhanced security with additional tools:
  * **AIDE** (Advanced Intrusion Detection Environment) for file integrity monitoring
  * Extended kernel hardening with AMD EPYC optimizations
* **Safety First**: Backs up critical configuration files before modification, stored in `/root/setup_harden_backup_*`.
* **Optional Software**: Offers interactive installation of:
  * Docker & Docker Compose v2
  * Tailscale (Mesh VPN)
  * Nginx Web Server (containerized or host-based)
  * Advanced security tools (AIDE)
* **Comprehensive Logging**: Logs all actions to `/var/log/du_setup_*.log`.
* **Automation Safety**: `--quiet` never grants consent; `--non-interactive` preserves valid detected state and fails closed when required input is missing.

-----

## Important operational boundaries

- Docker Compose v2 (`docker compose`) is required; Compose v1 is unsupported.
- Docker-published ports require Docker-aware firewall review because they do not follow ordinary UFW INPUT handling.
- Wazuh is manager-only. Use it when this host forwards to an external Wazuh indexer/dashboard; for a single Netcup host without external analytics, Fail2ban, auditd, and AIDE are the lighter default.
- Database application access rules are never replaced. Native managed settings use dedicated includes; container database configuration remains application-owned.
- The complete repository self-updater validates and swaps an installed non-Git tree atomically. It refuses to overwrite dirty Git worktrees.

## Installation & Usage

### Prerequisites

* Fresh installation of a compatible OS.
* Root or `sudo` privileges.
* Internet access for package downloads.
* Minimum 2GB disk space for swap file creation and temporary files.
* For remote backups: An SSH-accessible server (e.g., Hetzner Storage Box) with credentials or SSH key access. For Hetzner, SSH (port 23) is used for rsync.
* For Tailscale: A pre-auth key from [https://login.tailscale.com/admin](https://login.tailscale.com/admin) (standard, starts with `tskey-auth-`) or from a custom server (e.g., `https://ts.mydomain.cloud`).

### 1. Download & Prepare Script

#### Modular Script (v0.75-modular)
```bash
git clone https://github.com/onesource/du_setup.git
cd du_setup
chmod +x du_setup_modular.sh
```

> **Note**: This is the new modular architecture version with improved code organization and maintainability.

### 2. Verify Script Integrity (Recommended)

To ensure the script has not been altered, you can verify its SHA256 checksum.

#### For Modular Script (v0.75-modular)

```bash
# Download the official checksum file
wget https://raw.githubusercontent.com/onesource/du_setup/refs/heads/main/du_setup_modular.sh.sha256

# Run the check (it should output: du_setup_modular.sh: OK)
sha256sum -c du_setup_modular.sh.sha256
```

> **Note**: The SHA256 checksum for the modular version will be available after the initial release.

### 3. Run the Script

#### Interactively (Recommended)

Ideally run as root, if you are a sudo user you can switch to root with `sudo su`

For the modular script:
```bash
./du_setup_modular.sh
```

Alternatively run with sudo -E, -E flag preserve the environment variables.

For the modular script:
```bash
sudo -E ./du_setup_modular.sh
```

#### Quiet and non-interactive modes

`--quiet` suppresses informational output but still prompts. `--non-interactive` never invents missing first-run values; use it only after an interactive run has established required state.


For the modular script:
```bash
sudo -E ./du_setup_modular.sh --quiet
sudo -E ./du_setup_modular.sh --non-interactive
```

> **Warning**: The script pauses to verify SSH access on the new port before disabling old access methods. **Test the new SSH connection from a separate terminal before proceeding!**
>
> Ensure your VPS provider’s firewall allows the custom SSH port, backup server’s SSH port (e.g., 23 for Hetzner Storage Box), and Tailscale traffic (UDP 41641 for direct connections).

-----

## What It Does

| Task | Description |
| :--- | :--- |
| **Provider Package Cleanup** | Detects and optionally removes cloud provider packages, monitoring agents, and default provisioning users to reduce attack surface and unnecessary services. |
| **System Compatibility Checks** | Verifies OS compatibility, root privileges, and internet connectivity. |
| **Package Management** | Updates package indexes, upgrades installed packages, and ensures the declared base package set is installed. |
| **Setup User Creation & Management**| Creates or uses an existing admin user with optional SSH key setup and strong password enforcement. Includes marker file for cleanup exclusion. |
| **SSH Hardening and Rollback** | Disables root login, configures key-based authentication, sets custom SSH port, and supports rollback of SSH configuration if connectivity fails. |
| **Firewall Setup** | Configures UFW to deny incoming traffic by default, allowing specific user-defined ports. |
| **Fail2Ban Setup** | Configures Fail2Ban to monitor SSH and UFW logs, blocking suspicious IPs. |
| **Auto-Updates Setup** | Enables and configures `unattended-upgrades` for automatic security patches. |
| **Time Sync Setup** | Ensures `chrony` is active for accurate network time synchronization. |
| **Kernel and Sysctl Hardening** | Optional improvements to kernel parameters to mitigate common network attacks and improve system hardening. |
| **Docker Install** | Installs Docker Engine and Docker Compose v2, merges du_setup daemon keys into valid existing JSON, then adds the admin user to the `docker` group. |
| **Tailscale Setup** | Installs Tailscale and connects to a mesh network using a pre-auth key, with optional advanced flags. |
| **Automated Remote Backup**| Sets up cron-driven `rsync` backup script to remote SSH servers, integrates with notifications and performs backup verification. |
| **Swap File Setup** | Creates an optional swap file with tuned `swappiness` and `vfs_cache_pressure` settings. |
| **Security Auditing** | Runs optional **Lynis** and **debsecan** vulnerability audits and logs the results for review. |
| **Logging and Reporting** | Logs all actions and generates a detailed report of setup and cleanup in `/var/log` and backup directories. Saves timestamped backups of modified configuration files in `/root/setup_harden_backup_*`. |
| **Cleanup & Maintenance** | Reports final service state and reloads systemd; package removal occurs only through the separately confirmed provider-cleanup workflow. |
| **Final Summary** | Generates a detailed report of all changes and saves it to `/var/log/du_setup_report_*.txt`. |

-----

## Provider Package Cleanup

Detects and optionally removes provider-installed packages, monitoring agents, and default provisioning users to enhance server security.

Cleanup is optional but recommended for commercial VPS environments to reduce attack surface. Review preview outputs carefully before applying cleanup.

### Usage

* **Preview cleanup actions:** `sudo ./du_setup_modular.sh --cleanup-preview`
  Shows what would be removed without making changes.
* **Run cleanup only:** `sudo ./du_setup_modular.sh --cleanup-only`
  Executes provider cleanup on existing servers without full setup.
* **Skip cleanup:** `sudo ./du_setup_modular.sh --skip-cleanup`
  Runs full setup but skips the cleanup phase.

### What it detects

* Common cloud provider monitoring agents (e.g., DigitalOcean, Hetzner, Vultr)
* Virtualization guest tools (qemu-guest-agent, cloud-init)
* Default provisioning users (ubuntu, debian, admin, cloud-user)
* Unexpected SSH keys in `/root/.ssh/authorized_keys`

-----

## Post-Reboot Verification

After rebooting, verify the setup:

* **SSH Access**: `ssh -p <custom_port> <username>@<server_ip>`
* **Firewall Rules**: `sudo ufw status verbose`
* **Time Synchronization**: `chronyc tracking`
* **Fail2Ban Status**: `sudo fail2ban-client status sshd`
* **Swap Status**: `sudo swapon --show && free -h`
* **Hostname**: `hostnamectl`
* **Kernal Hardening** (if configured):
  * Check the conf file: `sudo cat /etc/sysctl.d/99-du-hardening.conf`
  * Checks the live value of a few key parameters that script sets: `sudo sysctl fs.protected_hardlinks kernel.yama.ptrace_scope net.ipv4.tcp_syncookies`
* **Docker Status** (if installed): `docker ps`
* **Tailscale Status** (if installed): `tailscale status`
* **Tailscale Verification** (if configured):
  * Check connection: `tailscale status`
  * Test Tailscale SSH (if enabled): `tailscale ssh <username>@<tailscale-ip>`
  * Verify exit node (if enabled): Check Tailscale admin console
  * If not connected, run the `tailscale up` command shown in the script output
* **Remote Backup** (if configured):
  * Verify SSH key: `cat /root/.ssh/id_ed25519.pub`
  * Copy key (if not done): `ssh-copy-id -p <backup_port> -s <backup_user@backup_host>`
  * Test backup: `sudo /root/run_backup.sh`
  * Check logs: `sudo less /var/log/backup_rsync.log`
  * Verify cron job: `sudo crontab -l` (e.g., `5 3 * * * /root/run_backup.sh`)
* **Security Audit** (if run):
  * Check results: `sudo less /var/log/setup_harden_security_audit_*.log`
  * Review Lynis hardening index and debsecan vulnerabilities in the script’s summary output

-----

## Tested On

* Debian 12, 13
* Ubuntu 22.04, 24.04 - 24.10 & 25.04 (experimental)
* Cloud providers: DigitalOcean, Oracle Cloud, OVH Cloud, Hetzner, Netcup
* Backup destinations: Hetzner Storage Box (SSH, port 23), custom SSH servers
* Tailscale: Standard network, custom self-hosted servers

-----

## Important Notes

* **Run on a fresh system**: Designed for initial provisioning with at least 2GB free disk space.
* **Reboot required**: Ensures kernel and service changes apply cleanly.
* Test in a non-production environment (e.g., staging VM) first.
* Maintain out-of-band console access in case of SSH lockout.
* For Hetzner Storage Box, ensure `~/.ssh/` exists on the remote server: `ssh -p 23 <backup_user@backup_host> "mkdir -p ~/.ssh && chmod 700 ~/.ssh"`. Backups use SSH (port 23) for rsync, not SFTP.
* For Tailscale, generate a pre-auth key from [https://login.tailscale.com/admin](https://login.tailscale.com/admin) (standard, must start with `tskey-auth-`) or your custom server (any valid key). Ensure UDP 41641 is open for Tailscale traffic.
* For security audits, review `/var/log/setup_harden_security_audit_*.log` for Lynis and debsecan recommendations.

-----

## Troubleshooting

### SSH Lockout Recovery

If locked out, use your provider’s console:

1. **Remove Hardened Configuration**:

    ```bash
    sudo rm /etc/ssh/sshd_config.d/99-hardening.conf
    ```

2. **Restore Original `sshd_config`**:

    ```bash
    LATEST_BACKUP=$(ls -td /root/setup_harden_backup_* | head -1)
    sudo cp "$LATEST_BACKUP"/sshd_config.backup_* /etc/ssh/sshd_config
    ```

3. **Restart SSH**:

    ```bash
    sudo systemctl restart ssh
    ```

### Backup Issues

If backups fail:

1. **Verify SSH Key**:
      * Check: `sudo cat /root/.ssh/id_ed25519.pub`
      * Copy (if needed): `sudo ssh-copy-id -p <backup_port> -s <backup_user@backup_host>`
      * For Hetzner: `sudo ssh -p 23 <backup_user@backup_host> "mkdir -p ~/.ssh && chmod 700 ~/.ssh"`
      * Test SSH: `sudo ssh -p <backup_port> <backup_user@backup_host> exit`
2. **Check Logs**:
      * Review: `sudo less /var/log/backup_rsync.log`
      * If automated key copy fails: `cat /tmp/ssh-copy-id.log`
3. **Test Backup Manually**:

    ```bash
    sudo /root/run_backup.sh
    ```

4. **Verify Cron Job**:
      * Check: `sudo crontab -l`
      * Ensure: `5 3 * * * /root/run_backup.sh #-*- managed by setup_harden script -*-`
      * Test cron permissions: `echo "5 3 * * * /root/run_backup.sh" | crontab -u root -`
      * Check permissions: `ls -l /var/spool/cron/crontabs/root` (expect `-rw------- root:crontab`)
5. **Network Issues**:
      * Verify port: `nc -zv <backup_host> <backup_port>`
      * Check VPS firewall for outbound access to the backup port (e.g., 23 for Hetzner).
6. **Summary Errors**:
      * If summary shows `Remote Backup: Not configured`, verify: `ls -l /root/run_backup.sh`

### Security Audit Issues

If audits fail:

1. **Check Audit Log**:
      * Review: `sudo less /var/log/setup_harden_security_audit_*.log`
      * Look for Lynis errors or debsecan CVE reports
2. **Verify Installation**:
      * Lynis: `command -v lynis`
      * Debsecan: `command -v debsecan`
      * Reinstall if needed: `sudo apt-get install lynis debsecan`
3. **Run Manually**:
      * Lynis: `sudo lynis audit system --quick`
      * Debsecan: `sudo debsecan --suite $(source /etc/os-release && echo $VERSION_CODENAME)`

### Tailscale Issues

If Tailscale fails to connect:

1. **Verify Installation**:
      * Check: `command -v tailscale`
      * Service status: `sudo systemctl status tailscaled`
2. **Check Connection**:
      * Run: `tailscale status`
      * Verify server: `tailscale status --json | grep ControlURL`
      * Check logs: `sudo journalctl -u tailscaled`
3. **Test Pre-Auth Key**:
      * Re-run the command shown in the script output (e.g., `sudo tailscale up --auth-key=<key> --operator=<username>` or with `--login-server=<url>`).
      * For custom servers, ensure the key is valid for the specified server (e.g., generated from `https://ts.mydomain.cloud`).
4. **Additional Flags**:
      * Verify SSH: `tailscale ssh <username>@<tailscale-ip>`
      * Check exit node: Tailscale admin console
      * Verify DNS: `cat /etc/resolv.conf`
      * Check routes: `tailscale status`
5. **Network Issues**:
      * Ensure UDP 41641 is open: `nc -zvu <tailscale-server> 41641`
      * Check VPS firewall for Tailscale traffic.

-----

## MIT [License](https://github.com/onesource/du_setup/blob/main/LICENSE)

This script is open-source and provided "as is" without warranty. Use at your own risk.
