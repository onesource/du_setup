#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Backup Configuration Module
# Handles rsync backup configuration and setup
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Backup Configuration Function ---
setup_backup() {
    print_section "Backup Configuration (rsync over SSH)"

    local installed=false enabled=false desired
    [[ -f /root/run_backup.sh ]] && installed=true
    crontab -u root -l 2>/dev/null | grep -Fq "#-*- installed by du_setup script -*-" && enabled=true
    desired=$(prompt_component_desired backup "rsync backup" "$installed" "$enabled") || return 1
    state_set component.backup "$desired"
    if [[ "$desired" != "true" ]]; then
        print_info "The existing backup, if any, remains disabled and was not modified."
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

    # --- Reconcile Backup Destination ---
    local BACKUP_DEST BACKUP_PORT REMOTE_BACKUP_PATH SSH_COPY_ID_FLAGS=""
    BACKUP_DEST=$(prompt_value_current "Backup destination (user@host)" "$(state_get backup.destination '')" validate_backup_destination)
    BACKUP_PORT=$(prompt_value_current "Backup SSH port" "$(state_get backup.port 22)" validate_backup_port)
    REMOTE_BACKUP_PATH=$(prompt_value_current "Remote backup path" "$(state_get backup.remote_path /home/backups/)" validate_remote_backup_path)
    state_set backup.destination "$BACKUP_DEST"
    state_set backup.port "$BACKUP_PORT"
    state_set backup.remote_path "$REMOTE_BACKUP_PATH"

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
        local connection_ok=false
        if [[ -n "$SSH_COPY_ID_FLAGS" ]]; then
            printf 'quit\n' | sftp -P "$BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$BACKUP_DEST" >/dev/null 2>&1 && connection_ok=true
        else
            ssh -p "$BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$BACKUP_DEST" true 2>/dev/null && connection_ok=true
        fi
        if [[ "$connection_ok" == "true" ]]; then
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
    local BACKUP_DIRS_ARRAY=() current_sources
    current_sources=$(state_get backup.sources "/home/${USERNAME}/")
    while true; do
        print_info "Enter absolute directory paths separated by spaces."
        read -rp "$(printf '%s' "${CYAN}Backup sources [${current_sources}]: ${NC}")" -a user_input_dirs
        if [[ ${#user_input_dirs[@]} -eq 0 ]]; then
            read -r -a BACKUP_DIRS_ARRAY <<< "$current_sources"
        else
            BACKUP_DIRS_ARRAY=("${user_input_dirs[@]}")
        fi
        local all_valid=true dir
        for dir in "${BACKUP_DIRS_ARRAY[@]}"; do
            if [[ ! "$dir" =~ ^/ || "$dir" == *$'\n'* ]]; then
                print_error "Invalid path: '$dir'. Backup sources must be absolute paths without newlines."
                all_valid=false
                break
            fi
        done
        [[ "$all_valid" == "true" && ${#BACKUP_DIRS_ARRAY[@]} -gt 0 ]] && break
    done
    local BACKUP_DIRS_STRING="${BACKUP_DIRS_ARRAY[*]}" BACKUP_DIRS_DECL
    printf -v BACKUP_DIRS_DECL '%q ' "${BACKUP_DIRS_ARRAY[@]}"
    state_set backup.sources "$BACKUP_DIRS_STRING"
    print_info "Directories to be backed up: $BACKUP_DIRS_STRING"

    # --- Create Exclude File ---
    if [[ ! -f "$EXCLUDE_FILE_PATH" ]]; then
        print_info "Creating rsync exclude file at $EXCLUDE_FILE_PATH..."
        tee "$EXCLUDE_FILE_PATH" > /dev/null <<'EOF'
# MANAGED BY du_setup. Update choices through the reconciler; manual edits may be overwritten.
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
    elif ! head -n 1 "$EXCLUDE_FILE_PATH" | grep -Fq "MANAGED BY du_setup"; then
        local exclude_temp
        exclude_temp=$(mktemp)
        {
            printf '%s\n' '# MANAGED BY du_setup. Update choices through the reconciler; manual edits may be overwritten.'
            cat "$EXCLUDE_FILE_PATH"
        } > "$exclude_temp"
        install -m 0600 "$exclude_temp" "$EXCLUDE_FILE_PATH"
        rm -f "$exclude_temp"
    else
        print_info "Preserving the current managed rsync exclude list."
    fi
    local add_excludes
    add_excludes=$(prompt_bool_current "Add entries to the current backup exclude list?" false) || return 1
    if [[ "$add_excludes" == "true" ]]; then
        read -rp "$(printf '%s' "${CYAN}Enter items separated by spaces: ${NC}")" -a extra_excludes
        local item
        for item in "${extra_excludes[@]}"; do
            grep -Fxq -- "$item" "$EXCLUDE_FILE_PATH" || printf '%s\n' "$item" >> "$EXCLUDE_FILE_PATH"
        done
    fi
    chmod 600 "$EXCLUDE_FILE_PATH"

    # --- Collect Cron Schedule ---
    local CRON_SCHEDULE
    CRON_SCHEDULE=$(prompt_value_current "Backup cron schedule" "$(state_get backup.schedule '5 3 * * *')" validate_cron_schedule)
    state_set backup.schedule "$CRON_SCHEDULE"

    # --- Collect Notification Details ---
    local BACKUP_CREDENTIALS="$DU_SETUP_CREDENTIALS_DIR/backup.env"
    local current_notification notification_enabled change_notification=false
    local NOTIFICATION_SETUP="none" NTFY_URL="" NTFY_TOKEN="" DISCORD_WEBHOOK=""
    local preserve_credentials=false
    current_notification=$(state_get backup.notifications none)
    case "$current_notification" in ntfy|discord|none) ;; *) current_notification=none ;; esac
    [[ -f "$BACKUP_CREDENTIALS" ]] || current_notification=none

    local notification_current=false
    [[ "$current_notification" != "none" ]] && notification_current=true
    notification_enabled=$(prompt_bool_current "Enable backup status notifications?" "$notification_current") || return 1
    if [[ "$notification_enabled" == "true" ]]; then
        if [[ "$current_notification" != "none" ]]; then
            NOTIFICATION_SETUP="$current_notification"
            change_notification=$(prompt_bool_current "Change the existing $current_notification notification configuration?" false) || return 1
            if [[ "$change_notification" == "false" ]]; then
                preserve_credentials=true
            fi
        fi
        if [[ "$preserve_credentials" != "true" ]]; then
            local n_choice default_choice=1
            [[ "$current_notification" == "discord" ]] && default_choice=2
            printf '%s' "${CYAN}Select notification method: 1) ntfy.sh 2) Discord  [${default_choice}]: ${NC}"
            read -r n_choice
            n_choice=${n_choice:-$default_choice}
            if [[ "$n_choice" == "2" ]]; then
                NOTIFICATION_SETUP="discord"
                read -rp "$(printf '%s' "${CYAN}Enter Discord Webhook URL: ${NC}")" DISCORD_WEBHOOK
                if [[ ! "$DISCORD_WEBHOOK" =~ ^https://discord.com/api/webhooks/ ]]; then
                    print_error "Invalid Discord webhook URL."
                    return 1
                fi
            else
                NOTIFICATION_SETUP="ntfy"
                read -rp "$(printf '%s' "${CYAN}Enter ntfy URL/topic (e.g., https://ntfy.sh/my-backups): ${NC}")" NTFY_URL
                read -rsp "$(printf '%s' "${CYAN}Enter ntfy access token (optional): ${NC}")" NTFY_TOKEN
                printf '\n'
                if [[ ! "$NTFY_URL" =~ ^https:// ]]; then
                    print_error "The ntfy URL must use HTTPS."
                    return 1
                fi
            fi
        fi
    fi
    state_set backup.notifications "$NOTIFICATION_SETUP"

    # Store notification credentials separately from executable code. Reusing
    # the current configuration never rewrites the credential file.
    if [[ "$preserve_credentials" != "true" ]]; then
        {
            printf 'NTFY_URL=%q\n' "$NTFY_URL"
            printf 'NTFY_TOKEN=%q\n' "$NTFY_TOKEN"
            printf 'DISCORD_WEBHOOK=%q\n' "$DISCORD_WEBHOOK"
        } > "$BACKUP_CREDENTIALS"
        chmod 0600 "$BACKUP_CREDENTIALS"
    fi

    # --- Generate Backup Script ---
    print_info "Generating backup script at $BACKUP_SCRIPT_PATH..."
    if ! tee "$BACKUP_SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
# MANAGED BY du_setup. Manual edits may be overwritten on the next run.
# Generated on $(date)
set -Euo pipefail; umask 077
# --- CONFIGURATION ---
BACKUP_DIRS=(${BACKUP_DIRS_DECL})
REMOTE_DEST="${BACKUP_DEST}"
REMOTE_PATH="${REMOTE_BACKUP_PATH}"
SSH_PORT="${BACKUP_PORT}"
EXCLUDE_FILE="${EXCLUDE_FILE_PATH}"
LOG_FILE="/var/log/backup_rsync.log"
LOCK_FILE="/tmp/backup_rsync.lock"
HOSTNAME="\$(hostname -f)"
NOTIFICATION_SETUP="${NOTIFICATION_SETUP}"
# shellcheck source=/dev/null
source "/etc/du-setup/credentials/backup.env"
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
rsync_output=\$(rsync -avz --delete --stats --exclude-from="\$EXCLUDE_FILE" -e "ssh -p \$SSH_PORT -o StrictHostKeyChecking=accept-new" "\${BACKUP_DIRS[@]}" "\${REMOTE_DEST}:\${REMOTE_PATH}" 2>&1)
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
    local SSH_COMMAND="ssh -p $BACKUP_PORT -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

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
        ssh -p "$BACKUP_PORT" -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$BACKUP_DEST" "rm -f '${REMOTE_BACKUP_PATH}$(basename "$TEST_FILE")'" > /dev/null 2>&1 || true
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
