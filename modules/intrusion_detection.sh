#!/bin/bash
# ====================================================================
# du_setup_modular.sh - Intrusion Detection System Module
# - Wazuh manager (single-host)
# - Active response (IPv4 + IPv6)
# - Auditd (trimmed)
# - AIDE, rkhunter, chkrootkit
# - Anomaly detector, log analysis
# ====================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------
# Module / environment
# -----------------------
# Source helper functions (adjust path as needed)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# Trap only on errors (not normal exit)
trap 'print_error "Intrusion detection module failed on line $LINENO."; log "IDS module error on line $LINENO";' ERR
trap 'log "Intrusion detection module completed."' EXIT

# -----------------------
# Helpers
# -----------------------

# Send HUP to Wazuh daemons that support reload (safe)
wazuh_reload_hup() {
    # target common Wazuh daemon names
    for p in ossec-logcollector ossec-analysisd wazuh-modulesd; do
        pkill -HUP -f "$p" >/dev/null 2>&1 || true
    done
}

# Append a localfile entry to Wazuh custom include (robust)
add_localfile() {
    local entry="$1"
    local tmp_file="${2:-${LOCALFILE_INCLUDE}.new}"

    # Ensure temp file exists
    touch "$tmp_file"

    # Avoid duplicate entries in both the existing include and the new temp file
    if ! grep -Fxq "$entry" "$tmp_file" 2>/dev/null && ! grep -Fxq "$entry" "${LOCALFILE_INCLUDE}" 2>/dev/null; then
        echo "$entry" >> "$tmp_file"
    fi
}

# -----------------------
# Ensure mailutils for cron mails (non-interactive)
# -----------------------
install_mailutils_noninteractive() {
    # NOTE: Installing mailutils will pull in a MTA (postfix/exim). This script installs mailutils only.
    # For SES, configure postfix or an SMTP relay afterwards (SES credentials/relayhost) - outside this script.
    if ! is_installed mailutils; then
        print_info "Installing mailutils (non-interactive). Configure your MTA for SES after install."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mailutils || true
    else
        print_info "mailutils already installed."
    fi
}

