#!/bin/bash

# ============================================================================
# du_setup.sh - Configuration Module
# Global variables and configuration settings
# ============================================================================

# --- Update Configuration ---
CURRENT_VERSION="0.74-modular"
SCRIPT_URL="https://raw.githubusercontent.com/onesource/du_setup/refs/heads/main/du_setup_modular.sh"
CHECKSUM_URL="${SCRIPT_URL}.sha256"

# --- Script Variables ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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