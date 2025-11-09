#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Intrusion Detection System Module
# Handles OSSEC HIDS, rootkit detection, and advanced monitoring
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- OSSEC Installation and Configuration ---
configure_ossec() {
    print_section "OSSEC HIDS Configuration"

    if ! confirm "Install OSSEC Host-based Intrusion Detection System?"; then
        print_info "Skipping OSSEC installation."
        return 0
    fi

    # Check if OSSEC is already installed
    if command -v ossec-control >/dev/null 2>&1; then
        print_info "OSSEC is already installed."
        if confirm "Reconfigure OSSEC?"; then
            print_info "Backing up existing OSSEC configuration..."
            cp -r /var/ossec/etc "$BACKUP_DIR/ossec_etc_backup_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        else
            return 0
        fi
    fi

    # Install OSSEC dependencies
    print_info "Installing OSSEC dependencies..."
    apt-get install -y -qq build-essential inotify-tools libssl-dev python3-dev

    # Download and compile OSSEC
    local OSSEC_VERSION="3.7.0"
    local OSSEC_TAR="ossec-hids-${OSSEC_VERSION}.tar.gz"
    local OSSEC_URL="https://github.com/ossec/ossec-hids/archive/${OSSEC_VERSION}.tar.gz"
    local OSSEC_DIR="/tmp/ossec-hids-${OSSEC_VERSION}"

    print_info "Downloading OSSEC ${OSSEC_VERSION}..."
    if ! curl -sL "$OSSEC_URL" -o "/tmp/$OSSEC_TAR"; then
        print_error "Failed to download OSSEC."
        return 1
    fi

    print_info "Extracting OSSEC..."
    cd /tmp
    tar -xzf "$OSSEC_TAR" || {
        print_error "Failed to extract OSSEC archive."
        rm -f "/tmp/$OSSEC_TAR"
        return 1
    }

    # Pre-generate OSSEC answers for automated installation
    print_info "Configuring OSSEC for automated installation..."
    cat > /tmp/preseed.txt <<'EOF'
en
server
local
/var/ossec
no
yes
no
no
no
yes
no
no
no
EOF

    print_info "Installing OSSEC (this may take several minutes)..."
    cd "$OSSEC_DIR"
    if ! bash ./install.sh < /tmp/preseed.txt > /tmp/ossec_install.log 2>&1; then
        print_error "OSSEC installation failed. Check /tmp/ossec_install.log for details."
        cd /
        rm -rf "$OSSEC_DIR" "/tmp/$OSSEC_TAR" /tmp/preseed.txt
        return 1
    fi

    # Configure OSSEC
    print_info "Configuring OSSEC rules..."

    # Create OSSEC configuration
    tee /var/ossec/etc/ossec.conf > /dev/null <<'EOF'
<ossec_config>
  <global>
    <email_notification>no</email_notification>
    <jsonout_output>yes</jsonout_output>
  </global>

  <rules>
    <include>rules_config.xml</include>
    <include>sshd_rules.xml</include>
    <include>syslog_rules.xml</include>
    <include>web_rules.xml</include>
    <include>apache_rules.xml</include>
    <include>nginx_rules.xml</include>
    <include>local_rules.xml</include>
  </rules>

  <syscheck>
    <frequency>7200</frequency>
    <scan_on_start>yes</scan_on_start>

    <!-- Directories to monitor -->
    <directories check_all="yes" realtime="yes">/etc,/usr/bin,/usr/sbin</directories>
    <directories check_all="yes" realtime="yes">/bin,/sbin,/boot</directories>
    <directories check_all="yes">/root,/home</directories>

    <!-- Files to ignore -->
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/hosts.deny</ignore>
    <ignore>/etc/mail/statistics</ignore>
    <ignore>/etc/random-seed</ignore>
    <ignore>/etc/adjtime</ignore>
    <ignore>/etc/httpd/logs</ignore>
    <ignore>/etc/utmpx</ignore>
    <ignore>/etc/wtmpx</ignore>
    <ignore>/etc/cups/certs</ignore>
    <ignore>/etc/dumpdates</ignore>
    <ignore>/etc/svc/volatile</ignore>
    <ignore>/sys/kernel/security</ignore>
    <ignore>/var/run/fail2ban/fail2ban.sock</ignore>
  </syscheck>

  <rootcheck>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/access.log</location>
  </localfile>

  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/error.log</location>
  </localfile>

  <localfile>
    <log_format>nginx</log_format>
    <location>/var/log/nginx/access.log</location>
  </localfile>

  <localfile>
    <log_format>nginx</log_format>
    <location>/var/log/nginx/error.log</location>
  </localfile>

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

  <active-responses>
    <command>firewall-drop</command>
    <location>local</location>
    <level>6</level>
    <timeout>300</timeout>
  </active-responses>
</ossec_config>
EOF

    # Create custom local rules for enhanced detection
    tee /var/ossec/rules/local_rules.xml > /dev/null <<'EOF'
<group name="local,syslog,">
  <!-- Custom rules for enhanced security monitoring -->

  <!-- Detect multiple SSH failed attempts from same IP -->
  <rule id="100001" level="10" frequency="6" timeframe="120">
    <if_sid>5710</if_sid>
    <same_source_ip />
    <description>Multiple SSH failed attempts from same source IP.</description>
    <group>authentication_failures,ssh</group>
  </rule>

  <!-- Detect sudo usage by non-authorized users -->
  <rule id="100002" level="8">
    <if_sid>5400</if_sid>
    <match>sudo:</match>
    <regex>USER=root ; COMMAND=</regex>
    <description>Sudo command executed as root.</description>
    <group>privilege_escalation,sudo</group>
  </rule>

  <!-- Detect new user creation -->
  <rule id="100003" level="7">
    <if_sid>5500</if_sid>
    <match>useradd</match>
    <description>New user account created.</description>
    <group>adduser,account_change</group>
  </rule>

  <!-- Detect suspicious cron job modifications -->
  <rule id="100004" level="8">
    <if_sid>5400</if_sid>
    <match>crontab</match>
    <regex>EDIT|REPLACE|DELETE</regex>
    <description>Crontab file modified.</description>
    <group>config_change,cron</group>
  </rule>

  <!-- Detect package installations -->
  <rule id="100005" level="7">
    <if_sid>5400</if_sid>
    <match>dpkg|apt-get|apt</match>
    <regex>install|install</regex>
    <description>Package installation detected.</description>
    <group>package_install,software_mgmt</group>
  </rule>

  <!-- Detect network interface changes -->
  <rule id="100006" level="8">
    <if_sid>5400</if_sid>
    <match>ip link|ifconfig</match>
    <regex>up|down</regex>
    <description>Network interface state changed.</description>
    <group>network_change</group>
  </rule>

  <!-- Detect file integrity violations -->
  <rule id="100007" level="12">
    <if_sid>550</if_sid>
    <description>Integrity checksum changed.</description>
    <group>ossec,syscheck</group>
  </rule>
</group>
EOF

    # Enable and start OSSEC
    print_info "Enabling OSSEC services..."
    /var/ossec/bin/ossec-control enable
    /var/ossec/bin/ossec-control start

    # Verify OSSEC is running
    if /var/ossec/bin/ossec-control status | grep -q "is running"; then
        print_success "OSSEC HIDS is installed and running."

        # Add OSSEC to startup
        tee /etc/systemd/system/ossec.service > /dev/null <<'EOF'
[Unit]
Description=OSSEC HIDS
After=network.target

[Service]
Type=forking
ExecStart=/var/ossec/bin/ossec-control start
ExecStop=/var/ossec/bin/ossec-control stop
ExecReload=/var/ossec/bin/ossec-control restart
PIDFile=/var/ossec/var/ossec.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

        systemctl enable ossec.service
        systemctl daemon-reload

        # Create initial baseline
        print_info "Creating initial file integrity baseline..."
        /var/ossec/bin/syscheckd -f

        log "OSSEC HIDS installation completed."
    else
        print_error "OSSEC failed to start properly."
        return 1
    fi

    # Cleanup
    cd /
    rm -rf "$OSSEC_DIR" "/tmp/$OSSEC_TAR" /tmp/preseed.txt
}