# -----------------------
# Wazuh Manager
# -----------------------
configure_wazuh() {
    print_section "Wazuh HIDS (manager-only) Configuration"

    local installed=false enabled=false desired WAZUH_BACKUP=""
    is_installed wazuh-manager && installed=true
    systemctl is-enabled --quiet wazuh-manager 2>/dev/null && systemctl is-active --quiet wazuh-manager && enabled=true
    desired=$(prompt_component_desired wazuh "Wazuh manager-only" "$installed" "$enabled") || return 1
    state_set component.wazuh "$desired"
    if [[ "$desired" != "true" ]]; then
        print_info "Wazuh manager will remain uninstalled or disabled."
        return 0
    fi
    if [[ -f "$WAZUH_CONF" ]]; then
        WAZUH_BACKUP=$(mktemp)
        cp -a "$WAZUH_CONF" "$WAZUH_BACKUP"
    fi

    # Ensure apt deps for repo
    print_info "Ensuring APT transport and GPG tools..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg lsb-release nftables

    # Add Wazuh APT repo & key (idempotent)
    if [ ! -f /usr/share/keyrings/wazuh.gpg ] || [ ! -f /etc/apt/sources.list.d/wazuh.list ]; then
        print_info "Installing Wazuh repository key and apt source..."
        # Use gpg --dearmor to create a proper keyring for apt (more portable)
        curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor --yes -o /usr/share/keyrings/wazuh.gpg
        chmod 644 /usr/share/keyrings/wazuh.gpg || true
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
            > /etc/apt/sources.list.d/wazuh.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
    fi

    # Install manager (manager-only; do not install agent)
    if ! is_installed wazuh-manager; then
        print_info "Installing wazuh-manager..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wazuh-manager
        systemctl daemon-reload
        systemctl enable --now wazuh-manager

        # Ensure the 'ossec' group is recognizable (refresh cache)
        if ! getent group ossec >/dev/null 2>&1; then
            print_info "Refreshing group cache for 'ossec'..."
            if command -v nscd >/dev/null 2>&1; then nscd -i group || true; fi
            sleep 1
        fi

        # Ensure it is running
        if ! systemctl is-active --quiet wazuh-manager; then
            systemctl start wazuh-manager
        fi
    else
        print_info "wazuh-manager already installed."
    fi

    # A new package install creates the vendor configuration after our first
    # backup opportunity. Capture it before applying du_setup customizations.
    if [[ -z "$WAZUH_BACKUP" && -f "$WAZUH_CONF" ]]; then
        WAZUH_BACKUP=$(mktemp)
        cp -a "$WAZUH_CONF" "$WAZUH_BACKUP"
    fi

    # Dynamic Wazuh group detection (robust against name resolution issues)
    local WAZUH_GROUP="ossec"
    if [ -d "/var/ossec" ]; then
        # Prefer numeric GID if name resolution is flaky
        WAZUH_GROUP=$(stat -c '%g' /var/ossec 2>/dev/null || echo "ossec")
        if [[ "$WAZUH_GROUP" =~ ^[0-9]+$ ]]; then
            log "Using Wazuh GID: ${WAZUH_GROUP}"
        else
            log "Using Wazuh group name: ${WAZUH_GROUP}"
        fi
    fi

    # Create include directories (keeps custom config isolated from upstream)
    ensure_dir_owned "${LOCAL_INCLUDE_DIR}"
    ensure_dir_owned "${RULES_INCLUDE_DIR}"

    # --- Create or update localfile include (only add entries for logs that exist) ---
    print_info "Writing Wazuh localfile include (idempotent)..."
    mkdir -p "$(dirname "${LOCALFILE_INCLUDE}")"
    LOCALFILE_TMP=$(mktemp)
    # Build content conditionally into temp file
    {
        echo '<localfile>'
        echo '  <log_format>syslog</log_format>'
        echo '  <location>/var/log/auth.log</location>'
        echo '</localfile>'
        # include rotated auth if present (some systems have .1)
        if [ -f /var/log/auth.log.1 ]; then
            echo '<localfile>'
            echo '  <log_format>syslog</log_format>'
            echo '  <location>/var/log/auth.log.1</location>'
            echo '</localfile>'
        fi
        # auditd log
        if [ -f /var/log/audit/audit.log ]; then
            echo '<localfile>'
            echo '  <log_format>audit</log_format>'
            echo '  <location>/var/log/audit/audit.log</location>'
            echo '</localfile>'
        fi
        # syslog
        if [ -f /var/log/syslog ]; then
            echo '<localfile>'
            echo '  <log_format>syslog</log_format>'
            echo '  <location>/var/log/syslog</location>'
            echo '</localfile>'
        fi
        # apache (only if dir or access.log exist)
        if [ -d /var/log/apache2 ] || [ -f /var/log/apache2/access.log ]; then
            echo '<localfile>'
            echo '  <log_format>apache</log_format>'
            echo '  <location>/var/log/apache2/access.log</location>'
            echo '</localfile>'
            echo '<localfile>'
            echo '  <log_format>apache</log_format>'
            echo '  <location>/var/log/apache2/error.log</location>'
            echo '</localfile>'
        fi
        # nginx
        if [ -d /var/log/nginx ] || [ -f /var/log/nginx/access.log ]; then
            echo '<localfile>'
            echo '  <log_format>syslog</log_format>'
            echo '  <location>/var/log/nginx/access.log</location>'
            echo '</localfile>'
            echo '<localfile>'
            echo '  <log_format>syslog</log_format>'
            echo '  <location>/var/log/nginx/error.log</location>'
            echo '</localfile>'
        fi
    } > "${LOCALFILE_TMP}"

    # Append Docker container log files (if docker present) to the new include in a safe way
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.ID}} {{.Names}}' | grep -E 'nginx|apache|httpd' | while read -r id _name; do
            LOG="/var/lib/docker/containers/${id}/${id}-json.log"
            if [ -f "$LOG" ]; then
                entry=$(cat <<-XML
<localfile>
  <log_format>json</log_format>
  <location>${LOG}</location>
</localfile>
XML
)
                add_localfile "$entry" "${LOCALFILE_TMP}"
            fi
        done
    fi

    # Replace only when content differs
    if [ ! -f "${LOCALFILE_INCLUDE}" ] || ! cmp -s "${LOCALFILE_TMP}" "${LOCALFILE_INCLUDE}"; then
        mv "${LOCALFILE_TMP}" "${LOCALFILE_INCLUDE}"
        print_info "Updated ${LOCALFILE_INCLUDE}"
    else
        rm -f "${LOCALFILE_TMP}"
        print_info "No change to ${LOCALFILE_INCLUDE} content."
    fi

    # Always ensure correct permissions/ownership (idempotent)
    getent group ossec >/dev/null 2>&1 || true
    chown "root:${WAZUH_GROUP}" "${LOCALFILE_INCLUDE}" || print_error "Failed to set ownership for ${LOCALFILE_INCLUDE}"
    chmod 640 "${LOCALFILE_INCLUDE}"

    # --- Syscheck include (realtime selective) ---
    print_info "Writing Wazuh syscheck include (idempotent)..."
    mkdir -p "$(dirname "${SYSCHECK_INCLUDE}")"
    SYSCHECK_TMP=$(mktemp)
    cat > "${SYSCHECK_TMP}" <<'EOF'
