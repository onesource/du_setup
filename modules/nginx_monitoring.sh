#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Nginx Monitoring and Logging Module
# Handles security monitoring, log analysis, and alerting
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Setup Nginx Monitoring ---
setup_nginx_monitoring() {
    print_section "Nginx Security Monitoring Setup"

    while true; do
        printf '%s\n' "${CYAN}Monitoring Options:${NC}"
        printf '  0) Return to Main Menu%s\n' "$NC"
        printf '  1) Setup Log Analysis and Alerting%s\n' "$NC"
        printf '  2) Configure Fail2ban for Nginx%s\n' "$NC"
        printf '  3) Setup Log Rotation%s\n' "$NC"
        printf '  4) Create Security Dashboard%s\n' "$NC"
        printf '  5) Setup Performance Monitoring%s\n' "$NC"

        read -rp "$(printf '%s' "${CYAN}Enter choice (0-5): ${NC}")" MONITOR_CHOICE
        case $MONITOR_CHOICE in
            0)
                print_info "Returning to main menu..."
                return 0
                ;;
            1) setup_log_analysis ;;
            2) setup_fail2ban_nginx ;;
            3) setup_log_rotation ;;
            4) setup_security_dashboard ;;
            5) setup_performance_monitoring ;;
            *)
                print_error "Invalid choice. Please enter 0-5."
                continue
                ;;
        esac

        # Ask if user wants to perform another monitoring task
        echo
        read -rp "$(printf '%s' "${CYAN}Do you want to perform another monitoring task? (y/n): ${NC}")" ANOTHER_TASK
        if [[ ! "$ANOTHER_TASK" =~ ^[Yy]$ ]]; then
            print_info "Exiting Nginx monitoring setup..."
            return 0
        fi
        echo
    done
}

# --- Setup Log Analysis ---
setup_log_analysis() {
    print_info "Setting up log analysis and alerting..."

    # Create necessary directories
    mkdir -p /opt/nginx/scripts
    mkdir -p /var/log/nginx

    # Create configuration file for monitoring settings (Overwrites existing)
    print_info "Updating monitoring configuration file: /etc/nginx-monitoring.conf"
    cat > /etc/nginx-monitoring.conf << EOF
# Nginx Monitoring Configuration
# Thresholds and settings can be customized here

# Alert thresholds
ALERT_THRESHOLD=\${ALERT_THRESHOLD:-100}
CPU_THRESHOLD=\${CPU_THRESHOLD:-80}
MEMORY_THRESHOLD=\${MEMORY_THRESHOLD:-80}
ERROR_RATE_THRESHOLD=\${ERROR_RATE_THRESHOLD:-5}
RESPONSE_TIME_THRESHOLD=\${RESPONSE_TIME_THRESHOLD:-1.0}

# Email settings
REPORT_EMAIL=\${REPORT_EMAIL:-$ADMIN_EMAIL}
ALERT_RATE_LIMIT_MINUTES=\${ALERT_RATE_LIMIT_MINUTES:-60}

# Fail2ban settings
MAXRETRY_AUTH=\${MAXRETRY_AUTH:-3}
MAXRETRY_LIMIT_REQ=\${MAXRETRY_LIMIT_REQ:-10}
MAXRETRY_NOSCRIPT=\${MAXRETRY_NOSCRIPT:-6}
MAXRETRY_BADBOTS=\${MAXRETRY_BADBOTS:-2}
MAXRETRY_NOPROXY=\${MAXRETRY_NOPROXY:-2}

# Whitelisted IPs (comma-separated)
WHITELISTED_IPS=\${WHITELISTED_IPS:-}
EOF

    # Create log analysis script
    cat > /opt/nginx/scripts/analyze_logs.sh << 'EOF'
#!/bin/bash

# Nginx log analysis script for security monitoring
LOG_DIR="/var/log/nginx"

# Load configuration
if [[ -f /etc/nginx-monitoring.conf ]]; then
    source /etc/nginx-monitoring.conf
else
    ALERT_THRESHOLD=100
    REPORT_EMAIL="${REPORT_EMAIL:-admin@localhost}"
    ALERT_RATE_LIMIT_MINUTES=60
fi

# Rate limiting for alerts
ALERT_LOCK_FILE="/tmp/nginx_alert_lock"
ALERT_LAST_SENT_FILE="/tmp/nginx_alert_last_sent"

# Function to check if alert should be sent (rate limiting)
check_alert_rate_limit() {
    local alert_type="$1"
    local lock_file="${ALERT_LOCK_FILE}_${alert_type}"
    local last_sent_file="${ALERT_LAST_SENT_FILE}_${alert_type}"

    # Check if alert was sent recently
    if [[ -f "$last_sent_file" ]]; then
        local last_sent=$(cat "$last_sent_file")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_sent))
        local limit_seconds=$((ALERT_RATE_LIMIT_MINUTES * 60))

        if [[ $time_diff -lt $limit_seconds ]]; then
            return 1  # Don't send alert
        fi
    fi

    return 0  # Send alert
}

# Function to send alert
send_alert() {
    local subject="$1"
    local message="$2"
    local alert_type="${3:-default}"

    # Check rate limit
    if ! check_alert_rate_limit "$alert_type"; then
        echo "$(date): Alert rate limited - $subject" >> /var/log/nginx/security_alerts.log
        return
    fi

    # Send email if configured
    if command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "$subject" "$REPORT_EMAIL"
    fi

    # Log alert and update timestamp
    echo "$(date): $subject - $message" >> /var/log/nginx/security_alerts.log
    echo "$(date +%s)" > "/tmp/nginx_alert_last_sent_${alert_type}"
}

# Analyze access logs for suspicious activity
analyze_access_logs() {
    local access_log="$LOG_DIR/access.log"

    if [[ ! -f "$access_log" ]]; then
        return 1
    fi

    # Count requests by IP (last hour)
    local suspicious_ips=$(awk '($1) { count[$1]++ } END { for (ip in count) if (count[ip] > 100) print ip, count[ip] }' "$access_log")

    if [[ -n "$suspicious_ips" ]]; then
        send_alert "High Traffic Alert" "Suspicious high traffic from IPs:\n$suspicious_ips" "high_traffic"
    fi

    # Detect potential attacks - improved patterns
    local attack_patterns=$(grep -Ei "(union\s+select|script.*alert|<script[^>]*>|javascript:|eval\(|document\.cookie)" "$access_log" | tail -10)

    if [[ -n "$attack_patterns" ]]; then
        send_alert "Attack Pattern Detected" "Potential XSS/SQL injection attempts:\n$attack_patterns" "attack_pattern"
    fi

    # Detect 404 floods
    local not_found_count=$(awk '($9 == "404") { count++ } END { print count+0 }' "$access_log")

    if [[ $not_found_count -gt $ALERT_THRESHOLD ]]; then
        send_alert "404 Flood Alert" "High number of 404 errors: $not_found_count" "404_flood"
    fi
}

