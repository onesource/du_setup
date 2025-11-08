#!/bin/bash

# ============================================================================
# du_setup.sh - Backup Configuration Module
# Handles rsync backup configuration and setup
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Backup Configuration Function ---
setup_backup() {
    print_section "Backup Configuration (rsync over SSH)"

    if ! confirm "Configure rsync-based backups to a remote SSH server?"; then
        print_info "Skipping backup configuration."
        log "Backup configuration skipped by user."
        return 0
    fi

    # --- Pre-flight Check ---
    if [[ -z "$USERNAME" ]] || ! id "$USERNAME" >/dev/null 2>&1; then
        print_error "Cannot configure backup: valid admin user ('$USERNAME') not found."
        log "Backup configuration failed: USERNAME variable not set or user does not exist."
        return 1
    fi

    local ROOT_SSH_DIR="/root/.ssh"
    local ROOT_SSH_KEY="$ROOT_SSH_DIR/id_ed25519"
    local BACKUP_SCRIPT_PATH="/root/run_backup.sh"
    local EXCLUDE_FILE_PATH="/root/rsync_exclude.txt"
    local CRON_MARKER="#-*- installed by du_setup script -*-"

    # --- Generate SSH Key for Root ---
    if [[ ! -f "$ROOT_SSH_KEY" ]]; then
        print_info "Generating a dedicated SSH key for root's backup job..."
        mkdir -p "$ROOT_SSH_DIR" && chmod 700 "$ROOT_SSH_DIR"
        ssh-keygen -t ed25519 -f "$ROOT_SSH_KEY" -N "" -q
        chown -R root:root "$ROOT_SSH_DIR"
        print_success "Root SSH key generated at $ROOT_SSH_KEY"
        log "Generated root SSH key for backups."
    else
        print_info "Existing root SSH key found at $ROOT_SSH_KEY."
    fi

    # --- Collect Backup Destination Details with Retry Loops ---
    local BACKUP_DEST BACKUP_PORT REMOTE_BACKUP_PATH SSH_COPY_ID_FLAGS=""

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter backup destination (e.g., u12345@u12345.your-storagebox.de): ${NC}")" BACKUP_DEST
        if [[ "$BACKUP_DEST" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$ ]]; then break; else print_error "Invalid format. Expected user@host. Please try again."; fi
    done

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter destination SSH port (Hetzner uses 23) [22]: ${NC}")" BACKUP_PORT
        BACKUP_PORT=${BACKUP_PORT:-22}
        if [[ "$BACKUP_PORT" =~ ^[0-9]+$ && "$BACKUP_PORT" -ge 1 && "$BACKUP_PORT" -le 65535 ]]; then break; else print_error "Invalid port. Must be between 1 and 65535. Please try again."; fi
    done

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter remote backup path (e.g., /home/my_backups/): ${NC}")" REMOTE_BACKUP_PATH
        if [[ "$REMOTE_BACKUP_PATH" =~ ^/[^[:space:]]*/$ ]]; then break; else print_error "Invalid path. Must start and end with '/' and contain no spaces. Please try again."; fi
    done

    print_info "Backup target set to: ${BACKUP_DEST}:${REMOTE_BACKUP_PATH} on port ${BACKUP_PORT}"

    # --- Hetzner Specific Handling ---
    if confirm "Is this backup destination a Hetzner Storage Box (requires special -s flag for key copy)?"; then
        SSH_COPY_ID_FLAGS="-s"
        print_info "Hetzner Storage Box mode enabled. Using '-s' for ssh-copy-id."
    fi

    # --- Handle SSH Key Copy ---
    printf '%s\n' "${CYAN}Choose how to copy root SSH key:${NC}"
    printf '  1) Automate with password (requires sshpass, password stored briefly in memory)\n'
    printf '  2) Manual copy (recommended)\n'
    read -rp "$(printf '%s' "${CYAN}Enter choice (1-2) [2]: ${NC}")" KEY_COPY_CHOICE
    KEY_COPY_CHOICE=${KEY_COPY_CHOICE:-2}
    if [[ "$KEY_COPY_CHOICE" == "1" ]]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            print_info "Installing sshpass for automated key copying..."
            if ! { apt-get update -qq && apt-get install -y -qq sshpass; }; then
                print_warning "Failed to install sshpass. Falling back to manual copy."
                KEY_COPY_CHOICE=2
            fi
        fi
        if [[ "$KEY_COPY_CHOICE" == "1" ]]; then
            read -rsp "$(printf '%s' "${CYAN}Enter password for $BACKUP_DEST: ${NC}")" BACKUP_PASSWORD; printf '\n'
            # Ensure ~/.ssh/ exists on remote for Hetzner
            if [[ -n "$SSH_COPY_ID_FLAGS" ]]; then
                ssh -p "$BACKUP_PORT" "$BACKUP_DEST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null || print_warning "Failed to create ~/.ssh on remote server."
            fi
            if SSHPASS="$BACKUP_PASSWORD" sshpass -e ssh-copy-id -p "$BACKUP_PORT" -i "$ROOT_SSH_KEY.pub" $SSH_COPY_ID_FLAGS "$BACKUP_DEST" 2>&1 | tee /tmp/ssh-copy-id.log; then
                print_success "SSH key copied successfully."
            else
                print_error "Automated SSH key copy failed. Error details in /tmp/ssh-copy-id.log."
                print_info "Please verify password and ensure ~/.ssh/authorized_keys is writable on the remote server."
                KEY_COPY_CHOICE=2
            fi
        fi
    fi
    if [[ "$KEY_COPY_CHOICE" == "2" ]]; then
        print_warning "ACTION REQUIRED: Copy root SSH key to backup destination."
        printf 'This will allow root user to connect without a password for automated backups.\n'
        printf '%s' "${YELLOW}The root user's public key is:${NC}"; cat "${ROOT_SSH_KEY}.pub"; printf '\n'
        printf '%s\n' "${YELLOW}Run the following command from this server's terminal to copy the key:${NC}"
        printf '%s\n' "${CYAN}ssh-copy-id -p \"${BACKUP_PORT}\" -i \"${ROOT_SSH_KEY}.pub\" ${SSH_COPY_ID_FLAGS} \"${BACKUP_DEST}\"${NC}"; printf '\n'
        if [[ -n "$SSH_COPY_ID_FLAGS" ]]; then
            print_info "For Hetzner, ensure ~/.ssh/ exists on remote server: ssh -p \"$BACKUP_PORT\" \"$BACKUP_DEST\" \"mkdir -p ~/.ssh && chmod 700 ~/.ssh\""
        fi
    fi

    # --- SSH Connection Test ---
    if confirm "Test SSH connection to backup destination (recommended)?"; then
        print_info "Testing SSH connection (timeout: 10 seconds)..."
        if [[ ! -f "$ROOT_SSH_DIR/known_hosts" ]] || ! grep -q "$BACKUP_DEST" "$ROOT_SSH_DIR/known_hosts"; then
            print_warning "SSH key may not be copied yet. Connection test may fail."
        fi
        local test_command="ssh -p \"$BACKUP_PORT\" -o BatchMode=yes -o ConnectTimeout=10 \"$BACKUP_DEST\" true"
        if [[ -n "$SSH_COPY_ID_FLAGS" ]]; then
            test_command="sftp -P \"$BACKUP_PORT\" -o BatchMode=yes -o ConnectTimeout=10 \"$BACKUP_DEST\" <<< 'quit'"
        fi
        if eval "$test_command" 2>/dev/null; then
            print_success "SSH connection to backup destination successful!"
        else
            print_error "SSH connection test failed. Please ensure key was copied correctly and port is open."
            print_info "  - Copy key: ssh-copy-id -p \"$BACKUP_PORT\" -i \"$ROOT_SSH_KEY.pub\" $SSH_COPY_ID_FLAGS \"$BACKUP_DEST\""
            print_info "  - Check port: nc -zv $(echo \"$BACKUP_DEST\" | cut -d'@' -f2) \"$BACKUP_PORT\""
            print_info "  - Ensure key is in ~/.ssh/authorized_keys on the backup server."
            if [[ -n "$SSH_COPY_ID_FLAGS" ]]; then
                print_info "  - For Hetzner, ensure ~/.ssh/ exists on remote server: ssh -p \"$BACKUP_PORT\" \"$BACKUP_DEST\" \"mkdir -p ~/.ssh && chmod 700 ~/.ssh\""
            fi
        fi
    fi

    # --- Collect Backup Source Directories ---
    local BACKUP_DIRS_ARRAY=()
    while true; do
        print_info "Enter full paths of directories to back up, separated by spaces."
        read -rp "$(printf '%s' "${CYAN}Default is '/home/${USERNAME}/'. Press Enter for default or provide your own: ${NC}")" -a user_input_dirs
        if [ ${#user_input_dirs[@]} -eq 0 ]; then
            BACKUP_DIRS_ARRAY=("/home/${USERNAME}/")
            break
        fi

        local all_valid=true
        for dir in "${user_input_dirs[@]}"; do
            if [[ ! "$dir" =~ ^/ ]]; then
                print_error "Invalid path: '$dir'. All paths must be absolute (start with '/'). Please try again."
                all_valid=false
                break
            fi
        done

        if [[ "$all_valid" == true ]]; then
            BACKUP_DIRS_ARRAY=("${user_input_dirs[@]}")
            break
        fi
    done
    # Convert array to a space-separated string for backup script
    local BACKUP_DIRS_STRING="${BACKUP_DIRS_ARRAY[*]}"
    print_info "Directories to be backed up: $BACKUP_DIRS_STRING"

    # --- Create Exclude File ---
    print_info "Creating rsync exclude file at $EXCLUDE_FILE_PATH..."
    tee "$EXCLUDE_FILE_PATH" > /dev/null <<'EOF'
# Default Exclusions
.cache/
.docker/
.local/
.npm/
.ssh/
.vscode-server/
*.log
*.tmp
node_modules/
.bashrc
.bash_history
.bash_logout
.cloud-locale-test.skip
.profile
.wget-hsts
EOF
    if confirm "Add more directories/files to exclude list?"; then
        read -rp "$(printf '%s' "${CYAN}Enter items separated by spaces (e.g., Videos/ 'My Documents/'): ${NC}")" -a extra_excludes
        for item in "${extra_excludes[@]}"; do echo "$item" >> "$EXCLUDE_FILE_PATH"; done
    fi
    chmod 600 "$EXCLUDE_FILE_PATH"
    print_success "Rsync exclude file created."

    # --- Collect Cron Schedule ---
    local CRON_SCHEDULE="5 3 * * *"
    print_info "Enter a cron schedule for backup. Use https://crontab.guru for help."
    read -rp "$(printf '%s' "${CYAN}Enter schedule (default: daily at 3:05 AM) [${CRON_SCHEDULE}]: ${NC}")" input
    CRON_SCHEDULE="${input:-$CRON_SCHEDULE}"
    if ! echo "$CRON_SCHEDULE" | grep -qE '^((\*\/)?[0-9,-]+|\*)\s+(((\*\/)?[0-9,-]+|\*)\s+){3}((\*\/)?[0-9,-]+|\*|[0-6])$'; then
        print_error "Invalid cron expression. Using default: ${CRON_SCHEDULE}"
    fi

    # --- Collect Notification Details ---
    local NOTIFICATION_SETUP="none" NTFY_URL="" NTFY_TOKEN="" DISCORD_WEBHOOK=""
    if confirm "Enable backup status notifications?"; then
        printf '%s' "${CYAN}Select notification method: 1) ntfy.sh 2) Discord  [1]: ${NC}"; read -r n_choice
        if [[ "$n_choice" == "2" ]]; then
            NOTIFICATION_SETUP="discord"
            read -rp "$(printf '%s' "${CYAN}Enter Discord Webhook URL: ${NC}")" DISCORD_WEBHOOK
            if [[ ! "$DISCORD_WEBHOOK" =~ ^https://discord.com/api/webhooks/ ]]; then
                print_error "Invalid Discord webhook URL."
                log "Invalid Discord webhook URL provided."
                return 1
            fi
        else
            NOTIFICATION_SETUP="ntfy"
            read -rp "$(printf '%s' "${CYAN}Enter ntfy URL/topic (e.g., https://ntfy.sh/my-backups): ${NC}")" NTFY_URL
            read -rp "$(printf '%s' "${CYAN}Enter ntfy Access Token (optional): ${NC}")" NTFY_TOKEN
            if [[ ! "$NTFY_URL" =~ ^https?:// ]]; then
                print_error "Invalid ntfy URL."
                log "Invalid ntfy URL provided."
                return 1
            fi
        fi
    fi

    # --- Generate Backup Script ---
    print_info "Generating backup script at $BACKUP_SCRIPT_PATH..."
    if ! tee "$BACKUP_SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
# Generated by server setup script on $(date)
set -Euo pipefail; umask 077
# --- CONFIGURATION ---
BACKUP_DIRS="${BACKUP_DIRS_STRING}"
REMOTE_DEST="${BACKUP_DEST}"
REMOTE_PATH="${REMOTE_BACKUP_PATH}"
SSH_PORT="${BACKUP_PORT}"
EXCLUDE_FILE="${EXCLUDE_FILE_PATH}"
LOG_FILE="/var/log/backup_rsync.log"
LOCK_FILE="/tmp/backup_rsync.lock"
HOSTNAME="\$(hostname -f)"
NOTIFICATION_SETUP="${NOTIFICATION_SETUP}"
NTFY_URL="${NTFY_URL}"
NTFY_TOKEN="${NTFY_TOKEN}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK}"
EOF
    then
        print_error "Failed to create backup script at $BACKUP_SCRIPT_PATH."
        log "Failed to create backup script at $BACKUP_SCRIPT_PATH."
        return 1
    fi
    if ! tee -a "$BACKUP_SCRIPT_PATH" > /dev/null <<'EOF'
# --- BACKUP SCRIPT LOGIC ---
send_notification() {
    local status="\$1" message="\$2" title color
    if [[ "\$status" == "SUCCESS" ]]; then title="✅ Backup SUCCESS: \$HOSTNAME"; color=3066993; else title="❌ Backup FAILED: \$HOSTNAME"; color=15158332; fi
    if [[ "\$NOTIFICATION_SETUP" == "ntfy" ]]; then
        curl -s -H "Title: \$title" \${NTFY_TOKEN:+-H "Authorization: Bearer \$NTFY_TOKEN"} -d "\$message" "\$NTFY_URL" > /dev/null 2>&1
    elif [[ "\$NOTIFICATION_SETUP" == "discord" ]]; then
        local escaped_message=\$(echo "\$message" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g' | sed ':a;N;\$!ba;s/\n/\\n/g')
        local json_payload=\$(printf '{"embeds": [{"title": "%s", "description": "%s", "color": %d}]}' "\$title" "\$escaped_message" "\$color")
        curl -s -H "Content-Type: application/json" -d "\$json_payload" "\$DISCORD_WEBHOOK" > /dev/null 2>&1
    fi
}
# --- DEPENDENCY & LOCKING ---
for cmd in rsync flock numfmt awk; do if ! command -v "\$cmd" &>/dev/null; then send_notification "FAILURE" "FATAL: '\$cmd' not found."; exit 10; fi; done
exec 200>"\$LOCK_FILE"; flock -n 200 || { echo "Backup already running."; exit 1; }
# --- LOG ROTATION ---
touch "\$LOG_FILE"; chmod 600 "\$LOG_FILE"; if [[ -f "\$LOG_FILE" && \$(stat -c%s "\$LOG_FILE") -gt 10485760 ]]; then mv "\$LOG_FILE" "\${LOG_FILE}.1"; fi
echo "--- Starting Backup at \$(date) ---" >> "\$LOG_FILE"
# --- RSYNC COMMAND ---
rsync_output=\$(rsync -avz --delete --stats --exclude-from="\$EXCLUDE_FILE" -e "ssh -p \$SSH_PORT" \$BACKUP_DIRS "\${REMOTE_DEST}:\${REMOTE_PATH}" 2>&1)
rsync_exit_code=\$?; echo "\$rsync_output" >> "\$LOG_FILE"
# --- NOTIFICATION ---
if [[ \$rsync_exit_code -eq 0 ]]; then
    data_transferred=\$(echo "\$rsync_output" | grep 'Total transferred file size' | awk '{print \$5}' | sed 's/,//g')
    human_readable=\$(numfmt --to=iec-i --suffix=B --format="%.2f" "\$data_transferred" 2>/dev/null || echo "0 B")
    printf -v message "Backup completed successfully.\nData Transferred: %s" "\$human_readable"
    send_notification "SUCCESS" "\$message"
else
    message="rsync failed with exit code \${rsync_exit_code}. Check log for details."
    send_notification "FAILURE" "\$message"
fi
EOF
    then
        print_error "Failed to append to backup script at $BACKUP_SCRIPT_PATH."
        log "Failed to append to backup script at $BACKUP_SCRIPT_PATH."
        return 1
    fi
    if ! chmod 700 "$BACKUP_SCRIPT_PATH"; then
        print_error "Failed to set permissions on $BACKUP_SCRIPT_PATH."
        log "Failed to set permissions on $BACKUP_SCRIPT_PATH."
        return 1
    fi
    print_success "Backup script created."

    # --- Backup test ---
    test_backup

    # --- Configure Cron Job ---
    print_info "Configuring root cron job..."
    # Ensure crontab is writable
    local CRON_DIR="/var/spool/cron/crontabs"
    mkdir -p "$CRON_DIR"
    chmod 1730 "$CRON_DIR"
    chown root:crontab "$CRON_DIR"
    # Validate inputs
    if [[ -z "$CRON_SCHEDULE" || -z "$BACKUP_SCRIPT_PATH" ]]; then
        print_error "Cron schedule or backup script path is empty."
        log "Cron configuration failed: CRON_SCHEDULE='$CRON_SCHEDULE', BACKUP_SCRIPT_PATH='$BACKUP_SCRIPT_PATH'"
        return 1
    fi
    if [[ ! -f "$BACKUP_SCRIPT_PATH" ]]; then
        print_error "Backup script $BACKUP_SCRIPT_PATH does not exist."
        log "Cron configuration failed: Backup script $BACKUP_SCRIPT_PATH not found."
        return 1
    fi
    # Create temporary cron file
    local TEMP_CRON
    TEMP_CRON=$(mktemp)
    if ! crontab -u root -l 2>/dev/null | grep -v "$CRON_MARKER" > "$TEMP_CRON"; then
        print_warning "No existing crontab found or error reading crontab. Creating new one."
        : > "$TEMP_CRON" # Create empty file
    fi
    echo "$CRON_SCHEDULE $BACKUP_SCRIPT_PATH $CRON_MARKER" >> "$TEMP_CRON"
    if ! crontab -u root "$TEMP_CRON" 2>&1 | tee -a "$LOG_FILE"; then
        print_error "Failed to configure cron job."
        log "Cron configuration failed: Error updating crontab."
        rm -f "$TEMP_CRON"
        return 1
    fi
    rm -f "$TEMP_CRON"
    print_success "Backup cron job scheduled: $CRON_SCHEDULE"
    log "Backup configuration completed."
}
# --- Backup Test Function ---
test_backup() {
    print_section "Backup Configuration Test"

    # Ensure script is running with effective root privileges
    if [[ $(id -u) -ne 0 ]]; then
        print_error "Backup test must be run as root. Re-run with 'sudo -E' or as root."
        log "Backup test failed: Script not run as root (UID $(id -u))."
        return 0
    fi

    local BACKUP_SCRIPT_PATH="/root/run_backup.sh"
    if [[ ! -f "$BACKUP_SCRIPT_PATH" || ! -r "$BACKUP_SCRIPT_PATH" ]]; then
        print_error "Backup script not found or not readable at $BACKUP_SCRIPT_PATH."
        log "Backup test failed: Script not found or not readable."
        return 0
    fi

    if ! command -v timeout >/dev/null 2>&1; then
        print_error "The 'timeout' command is not available. Please install coreutils."
        log "Backup test failed: 'timeout' command not found."
        return 0
    fi

    if ! confirm "Run a test backup to verify configuration?"; then
        print_info "Skipping backup test."
        log "Backup test skipped by user."
        return 0
    fi

    # Extract backup configuration from generated backup script
    local BACKUP_DEST REMOTE_BACKUP_PATH BACKUP_PORT
    BACKUP_DEST=$(grep "^REMOTE_DEST=" "$BACKUP_SCRIPT_PATH" | cut -d'"' -f2 2>/dev/null || echo "unknown")
    BACKUP_PORT=$(grep "^SSH_PORT=" "$BACKUP_SCRIPT_PATH" | cut -d'"' -f2 2>/dev/null || echo "22")
    REMOTE_BACKUP_PATH=$(grep "^REMOTE_PATH=" "$BACKUP_SCRIPT_PATH" | cut -d'"' -f2 2>/dev/null || echo "unknown")
    local BACKUP_LOG="/var/log/backup_rsync.log"

    if [[ "$BACKUP_DEST" == "unknown" || "$REMOTE_BACKUP_PATH" == "unknown" ]]; then
        print_error "Could not parse backup configuration from $BACKUP_SCRIPT_PATH."
        log "Backup test failed: Invalid configuration in $BACKUP_SCRIPT_PATH."
        return 0
    fi

    # Create a temporary directory and file for test
    local TEST_DIR TEST_FILE
    TEST_DIR="/root/test_backup_$(date +%Y%m%d_%H%M%S)"
    TEST_FILE="$TEST_DIR/test_backup_verification_$(date +%s).txt"
    if ! mkdir -p "$TEST_DIR" || ! echo "Test file for backup verification - $(date)" > "$TEST_FILE"; then
        print_error "Failed to create test directory or file in /root/."
        log "Backup test failed: Cannot create test directory/file."
        rm -rf "$TEST_DIR" 2>/dev/null
        return 0
    fi

    print_info "Running test backup of single file to ${BACKUP_DEST}:${REMOTE_BACKUP_PATH}..."
    local RSYNC_OUTPUT RSYNC_EXIT_CODE TIMEOUT_DURATION=60
    local SSH_KEY="/root/.ssh/id_ed25519"
    local SSH_COMMAND="ssh -p $BACKUP_PORT -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no"

    set +e
    RSYNC_OUTPUT=$(timeout "$TIMEOUT_DURATION" rsync -avz -e "$SSH_COMMAND" "$TEST_FILE" "${BACKUP_DEST}:${REMOTE_BACKUP_PATH}" 2>&1)
    RSYNC_EXIT_CODE=$?
    set -e

    {
        echo "--- Test Backup at $(date) ---"
        echo "Command: rsync -avz -e \"$SSH_COMMAND\" \"$TEST_FILE\" \"${BACKUP_DEST}:${REMOTE_BACKUP_PATH}\""
        echo "Output:"
        echo "$RSYNC_OUTPUT"
        echo "Exit Code: $RSYNC_EXIT_CODE"
    } >> "$BACKUP_LOG"

    if [[ $RSYNC_EXIT_CODE -eq 0 ]]; then
        print_success "Test backup (single file) successful! Check $BACKUP_LOG for details."
        log "Test backup successful (single file)."
        ssh -p "$BACKUP_PORT" -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "$BACKUP_DEST" "rm -f '${REMOTE_BACKUP_PATH}$(basename "$TEST_FILE")'" > /dev/null 2>&1 || true
        log "Attempted cleanup of remote test file: ${REMOTE_BACKUP_PATH}$(basename "$TEST_FILE")"
    else
        print_warning "The backup test (single file transfer) failed. This is not critical, and script will continue."
        print_info "You can troubleshoot this after server setup is complete."

        if [[ $RSYNC_EXIT_CODE -eq 124 ]]; then
            print_error "Test backup timed out after $TIMEOUT_DURATION seconds."
            log "Test backup failed: Timeout after $TIMEOUT_DURATION seconds."
        else
            print_error "Test backup failed (exit code: $RSYNC_EXIT_CODE). See $BACKUP_LOG for details."
            log "Test backup failed with exit code $RSYNC_EXIT_CODE."
            # Hints based on common rsync errors
            case "$RSYNC_OUTPUT" in
                *"Permission denied"*)
                    print_info "Hint: Check SSH key authentication and permissions on remote path."
                    ;;
                *"Connection timed out"*|*"Connection refused"*|*"Network is unreachable"*)
                    print_info "Hint: Check network connectivity, firewall rules (local and remote), and SSH port."
                    ;;
                *"No such file or directory"*)
                    print_info "Hint: Verify remote path '${REMOTE_BACKUP_PATH}' is correct and accessible."
                    ;;
            esac
        fi
    fi

    print_info "Common troubleshooting steps:"
        print_info "  - Ensure root SSH key is copied: ssh-copy-id -p \"$BACKUP_PORT\" -i \"$SSH_KEY.pub\" $SSH_COPY_ID_FLAGS \"$BACKUP_DEST\""
        print_info "  - Manually test SSH connection: ssh -p \"$BACKUP_PORT\" -i \"$SSH_KEY\" \"$BACKUP_DEST\""
        print_info "  - Check permissions on the remote path: '${REMOTE_BACKUP_PATH}'"


    # Clean up local temporary test directory and file
    rm -rf "$TEST_DIR" 2>/dev/null
    print_info "Local test directory cleaned up."
    print_success "Backup test completed."
    log "Backup test completed."
    return 0
}