<syscheck>
  <frequency>7200</frequency>
  <scan_on_start>yes</scan_on_start>
  <!-- Monitor key paths, avoid noisy coverage like entire /usr during upgrades -->
  <directories check_all="yes" realtime="yes">/etc,/usr/bin,/usr/sbin</directories>
  <directories check_all="yes" realtime="no">/bin,/sbin,/boot</directories>
  <directories check_all="yes">/root,/home</directories>
  <ignore>/etc/mtab</ignore>
  <ignore>/var/run/fail2ban/fail2ban.sock</ignore>
</syscheck>

  <rootcheck>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>

  <alerts>
    <log_alert_level>1</log_alert_level>
    <email_alert_level>7</email_alert_level>
  </alerts>

  <command>
    <name>firewall-drop</name>
    <executable>firewall-drop.sh</executable>
    <expect>srcip</expect>
    <timeout_allowed>yes</timeout_allowed>
  </command>

  <active-response>
    <command>firewall-drop</command>
    <location>local</location>
    <level>6</level>
    <timeout>300</timeout>
  </active-response>
EOF

    if [ ! -f "${SYSCHECK_INCLUDE}" ] || ! cmp -s "${SYSCHECK_TMP}" "${SYSCHECK_INCLUDE}"; then
        mv "${SYSCHECK_TMP}" "${SYSCHECK_INCLUDE}"
        print_info "Updated ${SYSCHECK_INCLUDE}"
    else
        rm -f "${SYSCHECK_TMP}"
        print_info "No change to ${SYSCHECK_INCLUDE} content."
    fi

    getent group ossec >/dev/null 2>&1 || true
    chown "root:${WAZUH_GROUP}" "${SYSCHECK_INCLUDE}" || print_error "Failed to set ownership for ${SYSCHECK_INCLUDE}"
    chmod 640 "${SYSCHECK_INCLUDE}"

    # --- Local rules include (idempotent) ---
    print_info "Writing Wazuh local rules include (idempotent)..."
    mkdir -p "$(dirname "${LOCAL_RULES_FILE}")"
    LOCAL_RULES_TMP=$(mktemp)
    cat > "${LOCAL_RULES_TMP}" <<'EOF'
<group name="local,syslog,">
  <!-- Group rule for SSH failure baseline -->
  <rule id="110000" level="0">
    <if_sid>5710,5716</if_sid>
    <description>Base rule for SSH authentication failures.</description>
  </rule>
  <!-- Detect multiple SSH failed attempts using the base rule -->
  <rule id="110001" level="10" frequency="6" timeframe="120">
    <if_matched_sid>110000</if_matched_sid>
    <same_source_ip />
    <description>Multiple SSH failed attempts from same source IP.</description>
    <group>authentication_failures,ssh</group>
  </rule>
  <!-- Detect sudo usage -->
  <rule id="110002" level="8">
    <if_sid>5400</if_sid>
    <match>sudo:</match>
    <regex>USER=root ; COMMAND=</regex>
    <description>Sudo command executed as root.</description>
    <group>privilege_escalation,sudo</group>
  </rule>
  <!-- Detect new user creation -->
  <rule id="110003" level="7">
    <if_sid>5902</if_sid>
    <match>useradd</match>
    <description>New user account created.</description>
    <group>adduser,account_change</group>
  </rule>
  <!-- Detect cron modifications -->
  <rule id="110004" level="8">
    <if_sid>5400</if_sid>
    <match>crontab</match>
    <regex>EDIT|REPLACE|DELETE</regex>
    <description>Crontab file modified.</description>
    <group>config_change,cron</group>
  </rule>
  <!-- Detect package installs -->
  <rule id="110005" level="7">
    <if_sid>5400</if_sid>
    <match>dpkg|apt-get|apt</match>
    <regex>install</regex>
    <description>Package installation detected.</description>
    <group>package_install,software_mgmt</group>
  </rule>
  <!-- Detect network interface changes -->
  <rule id="110006" level="8">
    <if_sid>5400</if_sid>
    <match>ip link|ifconfig</match>
    <regex>up|down</regex>
    <description>Network interface state changed.</description>
    <group>network_change</group>
  </rule>
  <!-- Detect file integrity changes -->
  <rule id="110007" level="12">
    <if_sid>550</if_sid>
    <description>Integrity checksum changed.</description>
    <group>ossec,syscheck</group>
  </rule>