# --- Rootkit Detection Tools ---
configure_rootkit_detection() {
    print_section "Rootkit Detection Configuration"

    if ! confirm "Install and configure rootkit detection tools (chkrootkit and rkhunter)?"; then
        print_info "Skipping rootkit detection tools."
        return 0
    fi

    # Install chkrootkit
    print_info "Installing chkrootkit..."
    apt-get install -y -qq chkrootkit

    # Install rkhunter
    print_info "Installing rkhunter..."
    apt-get install -y -qq rkhunter

    # Configure rkhunter
    print_info "Configuring rkhunter..."

    # Update rkhunter database
    rkhunter --update --rwo

    # Create rkhunter configuration
    tee /etc/rkhunter.conf.local > /dev/null <<'EOF'
# RKHunter local configuration for enhanced security
# Allow script files to be writable by their owner
ALLOW_SSH_ROOT_USER=no
ALLOW_SSH_PROT_V1=0
ENABLE_TESTS=all
DISABLE_TESTS=none
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

    # Run initial rkhunter check
    print_info "Running initial rkhunter system check..."
    rkhunter --check --rwo --sk || true

    # Create cron jobs for regular scanning
    print_info "Setting up regular rootkit scans..."

    # Daily chkrootkit scan
    echo "0 2 * * * /usr/sbin/chkrootkit 2>&1 | logger -t chkrootkit" > /etc/cron.daily/chkrootkit
    chmod +x /etc/cron.daily/chkrootkit

    # Weekly rkhunter scan
    cat > /etc/cron.weekly/rkhunter <<'EOF'
#!/bin/bash
# Weekly rkhunter scan with database update
/usr/bin/rkhunter --update --rwo
/usr/bin/rkhunter --check --rwo --sk | logger -t rkhunter
EOF
    chmod +x /etc/cron.weekly/rkhunter

    print_success "Rootkit detection tools installed and configured."
    log "Rootkit detection configuration completed."
}