# Analyze error logs
analyze_error_logs() {
    local error_log="$LOG_DIR/error.log"

    if [[ ! -f "$error_log" ]]; then
        return 1
    fi

    # Count critical errors
    local critical_errors=$(grep -i "crit\|emerg" "$error_log" | tail -5)

    if [[ -n "$critical_errors" ]]; then
        send_alert "Critical Nginx Errors" "Critical errors detected:\n$critical_errors" "critical_error"
    fi
}

# Generate daily report
generate_daily_report() {
    local report_file="/var/log/nginx/daily_report_$(date +%Y%m%d).txt"

    {
        echo "Nginx Daily Security Report - $(date)"
        echo "=================================="
        echo

        # Top IPs
        echo "Top 10 IP Addresses:"
        awk '($1) { count[$1]++ } END { for (ip in count) print ip, count[ip] }' "$LOG_DIR/access.log" | sort -k2 -nr | head -10
        echo

        # Top URLs
        echo "Top 10 Requested URLs:"
        awk '($7) { count[$7]++ } END { for (url in count) print url, count[url] }' "$LOG_DIR/access.log" | sort -k2 -nr | head -10
        echo

        # HTTP Status Codes
        echo "HTTP Status Code Distribution:"
        awk '($9) { count[$9]++ } END { for (code in count) print code, count[code] }' "$LOG_DIR/access.log" | sort -k1
        echo

        # Error Summary
        echo "Error Summary:"
        grep -i "error\|warn\|crit" "$LOG_DIR/error.log" | tail -10
        echo

    } > "$report_file"

    # Send daily report
    if command -v mail >/dev/null 2>&1; then
        mail -s "Nginx Daily Report - $(date +%Y-%m-%d)" "$REPORT_EMAIL" < "$report_file"
    fi
}

# Main execution
case "${1:-analyze}" in
    analyze)
        analyze_access_logs
        analyze_error_logs
        ;;
    report)
        generate_daily_report
        ;;
    *)
        echo "Usage: $0 {analyze|report}"
        exit 1
        ;;
esac
EOF

    chmod +x /opt/nginx/scripts/analyze_logs.sh

    # Create security alerts log
    touch /var/log/nginx/security_alerts.log
    chmod 600 /var/log/nginx/security_alerts.log
    chown root:root /var/log/nginx/security_alerts.log

    # Setup cron jobs for log analysis
    if crontab -l 2>/dev/null | grep -q "analyze_logs.sh"; then
        print_info "Updating log analysis cron jobs..."
        (crontab -l 2>/dev/null | grep -v "analyze_logs.sh") | crontab -
    fi
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/nginx/scripts/analyze_logs.sh analyze") | crontab -
    (crontab -l 2>/dev/null; echo "0 6 * * * /opt/nginx/scripts/analyze_logs.sh report") | crontab -
    print_success "Log analysis and alerting configured."
    log "Nginx log analysis setup completed" 2>/dev/null || true
}