</group>
EOF

    if [ ! -f "${LOCAL_RULES_FILE}" ] || ! cmp -s "${LOCAL_RULES_TMP}" "${LOCAL_RULES_FILE}"; then
        mv "${LOCAL_RULES_TMP}" "${LOCAL_RULES_FILE}"
        print_info "Updated ${LOCAL_RULES_FILE}"
    else
        rm -f "${LOCAL_RULES_TMP}"
        print_info "No change to ${LOCAL_RULES_FILE} content."
    fi

    getent group ossec >/dev/null 2>&1 || true
    chown "root:${WAZUH_GROUP}" "${LOCAL_RULES_FILE}" || print_error "Failed to set ownership for ${LOCAL_RULES_FILE}"
    chmod 640 "${LOCAL_RULES_FILE}"

    # --- Ensure ossec.conf is clean and references our custom settings (Robust) ---
    print_info "Ensuring ossec.conf references our custom settings..."

    # 1. Cleanup ALL old/fragile injection attempts (including historical ones)
    sed -i '/<include file="local\/localfile_custom.conf"/d' "${WAZUH_CONF}" 2>/dev/null || true
    sed -i '/<include file="local\/syscheck_custom.conf"/d' "${WAZUH_CONF}" 2>/dev/null || true
    sed -i '/<include>rules\/local_rules_custom.xml/d' "${WAZUH_CONF}" 2>/dev/null || true
    # Remove our marked block if it exists (idempotency)
    sed -i '/<!-- DU_SETUP_CUSTOM_START -->/,/<!-- DU_SETUP_CUSTOM_END -->/d' "${WAZUH_CONF}"

    # 2. Add our custom configuration block as a separate, STANDALONE <ossec_config>
    # Read the actual content of the custom files
    LOCALFILE_CONTENT=""
    [ -f "${LOCALFILE_INCLUDE}" ] && LOCALFILE_CONTENT=$(cat "${LOCALFILE_INCLUDE}")
    SYSCHECK_CONTENT=""
    [ -f "${SYSCHECK_INCLUDE}" ] && SYSCHECK_CONTENT=$(cat "${SYSCHECK_INCLUDE}")

    # Prepare the custom block
    {
        echo "  <!-- DU_SETUP_CUSTOM_START -->"
        echo "  <ossec_config>"
        [ -n "$LOCALFILE_CONTENT" ] && echo "$LOCALFILE_CONTENT" | sed '/<?xml/d' | sed 's/^[[:space:]]*//'
        [ -n "$SYSCHECK_CONTENT" ] && echo "$SYSCHECK_CONTENT" | sed '/<?xml/d' | sed 's/^[[:space:]]*//'
        echo "  </ossec_config>"
        echo "  <!-- DU_SETUP_CUSTOM_END -->"
    } > "${LOCAL_INCLUDE_DIR}/combined_custom.tmp"

    # Append to the very end of ossec.conf. A separate <ossec_config> block is legal and avoids nesting.
    # We add a newline first to be safe.
    echo "" >> "${WAZUH_CONF}"
    cat "${LOCAL_INCLUDE_DIR}/combined_custom.tmp" >> "${WAZUH_CONF}"
    rm -f "${LOCAL_INCLUDE_DIR}/combined_custom.tmp"

    # 4. Validate configuration before reloading
    print_info "Validating Wazuh configuration..."
    if /var/ossec/bin/wazuh-analysisd -t >/dev/null 2>&1; then
        print_success "Wazuh configuration validated."
        wazuh_reload_hup
    else
        print_error "Wazuh configuration validation failed! Checking for redundant ossec_config blocks..."
        # Sometimes multiple ossec_config tags are added; attempt one more cleanup
        # This is a safety valve for previous failed runs
        sed -i 'N;/<\/ossec_config>\n<ossec_config>/d' "${WAZUH_CONF}" 2>/dev/null || true
        if /var/ossec/bin/wazuh-analysisd -t >/dev/null 2>&1; then
            print_success "Wazuh configuration fixed and validated."
        else
            print_error "Wazuh configuration remains invalid; restoring the complete pre-change configuration."
            log "Wazuh config validation failed; rollback initiated."
            if [[ -n "$WAZUH_BACKUP" && -f "$WAZUH_BACKUP" ]]; then
                cp -a "$WAZUH_BACKUP" "$WAZUH_CONF"
            fi
            rm -f "$WAZUH_BACKUP"
            return 1
        fi
    fi

    rm -f "$WAZUH_BACKUP"
    if ! systemctl restart wazuh-manager; then
        print_error "Failed to restart wazuh-manager. Check journalctl -xeu wazuh-manager."
        return 1
    fi

    # -------------------------------
    # Active-response: firewall-drop (IPv4 + IPv6 equal priority)
    # -------------------------------
    if [ ! -f "${ACTIVE_RESPONSE_SCRIPT}" ]; then
        print_info "Installing active-response firewall script (IPv4 + IPv6)..."
        mkdir -p "${ACTIVE_RESPONSE_DIR}"
        cat > "${ACTIVE_RESPONSE_SCRIPT}" <<'EOF'
#!/bin/bash
ACTION="$1"
IP="$3"

# Require nftables; if missing, log and exit (do not fail Wazuh action)
if ! command -v nft >/dev/null 2>&1; then
    logger -t wazuh "nft command not found; active-response no-op for $IP"
    exit 0