# --- Log Correlation and Analysis ---
configure_log_correlation() {
    print_section "Log Correlation and Analysis"

    if ! confirm "Configure centralized log correlation and analysis?"; then
        print_info "Skipping log correlation setup."
        return 0
    fi

    # Ensure logrotate is configured for security logs
    print_info "Configuring log rotation for security logs..."

    tee /etc/logrotate.d/security-logs > /dev/null <<'EOF'
/var/log/auth.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}

/var/log/ossec/logs/alerts.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    sharedscripts
    postrotate
        /var/ossec/bin/ossec-control restart >/dev/null 2>&1 || true
    endscript
}
EOF

    # Create log analysis script
    print_info "Creating log analysis script..."
    tee /usr/local/bin/security-log-analyzer.sh > /dev/null <<'EOF'
#!/bin/bash
# Security Log Analyzer Script
# Analyzes various security logs for suspicious activities

LOG_FILE="/var/log/security-analysis.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Function to log with timestamp
log_message() {
    echo "[$DATE] $1" >> "$LOG_FILE"
}

# Analyze SSH authentication failures
analyze_ssh_failures() {
    local failed_count
    failed_count=$(grep "authentication failure" /var/log/auth.log | grep "$(date '+%b %d')" | wc -l)
    if [ "$failed_count" -gt 10 ]; then
        log_message "WARNING: High number of SSH failures detected: $failed_count"
    fi
}

# Analyze sudo usage
analyze_sudo_usage() {
    local sudo_count
    sudo_count=$(grep "sudo:" /var/log/auth.log | grep "$(date '+%b %d')" | wc -l)
    if [ "$sudo_count" -gt 20 ]; then
        log_message "INFO: High sudo usage detected: $sudo_count commands"
    fi
}

# Analyze OSSEC alerts
analyze_ossec_alerts() {
    if [ -f /var/ossec/logs/alerts/alerts.log ]; then
        local high_alerts
        high_alerts=$(grep "$(date '+%Y %m %d')" /var/ossec/logs/alerts/alerts.log | grep -E "level [7-9]" | wc -l)
        if [ "$high_alerts" -gt 0 ]; then
            log_message "ALERT: $high_alerts high-priority OSSEC alerts detected"
        fi
    fi
}

# Run all analyses
analyze_ssh_failures
analyze_sudo_usage
analyze_ossec_alerts
EOF

    chmod +x /usr/local/bin/security-log-analyzer.sh

    # Add to cron for hourly analysis
    echo "0 * * * * /usr/local/bin/security-log-analyzer.sh" > /etc/cron.hourly/security-log-analyzer
    chmod +x /etc/cron.hourly/security-log-analyzer

    print_success "Log correlation and analysis configured."
    log "Log correlation configuration completed."
}

# --- Behavioral Anomaly Detection ---
configure_anomaly_detection() {
    print_section "Behavioral Anomaly Detection"

    if ! confirm "Configure basic behavioral anomaly detection?"; then
        print_info "Skipping anomaly detection setup."
        return 0
    fi

    # Install monitoring dependencies
    print_info "Installing anomaly detection dependencies..."
    apt-get install -y -qq iotop nethogs

    # Create anomaly detection script
    print_info "Creating anomaly detection script..."
    tee /usr/local/bin/anomaly-detector.sh > /dev/null <<'EOF'
#!/bin/bash
# Basic Anomaly Detection Script
# Monitors for unusual system behavior

ALERT_LOG="/var/log/anomaly-detections.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Function to send alerts
send_alert() {
    local message="$1"
    echo "[$DATE] ANOMALY: $message" >> "$ALERT_LOG"

    # If notification system is configured, send alert
    if [ -f /root/run_backup.sh ]; then
        # Extract notification settings from backup script
        if grep -q "NTFY_URL=" /root/run_backup.sh && ! grep -q 'NTFY_URL=""' /root/run_backup.sh; then
            NTFY_URL=$(grep "^NTFY_URL=" /root/run_backup.sh | cut -d'"' -f2)
            NTFY_TOKEN=$(grep "^NTFY_TOKEN=" /root/run_backup.sh | cut -d'"' -f2)
            curl -s -H "Title: Security Anomaly Detected" ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} -d "$message" "$NTFY_URL" > /dev/null 2>&1 || true
        elif grep -q "DISCORD_WEBHOOK=" /root/run_backup.sh && ! grep -q 'DISCORD_WEBHOOK=""' /root/run_backup.sh; then
            DISCORD_WEBHOOK=$(grep "^DISCORD_WEBHOOK=" /root/run_backup.sh | cut -d'"' -f2)
            local escaped_message=$(echo "$message" | sed 's/"/\\"/g')
            local json_payload=$(printf '{"embeds": [{"title": "Security Anomaly Detected", "description": "%s", "color": 15158332}]}' "$escaped_message")
            curl -s -H "Content-Type: application/json" -d "$json_payload" "$DISCORD_WEBHOOK" > /dev/null 2>&1 || true
        fi
    fi
}