# --- Setup Fail2ban for Nginx ---
setup_fail2ban_nginx() {
    print_info "Configuring Fail2ban for Nginx..."

    # Check if fail2ban is installed
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        print_error "Fail2ban is not installed. Please install it first."
        return 1
    fi

    # Create necessary directories
    mkdir -p /etc/fail2ban/jail.d
    mkdir -p /etc/fail2ban/filter.d

    # Load configuration for Fail2ban settings
    if [[ -f /etc/nginx-monitoring.conf ]]; then
        source /etc/nginx-monitoring.conf
    fi

    # Create Nginx jail configuration (Overwrites existing)
    print_info "Updating Nginx jail configuration: /etc/fail2ban/jail.d/nginx.conf"
    cat > /etc/fail2ban/jail.d/nginx.conf << 'EOF'
[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 5
bantime = 3600
findtime = 600

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 15
bantime = 600
findtime = 300

[nginx-noscript]
enabled = true
filter = nginx-noscript
logpath = /var/log/nginx/access.log
maxretry = 10
bantime = 86400
findtime = 600

[nginx-badbots]
enabled = true
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 5
bantime = 86400
findtime = 600

[nginx-noproxy]
enabled = true
filter = nginx-noproxy
logpath = /var/log/nginx/access.log
maxretry = 5
bantime = 86400
findtime = 300

[nginx-scan]
enabled = true
filter = nginx-scan
logpath = /var/log/nginx/access.log
maxretry = 20
bantime = 86400
findtime = 3600
EOF

    # Create Nginx filter definitions
    cat > /etc/fail2ban/filter.d/nginx-http-auth.conf << 'EOF'
[Definition]
failregex = ^ \[error\] \d+#\d+: \*\d+ user .* was not found in ".*"$
            ^ \[error\] \d+#\d+: \*\d+ no user/password was provided for basic authentication.*
            ^ \[error\] \d+#\d+: user .*: password mismatch.*
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nginx-limit-req.conf << 'EOF'
[Definition]
failregex = limiting requests, excess: .* by zone .*, client: <HOST>
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nginx-noscript.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*GET.*(\.php\?.*=|\.asp\?.*=|\.exe\?|\.pl\?|\.cgi\?)
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nginx-badbots.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*HTTP.*".*"(?:BadBot|EvilBot|MaliciousBot|Scanner|Harvester)"
ignoreregex = ^<HOST> -.*"(GET|POST).*HTTP.*".*"(?:Googlebot|bingbot|Slurp|DuckDuckBot|Baiduspider|YandexBot|facebookexternalhit|Twitterbot|LinkedInBot|WhatsApp)
EOF

    cat > /etc/fail2ban/filter.d/nginx-noproxy.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*GET http://.*(example\.com|test\.com|malicious\.com)
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nginx-scan.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*GET.*(\.env|\.git|\.svn|wp-config|config\.php|admin\.php|install\.php|wp-login\.php|xmlrpc\.php)
ignoreregex =
EOF

    # Create ignoreip configuration
    cat > /etc/fail2ban/jail.d/ignoreips.conf << 'EOF'
[DEFAULT]
# Space-separated list of IP addresses that cannot be banned
# Add your trusted IPs here
ignoreip = 127.0.0.1/8 ::1
EOF

    # Add whitelisted IPs from configuration if provided
    if [[ -f /etc/nginx-monitoring.conf ]]; then
        source /etc/nginx-monitoring.conf
        if [[ -n "$WHITELISTED_IPS" ]]; then
            sed -i "s/^ignoreip =.*/ignoreip = 127.0.0.1\/8 ::1 $WHITELISTED_IPS/" /etc/fail2ban/jail.d/ignoreips.conf
        fi
    fi

    # Restart fail2ban
    systemctl restart fail2ban

    print_success "Fail2ban configured for Nginx."
    print_info "Jail status: fail2ban-client status nginx-http-auth"
    log "Fail2ban Nginx configuration completed" 2>/dev/null || true
}

# --- Setup Log Rotation ---
setup_log_rotation() {
    print_info "Setting up log rotation..."

    # Create necessary directories
    if ! mkdir -p /var/log/nginx 2>/dev/null; then
        print_error "Failed to create /var/log/nginx directory"
        return 1
    fi
    print_info "Directory /var/log/nginx created"

    # Create logrotate configuration using printf for better reliability
    print_info "Creating logrotate configuration..."
    printf '%s\n' '/var/log/nginx/*.log {' > /etc/logrotate.d/nginx
    printf '%s\n' '    daily' >> /etc/logrotate.d/nginx
    printf '%s\n' '    missingok' >> /etc/logrotate.d/nginx
    printf '%s\n' '    rotate 30' >> /etc/logrotate.d/nginx
    printf '%s\n' '    compress' >> /etc/logrotate.d/nginx
    printf '%s\n' '    delaycompress' >> /etc/logrotate.d/nginx
    printf '%s\n' '    notifempty' >> /etc/logrotate.d/nginx
    printf '%s\n' '    create 0640 root adm' >> /etc/logrotate.d/nginx
    printf '%s\n' '    sharedscripts' >> /etc/logrotate.d/nginx
    printf '%s\n' '    postrotate' >> /etc/logrotate.d/nginx
    printf '%s\n' '        if [ -f /var/run/nginx.pid ]; then' >> /etc/logrotate.d/nginx
    printf '%s\n' '            kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true' >> /etc/logrotate.d/nginx
    printf '%s\n' '        fi' >> /etc/logrotate.d/nginx
    printf '%s\n' '        if systemctl is-active --quiet nginx 2>/dev/null; then' >> /etc/logrotate.d/nginx
    printf '%s\n' '            systemctl reload nginx 2>/dev/null || true' >> /etc/logrotate.d/nginx
    printf '%s\n' '        fi' >> /etc/logrotate.d/nginx
    printf '%s\n' '    endscript' >> /etc/logrotate.d/nginx
    printf '%s\n' '}' >> /etc/logrotate.d/nginx
    printf '%s\n' '' >> /etc/logrotate.d/nginx
    printf '%s\n' '/var/log/nginx/security_*.log {' >> /etc/logrotate.d/nginx
    printf '%s\n' '    daily' >> /etc/logrotate.d/nginx
    printf '%s\n' '    missingok' >> /etc/logrotate.d/nginx
    printf '%s\n' '    rotate 90' >> /etc/logrotate.d/nginx
    printf '%s\n' '    compress' >> /etc/logrotate.d/nginx
    printf '%s\n' '    delaycompress' >> /etc/logrotate.d/nginx
    printf '%s\n' '    notifempty' >> /etc/logrotate.d/nginx
    printf '%s\n' '    create 0640 root adm' >> /etc/logrotate.d/nginx
    printf '%s\n' '}' >> /etc/logrotate.d/nginx
    printf '%s\n' '' >> /etc/logrotate.d/nginx
    printf '%s\n' '/var/log/nginx/performance.log {' >> /etc/logrotate.d/nginx
    printf '%s\n' '    daily' >> /etc/logrotate.d/nginx
    printf '%s\n' '    missingok' >> /etc/logrotate.d/nginx
    printf '%s\n' '    rotate 30' >> /etc/logrotate.d/nginx
    printf '%s\n' '    compress' >> /etc/logrotate.d/nginx
    printf '%s\n' '    delaycompress' >> /etc/logrotate.d/nginx
    printf '%s\n' '    notifempty' >> /etc/logrotate.d/nginx
    printf '%s\n' '    create 0640 root adm' >> /etc/logrotate.d/nginx
    printf '%s\n' '}' >> /etc/logrotate.d/nginx

    if [ ! -f /etc/logrotate.d/nginx ]; then
        print_error "Failed to create logrotate configuration file"
        return 1
    fi
    print_info "Configuration file created"

    # Set proper permissions on log directory
    chmod 755 /var/log/nginx 2>/dev/null || true

    # Create empty log files if they don't exist
    print_info "Creating log files..."
    touch /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || true
    touch /var/log/nginx/security_alerts.log /var/log/nginx/performance.log 2>/dev/null || true

    # Set proper permissions on log files
    chmod 600 /var/log/nginx/security_alerts.log 2>/dev/null || true
    chmod 640 /var/log/nginx/*.log 2>/dev/null || true
    
    # Set ownership for unprivileged Nginx (UID 101) if in Docker
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
        chown -R 101:101 /var/log/nginx 2>/dev/null || true
        print_info "Log files ownership set to UID 101 for Docker Nginx"
    else
        chown root:root /var/log/nginx/security_alerts.log 2>/dev/null || true
        chown root:adm /var/log/nginx/*.log 2>/dev/null || true
    fi
    print_info "Log files created and permissions set"

    # Test logrotate configuration (use || true to prevent script exit due to set -e)
    print_info "Testing logrotate configuration..."
    local test_output
    test_output=$(logrotate -d /etc/logrotate.d/nginx 2>&1) || true
    local test_result=$?

    if [ $test_result -eq 0 ]; then
        print_success "Log rotation configured successfully."
        print_info "Log files will be rotated daily."
        print_info "Configuration file: /etc/logrotate.d/nginx"
        log "Nginx log rotation setup completed" 2>/dev/null || true
        return 0
    else
        print_error "Logrotate configuration has errors (exit code: $test_result)."
        print_info "Configuration created at: /etc/logrotate.d/nginx"
        if [ -n "$test_output" ]; then
            print_info "Test output:"
            echo "$test_output" | head -20
        fi
        print_info "You can test manually with: logrotate -d /etc/logrotate.d/nginx"
        # Return 0 to avoid script exit due to set -e, configuration is still usable
        return 0
    fi
}

# --- Setup Security Dashboard ---
setup_security_dashboard() {
    print_info "Creating security dashboard..."

    # Create necessary directories
    mkdir -p /opt/nginx/dashboard
    mkdir -p /opt/nginx/scripts
    mkdir -p /opt/nginx/conf.d
    mkdir -p /var/log/nginx

    # Create HTML dashboard
    cat > /opt/nginx/dashboard/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Nginx Security Dashboard</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; }
        .header { background: #2c3e50; color: white; padding: 20px; text-align: center; }
        .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin: 20px 0; }
        .metric { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .metric h3 { margin: 0 0 10px 0; color: #2c3e50; }
        .metric-value { font-size: 2em; font-weight: bold; color: #3498db; }
        .chart-container { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin: 20px 0; max-height: 400px; }
        .chart-container canvas { max-height: 300px; }
        .status-good { color: #27ae60; }
        .status-warning { color: #f39c12; }
        .status-danger { color: #e74c3c; }
        .refresh { position: fixed; top: 20px; right: 20px; background: #3498db; color: white; padding: 10px 20px; border: none; border-radius: 5px; cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Nginx Security Dashboard</h1>
            <p>Real-time monitoring and security metrics</p>
        </div>

        <button class="refresh" onclick="location.reload()">Refresh</button>

        <div class="metrics">
            <div class="metric">
                <h3>Direct Connections</h3>
                <div class="metric-value" id="active-connections">-</div>
                <small>Active TCP/HTTP streams</small>
            </div>
            <div class="metric">
                <h3>Unique Visitors (1h)</h3>
                <div class="metric-value" id="unique-visitors">-</div>
                <small>Distinct IP addresses</small>
            </div>
            <div class="metric">
                <h3>Banned IPs</h3>
                <div class="metric-value" id="banned-ips">-</div>
                <small>Blocked by Fail2ban</small>
            </div>
            <div class="metric">
                <h3>Security Alerts</h3>
                <div class="metric-value" id="security-events">-</div>
                <small>Suspicious patterns detected</small>
            </div>
        </div>

        <div class="chart-container">
            <h3>Request Trends (Last Hour)</h3>
            <canvas id="requestChart"></canvas>
        </div>

        <div class="chart-container">
            <h3>HTTP Status Codes</h3>
            <canvas id="statusChart"></canvas>
        </div>

        <div class="chart-container">
            <h3>Security Event Breakdown</h3>
            <div id="threat-list" style="margin-top: 10px;">
                <p style="color: #666; font-style: italic;">No specific threats categorized yet...</p>
            </div>
        </div>

        <div class="chart-container">
            <h3>Top Attack Sources</h3>
            <canvas id="attackChart"></canvas>
        </div>
    </div>

    <script>
        // Global chart instances
        let requestChart, statusChart, attackChart;

        // Fetch data from API endpoints
        async function fetchMetrics() {
            console.log("Fetching metrics...");
            try {
                const response = await fetch('/api/metrics');
                console.log("Response status:", response.status);
                if (!response.ok) throw new Error('API response not OK: ' + response.status);
                const data = await response.json();
                console.log("Data received:", data);

                // Update summary metrics
                if (data.nginx_status) {
                    document.getElementById('active-connections').textContent = 
                        data.nginx_status.active_connections || '0';
                    document.getElementById('unique-visitors').textContent = 
                        data.nginx_status.unique_visitors || '0';
                }

                if (data.fail2ban_status) {
                    document.getElementById('banned-ips').textContent = 
                        data.fail2ban_status.currently_banned || '0';
                }

                if (data.security_events) {
                    document.getElementById('security-events').textContent = 
                        data.security_events.total_detections || '0';
                }

                // Update Request Trends Chart
                if (data.request_trends && requestChart) {
                    requestChart.data.datasets[0].data = data.request_trends.values;
                    requestChart.data.labels = data.request_trends.labels;
                    requestChart.update();
                }

                // Update Status Codes Chart
                if (data.status_distribution && statusChart) {
                    statusChart.data.datasets[0].data = [
                        data.status_distribution['2xx'] || 0,
                        data.status_distribution['3xx'] || 0,
                        data.status_distribution['4xx'] || 0,
                        data.status_distribution['5xx'] || 0,
                        data.status_distribution['Others'] || 0
                    ];
                    statusChart.update();
                }

                // Update Security Event Breakdown
                if (data.security_events && data.security_events.threat_breakdown) {
                    const breakdown = data.security_events.threat_breakdown;
                    const container = document.getElementById('threat-list');
                    
                    const descriptions = {
                        'SQL Injection': 'Attempts to execute malicious SQL statements to steal or manipulate data.',
                        'XSS/Injection': 'Attempts to inject malicious scripts into web pages viewed by other users.',
                        'Path Traversal': 'Attempts to access files and directories stored outside the web root.',
                        'Brute Force/Admin': 'Automated attempts to guess passwords or access admin interfaces.',
                        'Exploit/Execution': 'Attempts to execute arbitrary code or system commands on the server.',
                        'Scan/Probing': 'Automated tools searching for vulnerabilities or sensitive files.',
                        'Alert Log Entry': 'Security events captured by dedicated logs (e.g., Fail2ban).'
                    };

                    if (Object.keys(breakdown).length > 0) {
                        let html = '<table style="width: 100%; border-collapse: collapse;">';
                        for (const [type, count] of Object.entries(breakdown)) {
                            if (count > 0) {
                                const desc = descriptions[type] || 'Suspicious activity pattern detected.';
                                html += `<tr style="border-bottom: 1px solid #eee;" title="${desc}">
                                    <td style="padding: 8px 0; color: #e74c3c; font-weight: bold; cursor: help;">${type}</td>
                                    <td style="padding: 8px 0; text-align: right;">${count} detections</td>
                                </tr>`;
                            }
                        }
                        html += '</table>';
                        container.innerHTML = html;
                    }
                }

                // Update Attack Sources Chart
                if (data.top_attacks && attackChart) {
                    attackChart.data.labels = data.top_attacks.map(a => a.ip);
                    attackChart.data.datasets[0].data = data.top_attacks.map(a => a.count);
                    attackChart.update();
                }

            } catch (error) {
                console.error('Error fetching metrics:', error);
            }
        }

        // Initialize charts
        function initCharts() {
            if (typeof Chart === 'undefined') {
                console.warn("Chart.js not loaded. Charts will not be initialized.");
                return;
            }

            try {
                // Request trends chart
                const requestCtx = document.getElementById('requestChart').getContext('2d');
                requestChart = new Chart(requestCtx, {
                    type: 'line',
                    data: {
                        labels: [],
                        datasets: [{
                            label: 'Requests/min',
                            data: [],
                            borderColor: '#3498db',
                            backgroundColor: 'rgba(52, 152, 219, 0.1)',
                            tension: 0.4,
                            fill: true
                        }]
                    },
                    options: {
                        responsive: true,
                        scales: { y: { beginAtZero: true } },
                        animation: { duration: 0 }
                    }
                });

                // Status codes chart
                const statusCtx = document.getElementById('statusChart').getContext('2d');
                statusChart = new Chart(statusCtx, {
                    type: 'doughnut',
                    data: {
                        labels: ['2xx Success', '3xx Redirect', '4xx Client Error', '5xx Server Error', 'Others'],
                        datasets: [{
                            data: [0, 0, 0, 0, 0],
                            backgroundColor: ['#27ae60', '#3498db', '#f39c12', '#e74c3c', '#95a5a6']
                        }]
                    },
                    options: { 
                        responsive: true,
                        maintainAspectRatio: false
                    }
                });

                // Attack sources chart
                const attackCtx = document.getElementById('attackChart').getContext('2d');
                attackChart = new Chart(attackCtx, {
                    type: 'bar',
                    data: {
                        labels: [],
                        datasets: [{
                            label: 'Security Events',
                            data: [],
                            backgroundColor: '#e74c3c'
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        scales: { y: { beginAtZero: true } }
                    }
                });
            } catch (err) {
                console.error("Error initializing charts:", err);
            }
        }

        // Initialize and refresh
        document.addEventListener('DOMContentLoaded', () => {
            initCharts();
            fetchMetrics();
            setInterval(fetchMetrics, 30000); // Refresh every 30 seconds
        });
    </script>
</body>
</html>
EOF

    # Add dashboard configuration to Nginx
    cat > /opt/nginx/conf.d/dashboard.conf << 'EOF'
# Security dashboard
server {
    listen 8082;
    server_name _;

    # Restrict access to localhost and Docker bridge
    allow 127.0.0.1;
    allow ::1;
    allow 172.20.0.0/16;
    deny all;

    # Health check endpoint - MUST BE FIRST
    location /health {
        access_log off;
        allow all;  # Allow all IPs including Docker bridge network
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Serve dashboard
    location / {
        root /opt/nginx/dashboard;
        index index.html;
        # CSP to allow Chart.js CDN (required for dashboard)
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; img-src 'self' data: https:; font-src 'self' https://cdn.jsdelivr.net; connect-src 'self' https://cdn.jsdelivr.net; frame-ancestors 'self'; form-action 'self'; object-src 'none'; base-uri 'self';" always;
    }

    # API endpoints for metrics
    location /api/metrics {
        proxy_pass http://172.20.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        add_header Content-Type application/json;
    }

    location /api/security-events {
        proxy_pass http://172.20.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        add_header Content-Type application/json;
    }

    access_log off;
}
EOF

    # Create API script for real-time metrics
    cat > /opt/nginx/scripts/metrics_api.py << 'EOF'
#!/usr/bin/env python3

import json
import re
import subprocess
import sys
from datetime import datetime, timedelta

def get_nginx_status():
    """Parse nginx status from stub_status module or access logs"""
    try:
        # Try to get status from stub_status module first
        try:
            result = subprocess.run(['curl', '-s', 'http://localhost/nginx_status'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and 'Active connections' in result.stdout:
                lines = result.stdout.split('\n')
                active_connections = int(lines[0].split(':')[1].strip())
                accepts = int(lines[2].split()[0])
                handled = int(lines[2].split()[1])
                requests = int(lines[2].split()[2])

                return {
                    'active_connections': active_connections,
                    'requests_per_second': requests // 60 if requests > 0 else 0,
                    'total_requests': requests,
                    'timestamp': datetime.now().isoformat()
                }
        except:
            pass

        # Fallback to access log analysis
        with open('/var/log/nginx/access.log', 'r') as f:
            lines = f.readlines()

        # Calculate metrics from access log
        total_requests = len(lines)
        now = datetime.now()
        one_minute_ago = now - timedelta(minutes=1)

        recent_requests = 0
        for line in lines[-1000:]:
            try:
                timestamp_str = line.split()[3][1:]
                timestamp = datetime.strptime(timestamp_str, '%d/%b/%Y:%H:%M:%S')
                if timestamp > one_minute_ago:
                    recent_requests += 1
            except:
                continue

        return {
            'active_connections': recent_requests,
            'requests_per_second': recent_requests,
            'total_requests': total_requests,
            'timestamp': now.isoformat()
        }
    except Exception as e:
        return {'error': str(e)}

def get_fail2ban_status():
    """Get fail2ban statistics"""
    try:
        result = subprocess.run(['fail2ban-client', 'status', 'nginx-http-auth'],
                           capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            lines = result.stdout.split('\n')
            for line in lines:
                if 'Currently banned:' in line:
                    banned_count = int(line.split(':')[1].strip())
                    return {
                        'jail': 'nginx-http-auth',
                        'currently_banned': banned_count
                    }
    except:
        pass
    return {'jail': 'nginx-http-auth', 'currently_banned': 0}

def get_security_events():
    """Get security event count from alerts log"""
    try:
        alert_file = '/var/log/nginx/security_alerts.log'
        if not os.path.exists(alert_file):
            return {'event_count': 0}

        # Count events in last 24 hours
        now = datetime.now()
        one_day_ago = now - timedelta(days=1)

        event_count = 0
        with open(alert_file, 'r') as f:
            for line in f:
                try:
                    # Parse timestamp from log line
                    timestamp_str = line.split(')')[0].split('(')[1]
                    timestamp = datetime.strptime(timestamp_str, '%Y-%m-%d %H:%M:%S')
                    if timestamp > one_day_ago:
                        event_count += 1
                except:
                    continue

        return {'event_count': event_count}
    except:
        return {'event_count': 0}

if __name__ == '__main__':
    import os
    metrics = {
        'nginx_status': get_nginx_status(),
        'fail2ban_status': get_fail2ban_status(),
        'security_events': get_security_events()
    }
    print(json.dumps(metrics, indent=2))
EOF

    chmod +x /opt/nginx/scripts/metrics_api.py

    # Create Flask API server for metrics
    cat > /opt/nginx/scripts/metrics_server.py << 'EOF'
#!/usr/bin/env python3

from flask import Flask, jsonify
import subprocess
import os
import re
from datetime import datetime, timedelta
from collections import Counter

app = Flask(__name__)

# Detect best log paths
def find_log_path(filenames, fallback):
    for path in ['/opt/nginx/logs', '/var/log/nginx']:
        for f in filenames:
            full_path = os.path.join(path, f)
            if os.path.exists(full_path) and os.path.getsize(full_path) > 0:
                return full_path
    return fallback

ACCESS_LOG = find_log_path(['security.log', 'https_access.log', 'default_access.log', 'access.log'], '/var/log/nginx/access.log')
ERROR_LOG = find_log_path(['error.log', 'default_error.log'], '/var/log/nginx/error.log')
ALERTS_LOG = find_log_path(['security_alerts.log'], '/var/log/nginx/security_alerts.log')

def get_last_lines(filepath, num_lines=1000):
    """Efficiently read the last N lines of a file"""
    if not os.path.exists(filepath): return []
    try:
        with open(filepath, 'rb') as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            # Read last 2MB to find lines
            offset = min(size, 2048 * 1024)
            f.seek(size - offset)
            chunk = f.read().decode('utf-8', errors='ignore')
            return chunk.splitlines()[-num_lines:]
    except: return []

def get_nginx_status():
    """Parse nginx status from stub_status module or access logs"""
    status = {
        'active_connections': 0,
        'unique_visitors': 0,
        'total_requests': 0
    }
    
    # 1. Try stub_status
    try:
        result = subprocess.run(['curl', '-s', 'http://localhost/nginx_status'],
                              capture_output=True, text=True, timeout=2)
        if result.returncode == 0 and 'Active connections' in result.stdout:
            lines = result.stdout.split('\n')
            status['active_connections'] = int(lines[0].split(':')[1].strip())
            status['total_requests'] = int(lines[2].split()[2])
    except: pass

    # 2. Get unique visitors from last hour of access log
    try:
        lines = get_last_lines(ACCESS_LOG, 5000)
        ips = set()
        recent_count = 0
        if lines:
            # Use the latest timestamp in the log as 'now'
            latest_ts = None
            for line in reversed(lines):
                try:
                    match = re.search(r'\[(\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2})', line)
                    if match:
                        ts = datetime.strptime(match.group(1), '%d/%b/%Y:%H:%M:%S')
                        if not latest_ts: latest_ts = ts
                        
                        # Within last hour
                        if ts > (latest_ts - timedelta(hours=1)):
                            ip = line.split()[0]
                            ips.add(ip)
                        else: break
                except: continue
        
        status['unique_visitors'] = len(ips)
        if status['total_requests'] == 0: status['total_requests'] = len(lines)
    except: pass
    
    return status

def get_fail2ban_status():
    """Get fail2ban statistics"""
    try:
        result = subprocess.run(['fail2ban-client', 'status', 'nginx-http-auth'],
                           capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            match = re.search(r'Currently banned:\s+(\d+)', result.stdout)
            if match:
                return {'currently_banned': int(match.group(1))}
    except:
        pass
    return {'currently_banned': 0}

def get_security_events():
    """Get security event count from alerts log"""
    count = 0
    try:
        if os.path.exists(ALERTS_LOG):
            with open(ALERTS_LOG, 'r') as f:
                count = sum(1 for line in f)
    except:
        pass
    return {'event_count': count}

def get_request_trends():
    """Get request counts per minute for the last 60 minutes"""
    labels = []
    values = []
    try:
        if os.path.exists(ACCESS_LOG):
            # Read from the end of the file
            with open(ACCESS_LOG, 'rb') as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                offset = min(size, 2048 * 1024) # 2MB
                f.seek(size - offset)
                lines = f.read().decode('utf-8', errors='ignore').splitlines()
            
            counts = Counter()
            latest_ts = None
            
            for line in reversed(lines):
                try:
                    match = re.search(r'\[(\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2})', line)
                    if match:
                        ts_str = match.group(1)
                        ts = datetime.strptime(ts_str, '%d/%b/%Y:%H:%M:%S')
                        if not latest_ts: latest_ts = ts
                        counts[ts.strftime('%H:%M')] += 1
                except: continue
            
            if not latest_ts:
                latest_ts = datetime.now()

            for i in range(59, -1, -1):
                t = (latest_ts - timedelta(minutes=i)).strftime('%H:%M')
                labels.append(t)
                values.append(counts.get(t, 0))
    except Exception as e:
        print(f"Error in request trends: {e}")
    return {'labels': labels, 'values': values}

def get_status_distribution():
    """Aggregate HTTP status codes"""
    dist = Counter({'2xx': 0, '3xx': 0, '4xx': 0, '5xx': 0, 'Others': 0})
    try:
        lines = get_last_lines(ACCESS_LOG, 5000)
        
        for line in lines:
            try:
                # Robust parsing: split by quotes and get first item of 3rd segment
                parts = line.split('"')
                if len(parts) >= 3:
                    status_part = parts[2].strip().split()[0]
                    if status_part.startswith('2'): dist['2xx'] += 1
                    elif status_part.startswith('3'): dist['3xx'] += 1
                    elif status_part.startswith('4'): dist['4xx'] += 1
                    elif status_part.startswith('5'): dist['5xx'] += 1
                    else: dist['Others'] += 1
            except: continue
    except:
        pass
    return dict(dist)

def get_security_data():
    """Identify top suspicious IP addresses and categorize threats"""
    ips = Counter()
    threats = Counter()
    total_detections = 0
    
    # Categories mapping
    patterns = {
        'SQL Injection': re.compile(r'(union\s+select|select\s+.*\s+from|insert\s+into)', re.I),
        'XSS/Injection': re.compile(r'(script|<|%3c|%3e|>)', re.I),
        'Path Traversal': re.compile(r'(etc/passwd|/etc/|../|boot\.ini)', re.I),
        'Brute Force/Admin': re.compile(r'(wp-login|admin\.php|login\.php|wp-admin|xmlrpc)', re.I),
        'Exploit/Execution': re.compile(r'(cgi-bin|mindex|shell|cmd\.exe|powershell|\$\{)', re.I),
        'Scan/Probing': re.compile(r'(\.env|\.git|config|phpinfo|\.aws|\.ssh)', re.I)
    }

    try:
        # 1. Check dedicated alerts log (usually Fail2ban or ModSec)
        if os.path.exists(ALERTS_LOG) and os.path.getsize(ALERTS_LOG) > 0:
            with open(ALERTS_LOG, 'r') as f:
                for line in f:
                    total_detections += 1
                    threats['Alert Log Entry'] += 1
                    match = re.search(r'(\d{1,3}\.){3}\d{1,3}', line)
                    if match: ips[match.group(0)] += 1
        
        # 2. Hybrid: Scan access log for common patterns
        if os.path.exists(ACCESS_LOG):
            lines = get_last_lines(ACCESS_LOG, 2000)
            for line in lines:
                matched_any = False
                for name, prog in patterns.items():
                    if prog.search(line):
                        total_detections += 1
                        threats[name] += 1
                        matched_any = True
                
                if matched_any:
                    match = re.match(r'^(\d{1,3}\.){3}\d{1,3}', line)
                    if match: ips[match.group(0)] += 1
    except: pass
    
    return {
        'total_detections': total_detections,
        'threat_breakdown': dict(threats),
        'top_attacks': [{'ip': ip, 'count': count} for ip, count in ips.most_common(5)]
    }

@app.route('/api/metrics')
def metrics():
    """Return all metrics"""
    security = get_security_data()
    return jsonify({
        'nginx_status': get_nginx_status(),
        'fail2ban_status': get_fail2ban_status(),
        'security_events': security,
        'request_trends': get_request_trends(),
        'status_distribution': get_status_distribution(),
        'top_attacks': security['top_attacks']
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081, debug=False)
EOF

    chmod +x /opt/nginx/scripts/metrics_server.py

    # Create systemd service for metrics server
    cat > /etc/systemd/system/nginx-metrics-api.service << 'EOF'
[Unit]
Description=Nginx Metrics API Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/nginx/scripts/metrics_server.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Add port mapping to Docker Compose if not already present
    local RESTART_NEEDED=false
    if [[ -f /opt/nginx/docker-compose.yml ]]; then
        if ! grep -q "8080:8082" /opt/nginx/docker-compose.yml; then
            print_info "Patching /opt/nginx/docker-compose.yml with port 8080..."
            # Add port 8080:8082 mapping after the 443 mapping
            sed -i '/"443:8443"/a \      - "8080:8082"' /opt/nginx/docker-compose.yml
            RESTART_NEEDED=true
        fi
        if ! grep -q "./dashboard:/opt/nginx/dashboard:ro" /opt/nginx/docker-compose.yml; then
            print_info "Patching /opt/nginx/docker-compose.yml with dashboard volume..."
            # Add dashboard volume after html volume
            sed -i '/.\/html:\/usr\/share\/nginx\/html:ro/a \      - ./dashboard:/opt/nginx/dashboard:ro' /opt/nginx/docker-compose.yml
            RESTART_NEEDED=true
        fi
        
        if [[ "$RESTART_NEEDED" == "true" ]]; then
            # Restart container to apply changes
            print_info "Restarting Nginx container to apply configuration changes..."
            (cd /opt/nginx && run_docker_compose up -d --build)
        else
            print_info "Nginx container configuration is up to date."
        fi
    fi

    # Ensure SSH TCP Forwarding is enabled for tunneling
    print_info "Ensuring SSH TCP Forwarding is enabled..."
    local ssh_conf="/etc/ssh/sshd_config.d/99-hardening.conf"
    if [[ -f "$ssh_conf" ]]; then
        if grep -q "AllowTcpForwarding no" "$ssh_conf"; then
            print_info "Enabling AllowTcpForwarding in $ssh_conf..."
            sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/' "$ssh_conf"
            
            # Reload SSH service
            if systemctl is-active --quiet ssh.socket; then
                systemctl reload ssh.service 2>/dev/null || true
            else
                systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
            fi
            print_success "SSH TCP Forwarding enabled and service reloaded."
        fi
    fi

    # Install Python3 and Flask on host system if not present
    # The Flask API runs as a separate systemd service on the host to:
    # - Read log files from /var/log/nginx/ on the host
    # - Interact with system services like fail2ban
    # - Avoid modifying the Nginx container

    # Debug: Check what we have
    print_info "Checking Python3 and Flask availability..."
    if command -v python3 >/dev/null 2>&1; then
        print_info "Python3 found: $(python3 --version 2>&1)"
    else
        print_warning "Python3 not found"
    fi

    if python3 -c "import flask" 2>/dev/null; then
        print_info "Flask is already installed"
    else
        print_warning "Flask not found"
    fi

    # Check if running as root (required for package installation)
    if [[ $EUID -ne 0 ]]; then
        print_warning "Not running as root, skipping automatic Python/Flask installation"
        print_info "Run with sudo or as root to install dependencies automatically"
    else
        # Install Flask via system package manager (Debian/Ubuntu: python3-flask, RHEL/CentOS: python3-flask)
        if ! python3 -c "import flask" 2>/dev/null; then
            print_info "Installing Flask via system package manager..."

            if command -v apt-get >/dev/null 2>&1; then
                # Debian/Ubuntu: use python3-flask package
                if DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
                    if DEBIAN_FRONTEND=noninteractive apt-get install -y python3-flask >/dev/null 2>&1; then
                        print_success "Flask installed successfully via apt-get"
                    else
                        print_warning "Failed to install Flask via apt-get"
                        print_info "To install manually: apt-get install python3-flask"
                    fi
                else
                    print_warning "Failed to update package list"
                fi
            elif command -v yum >/dev/null 2>&1; then
                # RHEL/CentOS: use python3-flask package
                if yum install -y python3-flask >/dev/null 2>&1; then
                    print_success "Flask installed successfully via yum"
                else
                    print_warning "Failed to install Flask via yum"
                    print_info "To install manually: yum install python3-flask"
                fi
            else
                print_warning "Package manager not found, skipping Flask installation"
                print_info "To install manually: apt-get install python3-flask"
            fi
        fi
    fi

    # Detect variables for instructions if not already set
    local display_port="${SSH_PORT}"
    if [[ -z "$display_port" ]]; then
        if command -v ss >/dev/null 2>&1; then
            display_port=$(ss -tlpn 2>/dev/null | grep sshd | head -n 1 | grep -o ':[0-9]*' | sed 's/://' | head -n 1 || echo "")
        fi
        if [[ -z "$display_port" ]] && [[ -f /etc/ssh/sshd_config ]]; then
            display_port=$(grep -E "^Port\s+[0-9]+" /etc/ssh/sshd_config | grep -oP "\d+" | head -n 1 || echo "")
        fi
        display_port=${display_port:-22}
    fi

    local display_ip="${SERVER_IP_V4}"
    if [[ -z "$display_ip" || "$display_ip" == "unknown" ]]; then
        display_ip=$(curl -4 -s --connect-timeout 2 https://ifconfig.me 2>/dev/null || echo "your-server-ip")
    fi

    local display_user="${USERNAME}"
    if [[ -z "$display_user" ]]; then
        display_user=${SUDO_USER:-$(whoami)}
    fi

    local display_auth_keys_path
    if [[ "$display_user" == "root" ]]; then
        display_auth_keys_path="/root/.ssh/authorized_keys"
    else
        display_auth_keys_path="/home/${display_user}/.ssh/authorized_keys"
    fi

    # Enable and start the service (with error handling)
    if systemctl daemon-reload 2>/dev/null; then
        if systemctl enable nginx-metrics-api 2>/dev/null; then
            if systemctl restart nginx-metrics-api 2>/dev/null; then
                print_success "Security dashboard created."
                print_info "Dashboard URL: http://localhost:8080"
                print_info "Metrics API: http://localhost:8081"
                print_info "Access is restricted to localhost only for security."
                
                print_section "How to Access the Dashboard"
                print_info "1. FROM SERVER TERMINAL (Text-only):"
                print_info "   curl http://localhost:8080"
                echo
                print_info "2. FROM YOUR LOCAL COMPUTER (Web Browser):"
                print_info "   Use an SSH tunnel to securely view the graphical dashboard."
                print_info "   (Note: If using PowerShell, you may need to specify your private key with -i)"
                echo
                print_info "   ssh -L 8080:localhost:8080 -L 8081:localhost:8081 -p ${display_port} -i <path_to_private_key> ${display_user}@${display_ip}"
                print_info "   Example: ssh -L 8080:localhost:8080 -L 8081:localhost:8081 -p ${display_port} -i C:\\Users\\Name\\.ssh\\id_rsa ${display_user}@${display_ip}"
                print_info "   Then open in your local browser: http://localhost:8080"
                echo
                print_info "TROUBLESHOOTING SSH (Permission Denied):"
                print_info "   - If you use PuTTY, it uses .ppk files. PowerShell's 'ssh' needs an OpenSSH key."
                print_info "   - Ensure your local public key is added to this file on the server."
                print_info "     ${display_auth_keys_path}"
                print_info "   - If Windows says 'UNPROTECTED PRIVATE KEY FILE', use the icacls commands provided."
                print_info "     icacls \"C:\\path\\to\\key\" /inheritance:r"
                print_info "     icacls \"C:\\path\\to\\key\" /grant:r \"\$(\$env:USERNAME):R\""
                print_info "   - Use the -i flag in PowerShell to point exactly to your private key file."
                print_info "   - If the tunnel fails with 'administratively prohibited', ensure that"
                print_info "     'AllowTcpForwarding yes' is set in /etc/ssh/sshd_config.d/99-hardening.conf"
                print_info "     (The script now handles this automatically on reruns)."
            else
                print_warning "Failed to start nginx-metrics-api service"
            fi
        else
            print_warning "Failed to enable nginx-metrics-api service"
        fi
    else
        print_warning "Failed to reload systemd daemon"
    fi

    # Automate firewall configuration for Docker-to-Host API access
    if command -v ufw >/dev/null 2>&1; then
        print_info "Configuring firewall for Docker-to-Host API communication..."
        if ! ufw status | grep -q "8081.*docker0"; then
            ufw allow in on docker0 to any port 8081 comment 'Allow Nginx container to host API' >/dev/null 2>&1
            print_success "Firewall rule added: Allow 8081 on docker0"
        else
            print_info "Firewall rule for port 8081 on docker0 already exists."
        fi
    fi

    # Log completion (with error handling)
    log "Nginx security dashboard setup completed" 2>/dev/null || true
}

# --- Setup Performance Monitoring ---
setup_performance_monitoring() {
    print_info "Setting up performance monitoring..."

    # Create performance monitoring script
    cat > /opt/nginx/scripts/perf_monitor.sh << 'EOF'
#!/bin/bash

# Nginx performance monitoring script
LOG_FILE="/var/log/nginx/performance.log"

# Load configuration
if [[ -f /etc/nginx-monitoring.conf ]]; then
    source /etc/nginx-monitoring.conf
else
    CPU_THRESHOLD=80
    MEMORY_THRESHOLD=80
    ERROR_RATE_THRESHOLD=5
    RESPONSE_TIME_THRESHOLD=1.0
fi

# Graceful shutdown handler
shutdown_handler() {
    echo "$(date): Performance monitoring shutting down gracefully" >> "$LOG_FILE"
    exit 0
}

# Set trap for signals
trap shutdown_handler SIGTERM SIGINT

# Function to get container stats
get_container_stats() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        # System nginx - get process stats
        local pid=$(pgrep -o nginx)
        if [[ -n "$pid" ]]; then
            local cpu=$(ps -p "$pid" -o %cpu --no-headers | tr -d ' ')
            local mem=$(ps -p "$pid" -o %mem --no-headers | tr -d ' ')
            echo "${cpu}%\t${mem}%\t${mem}%"
        fi
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^nginx$"; then
        # Docker nginx
        docker stats nginx --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" | tail -n +2
    fi
}

# Function to check response time
check_response_time() {
    local url="http://localhost:8080/health"
    local response_time=$(curl -o /dev/null -s -w '%{time_total}' "$url" 2>/dev/null)

    if [[ -n "$response_time" ]]; then
        if (( $(echo "$response_time > $RESPONSE_TIME_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
            echo "$(date): Slow response time detected: ${response_time}s" >> "$LOG_FILE"
        fi
        echo "$response_time"
    else
        echo "0"
    fi
}

# Function to check error rate
check_error_rate() {
    local access_log="/var/log/nginx/access.log"
    if [[ ! -f "$access_log" ]]; then
        echo "0"
        return
    fi

    local total_requests=$(wc -l < "$access_log")
    local error_requests=$(awk '($9 >= 400) { count++ } END { print count+0 }' "$access_log")

    if [[ $total_requests -gt 0 ]]; then
        local error_rate=$(( error_requests * 100 / total_requests ))
        if [[ $error_rate -gt $ERROR_RATE_THRESHOLD ]]; then
            echo "$(date): High error rate: ${error_rate}%" >> "$LOG_FILE"
        fi
        echo "$error_rate"
    else
        echo "0"
    fi
}

# Main monitoring loop
monitor_performance() {
    echo "$(date): Starting performance monitoring" >> "$LOG_FILE"

    while true; do
        # Get container stats
        stats=$(get_container_stats)
        if [[ -n "$stats" ]]; then
            cpu_percent=$(echo "$stats" | awk '{print $1}' | sed 's/%//')
            memory_percent=$(echo "$stats" | awk '{print $3}' | sed 's/%//')

            # Check CPU usage
            if [[ -n "$cpu_percent" ]] && (( $(echo "$cpu_percent > $CPU_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
                echo "$(date): High CPU usage: ${cpu_percent}%" >> "$LOG_FILE"
            fi

            # Check memory usage
            if [[ -n "$memory_percent" ]] && (( $(echo "$memory_percent > $MEMORY_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
                echo "$(date): High memory usage: ${memory_percent}%" >> "$LOG_FILE"
            fi
        fi

        # Check response time
        response_time=$(check_response_time)

        # Check error rate
        error_rate=$(check_error_rate)

        # Log metrics
        echo "$(date): CPU=${cpu_percent:-N/A}%, MEM=${memory_percent:-N/A}%, Response=${response_time}s, Error_Rate=${error_rate}%" >> "$LOG_FILE"

        sleep 30
    done
}

# Start monitoring
monitor_performance
EOF

    chmod +x /opt/nginx/scripts/perf_monitor.sh

    # Create systemd service for performance monitoring
    cat > /etc/systemd/system/nginx-perf-monitor.service << 'EOF'
[Unit]
Description=Nginx Performance Monitor
After=network.target

# Optional dependency on Docker if using containerized Nginx
Wants=docker.service
After=docker.service

[Service]
Type=simple
User=root
ExecStart=/opt/nginx/scripts/perf_monitor.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start the service
    systemctl daemon-reload
    systemctl enable nginx-perf-monitor
    systemctl start nginx-perf-monitor

    print_success "Performance monitoring agent (host-based) started."
    print_info "This agent monitors both host-based and Docker Nginx instances."
    print_info "Performance logs: /var/log/nginx/performance.log"
    print_info "Service status: systemctl status nginx-perf-monitor"
    log "Nginx performance monitoring setup completed" 2>/dev/null || true
}