fi

# Setup nftables v4 and v6 if missing (idempotent)
nft list table ip ossec_filter >/dev/null 2>&1 || nft add table ip ossec_filter
nft list chain ip ossec_filter input >/dev/null 2>&1 || nft add chain ip ossec_filter input '{ type filter hook input priority 0; policy accept; }'
nft list set ip ossec_filter blocked_ips >/dev/null 2>&1 || nft add set ip ossec_filter blocked_ips '{ type ipv4_addr; }'
if ! nft list chain ip ossec_filter input 2>/dev/null | grep -q 'ip saddr @blocked_ips drop'; then
    nft add rule ip ossec_filter input ip saddr @blocked_ips drop 2>/dev/null || true
fi

nft list table ip6 ossec_filter >/dev/null 2>&1 || nft add table ip6 ossec_filter
nft list chain ip6 ossec_filter input >/dev/null 2>&1 || nft add chain ip6 ossec_filter input '{ type filter hook input priority 0; policy accept; }'
nft list set ip6 ossec_filter blocked_ips6 >/dev/null 2>&1 || nft add set ip6 ossec_filter blocked_ips6 '{ type ipv6_addr; }'
if ! nft list chain ip6 ossec_filter input 2>/dev/null | grep -q 'ip6 saddr @blocked_ips6 drop'; then
    nft add rule ip6 ossec_filter input ip6 saddr @blocked_ips6 drop 2>/dev/null || true
fi

# Add/delete element depending on IP family
if [[ "$IP" == *:* ]]; then
    # IPv6
    if [ "$ACTION" = "add" ]; then
        nft add element ip6 ossec_filter blocked_ips6 { "$IP" } 2>/dev/null || true
        logger -t wazuh "Blocked IPv6: $IP"
    elif [ "$ACTION" = "delete" ]; then
        nft delete element ip6 ossec_filter blocked_ips6 { "$IP" } 2>/dev/null || true
    fi
else
    # IPv4
    if [ "$ACTION" = "add" ]; then
        nft add element ip ossec_filter blocked_ips { "$IP" } 2>/dev/null || true
        logger -t wazuh "Blocked IPv4: $IP"
    elif [ "$ACTION" = "delete" ]; then
        nft delete element ip ossec_filter blocked_ips { "$IP" } 2>/dev/null || true
    fi
fi
EOF
        chmod 750 "${ACTIVE_RESPONSE_SCRIPT}"
        getent group ossec >/dev/null 2>&1 || true
        chown "root:${WAZUH_GROUP}" "${ACTIVE_RESPONSE_SCRIPT}" || print_error "Failed to set ownership for ${ACTIVE_RESPONSE_SCRIPT}"
        print_info "Active-response script installed."
    else
        print_info "Active-response script already present."
    fi

    # Tell Wazuh to reload active-response (HUP)
    wazuh_reload_hup

    print_success "Wazuh manager configured (manager-only)."
    log "Wazuh manager configuration completed."
}

# -----------------------
# AIDE (FIM)
# -----------------------
configure_aide() {
    print_section "AIDE (file integrity monitoring)"

    if ! confirm "Install and configure AIDE for FIM?"; then
        print_info "Skipping AIDE."
        return 0
    fi

    # Install AIDE if missing
    if ! is_installed aide; then
        print_info "Installing AIDE..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aide aide-common || {
            print_error "Failed to install AIDE"
            return 1
        }
    fi

# --- Secure database directory ---
    ensure_dir_owned /var/lib/aide
    chown root:root /var/lib/aide
    chmod 700 /var/lib/aide

    # Initialize DB if missing - check for common database files
    if [ ! -f /var/lib/aide/aide.db ] && [ ! -f /var/lib/aide/aide.db.new ]; then
        print_info "Initializing AIDE database..."
        # Try aideinit first, fall back to manual init
        if command -v aideinit >/dev/null 2>&1 && aideinit --yes; then
            print_info "AIDE database initialized via aideinit"
        else
            print_info "Using manual AIDE database initialization..."
            aide -i || {
                print_error "Manual AIDE database initialization failed"
                return 1
            }
            # Move the newly created database
            if [ -f /var/lib/aide/aide.db.new ]; then
                mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db || { print_error "Failed to move AIDE database"; return 1; }
            fi
        fi
        print_warning "IMPORTANT: The AIDE database at /var/lib/aide/aide.db is a critical security asset."
        print_warning "You should immediately back it up to secure, read-only, and offline storage."
    else
        print_info "AIDE database already exists."
    fi

    # Provide daily check script (cron.daily as a script, not a crontab entry)
    if [ ! -f /etc/cron.daily/aide ]; then
        print_info "Creating daily AIDE check script with email notifications..."
        cat > /etc/cron.daily/aide <<'EOF'