# Check for unusual CPU usage
check_cpu_usage() {
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    if (( $(echo "$cpu_usage > 80" | bc -l) )); then
        send_alert "High CPU usage detected: ${cpu_usage}%"
    fi
}

# Check for unusual memory usage
check_memory_usage() {
    local mem_usage
    mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
    if [ "$mem_usage" -gt 90 ]; then
        send_alert "High memory usage detected: ${mem_usage}%"
    fi
}

# Check for unusual network connections
check_network_connections() {
    local conn_count
    conn_count=$(ss -tn | wc -l)
    if [ "$conn_count" -gt 200 ]; then
        send_alert "High number of network connections: $conn_count"
    fi
}

# Check for unusual process count
check_process_count() {
    local proc_count
    proc_count=$(ps aux | wc -l)
    if [ "$proc_count" -gt 300 ]; then
        send_alert "High process count detected: $proc_count"
    fi
}

# Run all checks
check_cpu_usage
check_memory_usage
check_network_connections
check_process_count
EOF

    chmod +x /usr/local/bin/anomaly-detector.sh

    # Add to cron for every 15 minutes
    echo "*/15 * * * * /usr/local/bin/anomaly-detector.sh" > /etc/cron.d/anomaly-detector

    print_success "Behavioral anomaly detection configured."
    log "Anomaly detection configuration completed."
}

# --- Test Intrusion Detection Systems ---
test_intrusion_detection() {
    print_section "Intrusion Detection System Test"

    if ! confirm "Test intrusion detection systems?"; then
        print_info "Skipping IDS test."
        return 0
    fi

    print_info "Testing OSSEC..."
    if command -v /var/ossec/bin/ossec-control >/dev/null 2>&1; then
        if /var/ossec/bin/ossec-control status | grep -q "is running"; then
            print_success "OSSEC is running properly."

            # Test OSSEC by triggering a rule
            touch /etc/ossec-test-file
            rm /etc/ossec-test-file
            sleep 2
            if grep -q "ossec-test-file" /var/ossec/logs/alerts/alerts.log 2>/dev/null; then
                print_success "OSSEC file monitoring is working."
            else
                print_warning "OSSEC file monitoring test inconclusive."
            fi
        else
            print_error "OSSEC is not running."
        fi
    else
        print_error "OSSEC is not installed."
    fi

    print_info "Testing rootkit detection tools..."
    if command -v chkrootkit >/dev/null 2>&1; then
        print_success "chkrootkit is installed."
        if chkrootkit 2>/dev/null | grep -q "INFECTED"; then
            print_error "chkrootkit reported potential infections!"
        else
            print_success "chkrootkit scan completed without detections."
        fi
    else
        print_error "chkrootkit is not installed."
    fi

    if command -v rkhunter >/dev/null 2>&1; then
        print_success "rkhunter is installed."
        if rkhunter --check --rwo --sk 2>/dev/null; then
            print_success "rkhunter scan completed without warnings."
        else
            print_warning "rkhunter reported warnings (check logs)."
        fi
    else
        print_error "rkhunter is not installed."
    fi

    print_info "Testing anomaly detection..."
    if [ -f /usr/local/bin/anomaly-detector.sh ]; then
        /usr/local/bin/anomaly-detector.sh
        if [ -f /var/log/anomaly-detections.log ]; then
            print_success "Anomaly detection script is functional."
        else
            print_warning "Anomaly detection test inconclusive."
        fi
    else
        print_error "Anomaly detection script not found."
    fi

    print_success "Intrusion detection system test completed."
    log "IDS test completed."
}

# --- Main Intrusion Detection Configuration Function ---
configure_intrusion_detection() {
    print_section "Intrusion Detection System Setup"

    # Install and configure each component
    configure_ossec
    configure_rootkit_detection
    configure_log_correlation
    configure_anomaly_detection

    # Test the systems
    test_intrusion_detection

    print_success "Intrusion Detection System configuration completed."
    log "Intrusion Detection System module completed."
}