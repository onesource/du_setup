#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Configuration Module
# Global variables and configuration settings
# ============================================================================

# shellcheck disable=SC2034  # Variables are used in other modules that source this file

# --- Admin Info ---
ADMIN_EMAIL="admin@example.com"

# --- Update Configuration ---
CURRENT_VERSION="0.74.2_modular"
SCRIPT_URL="https://raw.githubusercontent.com/onesource/du_setup/refs/heads/main/du_setup_modular.sh"
CONFIG_URL="https://raw.githubusercontent.com/onesource/du_setup/refs/heads/main/lib/config.sh"
CHECKSUM_URL="${SCRIPT_URL}.sha256"

# --- Script Variables ---
LOG_FILE="/var/log/du_setup_$(date +%Y%m%d_%H%M%S).log"
BACKUP_LOG="/var/log/backup_rsync.log"
REPORT_FILE="/var/log/du_setup_report_$(date +%Y%m%d_%H%M%S).txt"
VERBOSE=true
BACKUP_DIR="/root/setup_harden_backup_$(date +%Y%m%d_%H%M%S)"
ORIGINAL_ARGS="$*"

# --- Operational Mode Flags ---
CLEANUP_PREVIEW=false
CLEANUP_ONLY=false
SKIP_CLEANUP=false

# --- Environment Detection Variables ---
DETECTED_VIRT_TYPE=""
DETECTED_MANUFACTURER=""
DETECTED_PRODUCT=""
DETECTED_BIOS_VENDOR=""
IS_CLOUD_PROVIDER=false
IS_CONTAINER=false
ENVIRONMENT_TYPE=""
DETECTED_PROVIDER_NAME=""

# --- SSH Configuration ---
SSHD_BACKUP_FILE=""
LOCAL_KEY_ADDED=false
SSH_SERVICE=""
PREVIOUS_SSH_PORT=""

# --- System Information ---
ID=""
FAILED_SERVICES=()
SERVER_IP_V4=""
SERVER_IP_V6=""

# --- User Configuration ---
USERNAME=""
USER_EXISTS=false
SERVER_NAME=""
PRETTY_NAME=""
SSH_PORT=""

# --- Timezone and Locale ---
TIMEZONE=""

# --- Backup Configuration ---
BACKUP_DEST=""
BACKUP_PORT=""
REMOTE_BACKUP_PATH=""
NOTIFICATION_SETUP="none"
NTFY_URL=""
NTFY_TOKEN=""
DISCORD_WEBHOOK=""

# --- Tailscale Configuration ---
TS_CONNECTION=""
TS_COMMAND=""
TS_FLAGS=""

# --- Security Audit Configuration ---
AUDIT_RAN=false
AUDIT_LOG=""
HARDENING_INDEX=""
DEBSECAN_VULNS=""

# --- Intrusion Detection Configuration (WAZUH & AIDE) ---
WAZUH_CONF="/var/ossec/etc/ossec.conf"
WAZUH_CONTROL="/var/ossec/bin/wazuh-control"
WAZUH_ALERTS_LOG="/var/ossec/logs/alerts/alerts.log"
LOCAL_INCLUDE_DIR="/var/ossec/etc/local"
RULES_INCLUDE_DIR="/var/ossec/etc/rules"
LOCALFILE_INCLUDE="${LOCAL_INCLUDE_DIR}/localfile_custom.conf"
SYSCHECK_INCLUDE="${LOCAL_INCLUDE_DIR}/syscheck_custom.conf"
LOCAL_RULES_FILE="${RULES_INCLUDE_DIR}/local_rules_custom.xml"
ACTIVE_RESPONSE_DIR="/var/ossec/active-response/bin"
ACTIVE_RESPONSE_SCRIPT="${ACTIVE_RESPONSE_DIR}/firewall-drop.sh"

RKHUNTER_CONF_LOCAL="/etc/rkhunter.conf.local"
RKHUNTER_LOG="/var/log/rkhunter.log"  # Assuming standard log path
AIDE_CONF="/etc/aide/aide.conf"
AIDE_DB="/var/lib/aide/aide.db"

# Thresholds and Alert Levels
SSH_FAILURE_THRESHOLD=10
SUDO_COUNT_THRESHOLD=50
HIGH_ALERTS_LEVEL="7-9"  # Configurable
CPU_THRESHOLD=80    # Default CPU usage 80%
MEM_THRESHOLD=90    # Default Memory usage 90%
CONN_THRESHOLD=200  # Default Network connections 200
PROC_THRESHOLD=300  # Default Processes 300
DISK_THRESHOLD=90  # New: Disk usage %

# --- Initialize Configuration ---
init_config() {
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"

    # Initialize log file
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

    # Initialize report file
    touch "$REPORT_FILE" && chmod 600 "$REPORT_FILE"

    log "Configuration initialized"
}