#!/bin/sh
# Set the email address to receive alerts.
# This should be a verified email in your AWS SES account.
    # Allow ADMIN_EMAIL to be supplied via environment; default empty
    ADMIN_EMAIL="${ADMIN_EMAIL:-}"

    # Determine aide binary at runtime
    AIDE_BIN="$(command -v aide || echo /usr/bin/aide)"
    # Run AIDE check and capture all output (stdout and stderr)
    AIDE_OUTPUT="$($AIDE_BIN --check 2>&1)"
HOST=$(hostname)

# AIDE returns >0 on changes
if echo "$AIDE_OUTPUT" | grep -Eiq "changed|added|removed|violation|difference"; then
    [ -n "$ADMIN_EMAIL" ] && echo "$AIDE_OUTPUT" | mail -s "AIDE Alert on $HOST" "$ADMIN_EMAIL"
    echo "$AIDE_OUTPUT" | logger -t aide -p user.err
else
    echo "$AIDE_OUTPUT" | logger -t aide -p user.info
fi

exit 0
EOF
        chmod 700 /etc/cron.daily/aide
    fi

    print_success "AIDE configured with email notifications via Postfix/SES."
    log "AIDE configuration completed."
}

# -----------------------
# Rootkit detection (rkhunter / chkrootkit)
# -----------------------
configure_rootkit_detection() {
    print_section "Rootkit detection"

    if ! confirm "Install chkrootkit and rkhunter?"; then
        print_info "Skipping rootkit detection."
        return 0
    fi

    # Install packages if missing
    local pkgs=(chkrootkit rkhunter)
    local to_install=()
    for p in "${pkgs[@]}"; do
        is_installed "$p" || to_install+=("$p")
    done
    if (( ${#to_install[@]} )); then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
    fi

    # rkhunter local config (append only if missing)
    if [ ! -f /etc/rkhunter.conf.local ]; then
        cat > /etc/rkhunter.conf.local <<'EOF'
ALLOW_SSH_ROOT_USER=no
ALLOW_SYSLOG_REMOTE_LOGGING=no
# Keep most tests enabled; whitelist some noisy scripts
# The baseline should be updated with 'rkhunter --propupd' after system updates.
SCRIPTWHITELIST=/usr/bin/ldd
SCRIPTWHITELIST=/usr/bin/whatis
SCRIPTWHITELIST=/usr/bin/ldconfig
SCRIPTWHITELIST=/usr/sbin/adduser
SCRIPTWHITELIST=/usr/sbin/useradd
SCRIPTWHITELIST=/usr/sbin/groupadd
SCRIPTWHITELIST=/usr/sbin/newusers
SCRIPTWHITELIST=/usr/sbin/userdel
SCRIPTWHITELIST=/usr/sbin/groupdel
SCRIPTWHITELIST=/usr/sbin/usermod
SCRIPTWHITELIST=/usr/sbin/groupmod
SCRIPTWHITELIST=/usr/sbin/pwconv
SCRIPTWHITELIST=/usr/sbin/grpconv
EOF
    fi

    # Update properties & initial check
    rkhunter --propupd || true
    rkhunter --update || true
    # Run initial check
    rkhunter --check --rwo --sk 2>&1 | logger -t rkhunter || true

    # chkrootkit weekly
    if [ ! -f /etc/cron.weekly/chkrootkit ]; then
        cat > /etc/cron.weekly/chkrootkit <<'EOF'
#!/bin/sh
/usr/sbin/chkrootkit 2>&1 | logger -t chkrootkit
EOF
        chmod +x /etc/cron.weekly/chkrootkit
    fi

    print_success "Rootkit detection configured."
    log "Rootkit detection configuration completed."
}

# -----------------------
# Log correlation and analyzer
# -----------------------
configure_log_correlation() {
    print_section "Log correlation & analysis"

    if ! confirm "Configure log rotation and security log analyzer?"; then
        print_info "Skipping log correlation."
        return 0
    fi

    # Only rotate system logs (not Wazuh-managed logs)
    if [ ! -f /etc/logrotate.d/security-logs ]; then
        cat > /etc/logrotate.d/security-logs <<'EOF'
/var/log/auth.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}

/var/log/audit/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        /usr/sbin/service auditd rotate >/dev/null 2>&1 || true
    endscript
}
EOF
        chmod 644 /etc/logrotate.d/security-logs
    fi

    # security-analysis log
    cat > /etc/logrotate.d/security-analysis <<'EOF'
/var/log/security-analysis.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
}
EOF
    chmod 644 /etc/logrotate.d/security-analysis

    # Analyzer script (reads Wazuh alerts file if present)
    cat > /usr/local/bin/security-log-analyzer.sh <<'EOF'
#!/bin/bash
LOG_FILE="/var/log/security-analysis.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"; }

