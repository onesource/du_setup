#!/bin/bash

# ============================================================================
# du_setup_modular.sh - User Management Module
# Handles user creation, SSH key management, and custom .bashrc setup
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- User Management Function ---
setup_user() {
    print_section "User Management"
    local USER_HOME SSH_DIR AUTH_KEYS PASS1 PASS2 SSH_PUBLIC_KEY TEMP_KEY_FILE

    if [[ -z "$USERNAME" ]]; then
        print_error "USERNAME variable is not set. Cannot proceed with user setup."
        exit 1
    fi

    if [[ $USER_EXISTS == false ]]; then
        print_info "Creating user '$USERNAME'..."
        if ! adduser --disabled-password --gecos "" "$USERNAME"; then
            print_error "Failed to create user '$USERNAME'."
            exit 1
        fi
        if ! id "$USERNAME" &>/dev/null; then
            print_error "User '$USERNAME' creation verification failed."
            exit 1
        fi
        print_info "Set a password for '$USERNAME' (required for sudo, or press Enter twice to skip for key-only access):"
        while true; do
            read -rsp "$(printf '%s' "${CYAN}New password: ${NC}")" PASS1
            printf '\n'
            read -rsp "$(printf '%s' "${CYAN}Retype new password: ${NC}")" PASS2
            printf '\n'
            if [[ -z "$PASS1" && -z "$PASS2" ]]; then
                print_warning "Password skipped. Relying on SSH key authentication."
                log "Password setting skipped for '$USERNAME'."
                break
            elif [[ "$PASS1" == "$PASS2" ]]; then
                if echo "$USERNAME:$PASS1" | chpasswd >/dev/null 2>&1; then
                    print_success "Password for '$USERNAME' updated."
                    break
                else
                    print_error "Failed to set password. Possible causes:"
                    print_info "  • permissions issue or password policy restrictions."
                    print_info "  • VPS provider password requirements (min. 8-12 chars, complexity rules)"
                    printf '\n'
                    print_info "Try again or press Enter twice to skip."
                    log "Failed to set password for '$USERNAME'."
                fi
            else
                print_error "Passwords do not match. Please try again."
            fi
        done

        USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
        SSH_DIR="$USER_HOME/.ssh"
        AUTH_KEYS="$SSH_DIR/authorized_keys"

        # Check if home directory is writable
        if [[ ! -w "$USER_HOME" ]]; then
            print_error "Home directory $USER_HOME is not writable by $USERNAME."
            print_info "Attempting to fix permissions..."
            chown "$USERNAME:$USERNAME" "$USER_HOME"
            chmod 700 "$USER_HOME"
            if [[ ! -w "$USER_HOME" ]]; then
                print_error "Failed to make $USER_HOME writable. Check filesystem permissions."
                exit 1
            fi
            log "Fixed permissions for $USER_HOME."
        fi

        if confirm "Add SSH public key(s) from your local machine now?"; then
            while true; do
                local SSH_PUBLIC_KEY
                read -rp "$(printf '%s' "${CYAN}Paste your full SSH public key: ${NC}")" SSH_PUBLIC_KEY

                if validate_ssh_key "$SSH_PUBLIC_KEY"; then
                    mkdir -p "$SSH_DIR"
                    chmod 700 "$SSH_DIR"
                    chown "$USERNAME:$USERNAME" "$SSH_DIR"
                    echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
                    awk '!seen[$0]++' "$AUTH_KEYS" > "$AUTH_KEYS.tmp" && mv "$AUTH_KEYS.tmp" "$AUTH_KEYS"
                    chmod 600 "$AUTH_KEYS"
                    chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
                    print_success "SSH public key added."
                    log "Added SSH public key for '$USERNAME'."
                    LOCAL_KEY_ADDED=true
                else
                    print_error "Invalid SSH key format. It should start with 'ssh-rsa', 'ecdsa-*', or 'ssh-ed25519'."
                fi

                if ! confirm "Do you have another SSH public key to add?" "n"; then
                    print_info "Finished adding SSH keys."
                    break
                fi
            done
        else
            print_info "No local SSH key provided. Generating a new key pair for '$USERNAME'."
            log "User opted not to provide a local SSH key. Generating a new one."

            if ! command -v ssh-keygen >/dev/null 2>&1; then
                print_error "ssh-keygen not found. Please install openssh-client."
                exit 1
            fi
            if [[ ! -w /tmp ]]; then
                print_error "Cannot write to /tmp. Unable to create temporary key file."
                exit 1
            fi

            mkdir -p "$SSH_DIR"
            chmod 700 "$SSH_DIR"
            chown "$USERNAME:$USERNAME" "$SSH_DIR"

            # Generate user key pair for login
            if ! sudo -u "$USERNAME" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519_user" -N "" -q; then
                print_error "Failed to generate user SSH key for '$USERNAME'."
                exit 1
            fi
            cat "$SSH_DIR/id_ed25519_user.pub" >> "$AUTH_KEYS"
            # Verify key was added
            if [[ ! -s "$AUTH_KEYS" ]]; then
                print_error "Failed to create authorized_keys file."
                exit 1
            fi
            chmod 600 "$AUTH_KEYS"
            chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
            print_success "SSH key generated and added to authorized_keys."
            log "Generated and added user SSH key for '$USERNAME'."

            if ! sudo -u "$USERNAME" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519_server" -N "" -q; then
                print_error "Failed to generate server SSH key for '$USERNAME'."
                exit 1
            fi
            print_success "Server SSH key generated (not shared)."
            log "Generated server SSH key for '$USERNAME'."

            TEMP_KEY_FILE="/tmp/${USERNAME}_ssh_key_$(date +%s)"
            trap 'rm -f "$TEMP_KEY_FILE" 2>/dev/null' EXIT
            cp "$SSH_DIR/id_ed25519_user" "$TEMP_KEY_FILE"
            chmod 600 "$TEMP_KEY_FILE"
            chown root:root "$TEMP_KEY_FILE"

            printf '\n'
            printf '%s\n' "${YELLOW}⚠ SECURITY WARNING: The SSH key pair below is your only chance to access '$USERNAME' via SSH.${NC}"
            printf '%s\n' "${YELLOW}⚠ Anyone with the private key can access your server. Secure it immediately.${NC}"
            printf '\n'
            printf '%s\n' "${PURPLE}ℹ ACTION REQUIRED: Save keys to your local machine:${NC}"
            printf '%s\n' "${CYAN}1. Save PRIVATE key to ~/.ssh/${USERNAME}_key:${NC}"
            printf '%s\n' "${RED} vvvv PRIVATE KEY BELOW THIS LINE vvvv  ${NC}"
            cat "$TEMP_KEY_FILE"
            printf '%s\n' "${RED} ^^^^ PRIVATE KEY ABOVE THIS LINE ^^^^^ ${NC}"
            printf '\n'
            printf '%s\n' "${CYAN}2. Save PUBLIC key to verify or use elsewhere:${NC}"
            printf '====SSH PUBLIC KEY BELOW THIS LINE====\n'
            cat "$SSH_DIR/id_ed25519_user.pub"
            printf '====SSH PUBLIC KEY END====\n'
            printf '\n'
            printf '%s\n' "${CYAN}3. On your local machine, set permissions for the private key:${NC}"
            printf '%s\n' "${CYAN}   chmod 600 ~/.ssh/${USERNAME}_key${NC}"
            printf '\n'
            printf '%s\n' "${CYAN}4. Connect to the server using:${NC}"
            if [[ "$SERVER_IP_V4" != "unknown" ]]; then
                printf '%s\n' "${CYAN}   ssh -i ~/.ssh/${USERNAME}_key -p $SSH_PORT $USERNAME@$SERVER_IP_V4${NC}"
            fi
            if [[ "$SERVER_IP_V6" != "not available" ]]; then
                printf '%s\n' "${CYAN}   ssh -i ~/.ssh/${USERNAME}_key -p $SSH_PORT $USERNAME@$SERVER_IP_V6${NC}"
            fi
            printf '\n'
            printf '%s\n' "${PURPLE}ℹ The private key file ($TEMP_KEY_FILE) will be deleted after this step.${NC}"
            read -rp "$(printf '%s' "${CYAN}Press Enter after you have saved the keys securely...${NC}")"
            rm -f "$TEMP_KEY_FILE" 2>/dev/null
            trap - EXIT
            LOCAL_KEY_ADDED=true
        fi
        print_success "User '$USERNAME' created."
        echo "$USERNAME" > /root/.du_setup_managed_user
        chmod 600 /root/.du_setup_managed_user
        log "Marked '$USERNAME' as script-managed user (excluded from provider cleanup)."
    else
        print_info "Using existing user: $USERNAME"
        if [[ ! -f /root/.du_setup_managed_user ]]; then
            echo "$USERNAME" > /root/.du_setup_managed_user
            chmod 600 /root/.du_setup_managed_user
            log "Marked existing user '$USERNAME' as script-managed"
        fi
        USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
        SSH_DIR="$USER_HOME/.ssh"
        AUTH_KEYS="$SSH_DIR/authorized_keys"
        if [[ ! -s "$AUTH_KEYS" ]] || ! grep -qE '^(ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-ed25519) ' "$AUTH_KEYS" 2>/dev/null; then
            print_warning "No valid SSH keys found in $AUTH_KEYS for existing user '$USERNAME'."
            print_info "You must manually add a public key to $AUTH_KEYS to enable SSH access."
            log "No valid SSH keys found for existing user '$USERNAME'."
        fi
    fi

    # Add custom .bashrc
    configure_custom_bashrc "$USER_HOME" "$USERNAME"

    print_info "Adding '$USERNAME' to sudo group..."
    if ! groups "$USERNAME" | grep -qw sudo; then
        if ! usermod -aG sudo "$USERNAME"; then
            print_error "Failed to add '$USERNAME' to sudo group."
            exit 1
        fi
        print_success "User added to sudo group."
    else
        print_info "User '$USERNAME' is already in sudo group."
    fi

    if getent group sudo | grep -qw "$USERNAME"; then
        print_success "Sudo group membership confirmed for '$USERNAME'."
        state_set managed_admin "$USERNAME"
        printf '%s\n' "$USERNAME" > "$LEGACY_MANAGED_ADMIN_STATE"
        chmod 0600 "$LEGACY_MANAGED_ADMIN_STATE"
    else
        print_warning "Sudo group membership verification failed. Please check manually with 'sudo -l' as $USERNAME."
    fi
    log "User management completed."
}