# SSH failed logins
ssh_failures=\$(grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo 0)
[ "\$ssh_failures" -gt ${SSH_FAILURE_THRESHOLD} ] && log "ALERT: \$ssh_failures SSH failed login attempts"

# Sudo commands
sudo_count=\$(grep -c "sudo:.*COMMAND" /var/log/auth.log 2>/dev/null || echo 0)
[ "\$sudo_count" -gt ${SUDO_COUNT_THRESHOLD} ] && log "INFO: \$sudo_count sudo commands executed"

# Wazuh high-priority alerts (if file exists)
if [ -f "${WAZUH_ALERTS_LOG}" ]; then
    # Count blocks containing 'level [7-9]' roughly; keep simple and robust
    high_alerts=\$(grep -E "level [7-9]" "${WAZUH_ALERTS_LOG}" 2>/dev/null | wc -l || echo 0)
    [ "\$high_alerts" -gt 0 ] && log "ALERT: \$high_alerts high-priority Wazuh alerts"
fi
EOF
    chmod +x /usr/local/bin/security-log-analyzer.sh
    # Restrict analyzer script ownership and permissions
    chown root:root /usr/local/bin/security-log-analyzer.sh || true
    chmod 750 /usr/local/bin/security-log-analyzer.sh || true
    cp /usr/local/bin/security-log-analyzer.sh /etc/cron.hourly/security-log-analyzer 2>/dev/null || true
    chown root:root /etc/cron.hourly/security-log-analyzer 2>/dev/null || true
    chmod 750 /etc/cron.hourly/security-log-analyzer 2>/dev/null || true

    print_success "Log correlation configured."
    log "Log correlation completed."
}

# -----------------------
# Behavioral anomaly detection
# -----------------------
configure_anomaly_detection() {
    print_section "Behavioral anomaly detection"

    if ! confirm "Install basic anomaly detection (cpu/mem/connections/processes/disk)?"; then
        print_info "Skipping anomaly detection."
        return 0
    fi

    # ensure dependencies
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bc procps curl

    cat > /usr/local/bin/anomaly-detector.sh <<'EOF'
#!/bin/bash
ALERT_LOG="/var/log/anomaly-detections.log"
send_alert(){ echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ANOMALY: \$1" >> "\$ALERT_LOG"; }

cpu=\$(top -bn1 | awk -F'id,' '/Cpu/ { split($1,a,","); sub("%Cpu(s):","",a[1]); print 100 - a[1] }' | awk '{printf "%.1f", $0}')
if (( \$(echo "\$cpu > ${CPU_THRESHOLD}" | bc -l) )); then send_alert "High CPU: \${cpu}%"; fi

mem=\$(free | awk '/Mem:/ {printf "%.0f", \$3/\$2 * 100}')
[ "\$mem" -gt ${MEM_THRESHOLD} ] && send_alert "High memory: \${mem}%"

conn=\$(ss -tn | tail -n +2 | wc -l)
[ "\$conn" -gt ${CONN_THRESHOLD} ] && send_alert "High connections: \$conn"

proc=\$(ps -e | wc -l)
[ "\$proc" -gt ${PROC_THRESHOLD} ] && send_alert "High process count: \$proc"

disk=\$(df -P / | awk 'NR==2 {gsub("%",""); print \$5}')
[ "\$disk" -gt ${DISK_THRESHOLD} ] && send_alert "High disk usage: \${disk}% on /"
EOF
    chmod +x /usr/local/bin/anomaly-detector.sh

    # Cron job
    cat >/etc/cron.d/anomaly-detector <<'EOF'
*/15 * * * * root /usr/local/bin/anomaly-detector.sh
EOF
    chmod 644 /etc/cron.d/anomaly-detector

    # Logrotate for anomaly detector log
    if [ ! -f /etc/logrotate.d/anomaly-detector ]; then
        cat > /etc/logrotate.d/anomaly-detector <<'EOF'
/var/log/anomaly-detections.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
}
EOF
        chmod 644 /etc/logrotate.d/anomaly-detector
    fi

    print_success "Anomaly detection configured."
    log "Anomaly detection completed."
}

# -----------------------
# Auditd trimmed integration
# -----------------------
configure_auditd() {
    print_section "auditd integration (trimmed rules)"

    if ! confirm "Install and enable auditd?"; then
        print_info "Skipping auditd."
        return 0
    fi

    if ! is_installed auditd; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd audispd-plugins
    fi

    AUDIT_RULES_FILE="/etc/audit/rules.d/99-security.rules"
    # Write trimmed rules only if missing or different
    AUDIT_RULES_TMP=$(mktemp)
    cat > "${AUDIT_RULES_TMP}" <<'EOF'
# Trimmed audit rules - high value events only
# --- Identity and credential stores ---
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity

# --- Privilege + sudo rules ---
-w /etc/sudoers -p wa -k privileged
-w /etc/sudoers.d -p wa -k privileged
-w /usr/bin/sudo -p x -k privileged

# --- SSH daemon integrity ---
-w /usr/sbin/sshd -p x -k sshd

# --- Cron persistence mechanisms ---
-w /etc/cron.allow -p wa -k cron
-w /etc/cron.d -p wa -k cron

# --- Auth log tampering ---
-w /var/log/auth.log -p wa -k authlog

# --- Command execution tracking (execve) ---
# Still the most valuable audit rule on a server
# but without filtering noise-heavy syscalls.
-a always,exit -F arch=b64 -S execve -k execs
-a always,exit -F arch=b32 -S execve -k execs
EOF

    if [ ! -f "${AUDIT_RULES_FILE}" ] || ! cmp -s "${AUDIT_RULES_TMP}" "${AUDIT_RULES_FILE}"; then
        mv "${AUDIT_RULES_TMP}" "${AUDIT_RULES_FILE}"
        chmod 644 "${AUDIT_RULES_FILE}"

        # Optional: Add Docker/Nginx if present (append to the rules file)
        if command -v docker >/dev/null; then
            if ! grep -q "-w /usr/bin/docker" "${AUDIT_RULES_FILE}"; then
                echo "-w /usr/bin/docker -p x -k docker" >> "${AUDIT_RULES_FILE}"
            fi
        fi
        if [ -d /etc/nginx ]; then
            if ! grep -q "-w /etc/nginx" "${AUDIT_RULES_FILE}"; then
                echo "-w /etc/nginx -p wa -k nginx" >> "${AUDIT_RULES_FILE}"
            fi
        fi
        augenrules --load >/dev/null 2>&1 || true
        print_info "Auditd rules updated."
    else
        rm -f "${AUDIT_RULES_TMP}"
        print_info "Auditd rules already up-to-date."
    fi

    # Logrotate for auditd (only auditd logs)
    if [ ! -f /etc/logrotate.d/auditd ]; then
        cat > /etc/logrotate.d/auditd <<'EOF'
/var/log/audit/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        /usr/sbin/service auditd rotate >/dev/null 2>&1 || true
    endscript
}
EOF
        chmod 644 /etc/logrotate.d/auditd
    fi

    systemctl enable --now auditd >/dev/null 2>&1 || true
    print_success "auditd configured."
    log "auditd configuration completed."
}

# -----------------------
# Test IDS stack (basic)
# -----------------------
test_intrusion_detection() {
    print_section "IDS self-test"

    if ! confirm "Run IDS tests (basic)?"; then
        print_info "Skipping IDS tests."
        return 0
    fi

    # Wazuh check
    print_info "Checking Wazuh manager status..."
    if [ -x "${WAZUH_CONTROL}" ] && "${WAZUH_CONTROL}" status | grep -q "is running"; then
        print_success "Wazuh manager running."
        touch /etc/wazuh-test-file && rm -f /etc/wazuh-test-file
        sleep 5
        if [ -f "${WAZUH_ALERTS_LOG}" ] && grep -q "wazuh-test-file" "${WAZUH_ALERTS_LOG}" 2>/dev/null; then
            print_success "Wazuh file monitoring appears to work."
        else
            print_warning "Wazuh file test inconclusive; check Wazuh logs."
        fi
    else
        print_error "Wazuh manager not running or control script missing."
    fi

    # AIDE
    if is_installed aide; then
        if /usr/bin/aide --check >/dev/null 2>&1; then
            print_success "AIDE check OK."
        else
            print_warning "AIDE reported changes or had errors; inspect logs."
        fi
    else
        print_warning "AIDE not installed."
    fi

    # rkhunter/chkrootkit
    if is_installed chkrootkit; then
        chkrootkit 2>&1 | logger -t chkrootkit || true
    fi
    if is_installed rkhunter; then
        rkhunter --check --rwo --sk 2>&1 | logger -t rkhunter || true
    fi

    # anomaly detector
    if [ -f /usr/local/bin/anomaly-detector.sh ]; then
        /usr/local/bin/anomaly-detector.sh || true
        print_success "Anomaly detector executed."
    fi

    # auditd
    if systemctl is-active --quiet auditd; then
        print_success "auditd active."
    else
        print_warning "auditd not active."
    fi

    print_success "IDS tests completed."
    log "IDS test finished."
}

# -----------------------
# Main orchestration
# -----------------------
configure_intrusion_detection() {
    print_section "Intrusion Detection System Setup (manager-only)"
    install_mailutils_noninteractive
    configure_wazuh
    configure_aide
    configure_rootkit_detection
    configure_log_correlation
    configure_anomaly_detection
    configure_auditd
    test_intrusion_detection
    print_success "IDS module finished."
    log "IDS module completed."
}

# If run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_intrusion_detection
fi