# --- Custom .bashrc Configuration Function ---
configure_custom_bashrc() {
    local USER_HOME="$1"
    local USERNAME="$2"
    local BASHRC_PATH="$USER_HOME/.bashrc"
    local temp_source_bashrc=""
    local keep_temp_source_on_error=false

    trap 'rm -f "$temp_source_bashrc" 2>/dev/null' INT TERM

    if ! confirm "Replace default .bashrc for '$USERNAME' with a custom one?" "n"; then
        print_info "Skipping custom .bashrc configuration."
        log "Skipped custom .bashrc for $USERNAME."
        return 0
    fi

    print_info "Preparing custom .bashrc for '$USERNAME'..."

    temp_source_bashrc=$(mktemp "/tmp/custom_bashrc_source.XXXXXX")
    if [[ -z "$temp_source_bashrc" || ! -f "$temp_source_bashrc" ]]; then
        print_error "Failed to create temporary file for .bashrc content."
        log "Error: mktemp failed for bashrc source."
        return 0
    fi
    chmod 600 "$temp_source_bashrc"

    # Use external bashrc template file
    local BASHRC_TEMPLATE="$(dirname "${BASH_SOURCE[0]}")/../lib/bashrc_template.sh"
    if [[ ! -f "$BASHRC_TEMPLATE" ]]; then
        print_error "Bashrc template not found at $BASHRC_TEMPLATE"
        return 1
    fi

    if ! cp "$BASHRC_TEMPLATE" "$temp_source_bashrc"; then
        print_error "Failed to copy bashrc template to temporary file $temp_source_bashrc."
        log "Critical error: Failed to copy bashrc template to $temp_source_bashrc."
        return 0
    fi

    log "Successfully created temporary .bashrc source at $temp_source_bashrc"

    if [[ -f "$BASHRC_PATH" ]] && ! grep -q "generated by /usr/sbin/adduser" "$BASHRC_PATH" 2>/dev/null; then
	    local BASHRC_BACKUP
        BASHRC_BACKUP="$BASHRC_PATH.backup_$(date +%Y%m%d_%H%M%S)"
        print_info "Backing up existing non-default .bashrc to $BASHRC_BACKUP"
        cp "$BASHRC_PATH" "$BASHRC_BACKUP"
        log "Backed up existing .bashrc to $BASHRC_BACKUP"
    fi

    local temp_fallback_path="/tmp/custom_bashrc_for_${USERNAME}.txt"

    if ! tee "$BASHRC_PATH" < "$temp_source_bashrc" > /dev/null
    then
        print_error "Failed to automatically write custom .bashrc to $BASHRC_PATH."
        log "Error writing custom .bashrc for $USERNAME to $BASHRC_PATH."

        if cp "$temp_source_bashrc" "$temp_fallback_path"; then
            chmod 644 "$temp_fallback_path"
            print_warning "ACTION REQUIRED: The custom .bashrc content has been saved to:"
            print_warning "  ${temp_fallback_path}"
            print_info "After setup, please manually copy it:"
            print_info "  sudo cp ${temp_fallback_path} ${BASHRC_PATH}"
            print_info "  sudo chown ${USERNAME}:${USERNAME} ${BASHRC_PATH}"
            print_info "  sudo chmod 644 ${BASHRC_PATH}"
            print_info "  (Source content is in ${temp_source_bashrc})"
            log "Saved custom .bashrc content to $temp_fallback_path for manual installation."
            keep_temp_source_on_error=true
        else
            print_error "Also failed to save custom .bashrc content to fallback location."
            log "Failed to save custom .bashrc content to fallback location."
        fi
    else
        if ! chown "$USERNAME:$USERNAME" "$BASHRC_PATH" || ! chmod 644 "$BASHRC_PATH"; then
            print_warning "Failed to set correct ownership/permissions on $BASHRC_PATH."
            log "Failed to chown/chmod $BASHRC_PATH."
            print_info "ACTION REQUIRED: Please manually set ownership/permissions:"
            print_info "  sudo chown ${USERNAME}:${USERNAME} ${BASHRC_PATH}"
            print_info "  sudo chmod 644 ${BASHRC_PATH}"
            print_info "  (Source content is in ${temp_source_bashrc})"
            keep_temp_source_on_error=true
        else
            print_success "Custom .bashrc created for '$USERNAME'."
            log "Custom .bashrc configuration completed for $USERNAME."
            rm -f "$temp_fallback_path" 2>/dev/null
        fi
    fi

    if [[ "$keep_temp_source_on_error" == false ]]; then
        rm -f "$temp_source_bashrc" 2>/dev/null
    fi

    trap - INT TERM

    return 0
}