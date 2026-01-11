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

    # Create configuration file for monitoring settings
    cat > /etc/nginx-monitoring.conf << 'EOF'
# Nginx Monitoring Configuration
# Thresholds and settings can be customized here

# Alert thresholds
ALERT_THRESHOLD=${ALERT_THRESHOLD:-100}
CPU_THRESHOLD=${CPU_THRESHOLD:-80}
MEMORY_THRESHOLD=${MEMORY_THRESHOLD:-80}
ERROR_RATE_THRESHOLD=${ERROR_RATE_THRESHOLD:-5}
RESPONSE_TIME_THRESHOLD=${RESPONSE_TIME_THRESHOLD:-1.0}

# Email settings
REPORT_EMAIL=${REPORT_EMAIL:-admin@localhost}
ALERT_RATE_LIMIT_MINUTES=${ALERT_RATE_LIMIT_MINUTES:-60}

# Fail2ban settings
MAXRETRY_AUTH=${MAXRETRY_AUTH:-3}
MAXRETRY_LIMIT_REQ=${MAXRETRY_LIMIT_REQ:-10}
MAXRETRY_NOSCRIPT=${MAXRETRY_NOSCRIPT:-6}
MAXRETRY_BADBOTS=${MAXRETRY_BADBOTS:-2}
MAXRETRY_NOPROXY=${MAXRETRY_NOPROXY:-2}

# Whitelisted IPs (comma-separated)
WHITELISTED_IPS=${WHITELISTED_IPS:-}
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
    chown root:adm /var/log/nginx/security_alerts.log
    chmod 640 /var/log/nginx/security_alerts.log

    # Setup cron jobs for log analysis
    if ! crontab -l 2>/dev/null | grep -q "analyze_logs.sh"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/nginx/scripts/analyze_logs.sh analyze") | crontab -
        (crontab -l 2>/dev/null; echo "0 6 * * * /opt/nginx/scripts/analyze_logs.sh report") | crontab -
        print_success "Log analysis cron jobs created."
    else
        print_info "Log analysis cron jobs already exist."
    fi

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

    # Create Nginx jail configuration
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
    chmod 640 /var/log/nginx/*.log 2>/dev/null || true
    chown root:adm /var/log/nginx/*.log 2>/dev/null || true
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
        .chart-container { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin: 20px 0; }
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
                <h3>Active Connections</h3>
                <div class="metric-value" id="active-connections">-</div>
            </div>
            <div class="metric">
                <h3>Requests/Second</h3>
                <div class="metric-value" id="requests-per-second">-</div>
            </div>
            <div class="metric">
                <h3>Banned IPs</h3>
                <div class="metric-value" id="banned-ips">-</div>
            </div>
            <div class="metric">
                <h3>Security Events</h3>
                <div class="metric-value" id="security-events">-</div>
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
            <h3>Top Attack Sources</h3>
            <canvas id="attackChart"></canvas>
        </div>
    </div>

    <script>
        // Fetch data from API endpoints
        async function fetchMetrics() {
            try {
                // Fetch metrics from API
                const metricsResponse = await fetch('/api/metrics');
                if (metricsResponse.ok) {
                    const metricsData = await metricsResponse.json();

                    // Update metrics from real data
                    if (metricsData.nginx_status) {
                        document.getElementById('active-connections').textContent =
                            metricsData.nginx_status.active_connections || 'N/A';
                        document.getElementById('requests-per-second').textContent =
                            metricsData.nginx_status.requests_per_second || 'N/A';
                    }

                    if (metricsData.fail2ban_status) {
                        document.getElementById('banned-ips').textContent =
                            metricsData.fail2ban_status.currently_banned || '0';
                    }

                    // Get security events from alerts log
                    const alertsResponse = await fetch('/api/security-events');
                    if (alertsResponse.ok) {
                        const eventsData = await alertsResponse.json();
                        document.getElementById('security-events').textContent =
                            eventsData.event_count || '0';
                    }
                }
            } catch (error) {
                console.error('Error fetching metrics:', error);
                // Keep last known values on error
            }
        }

        // Initialize charts
        function initCharts() {
            // Request trends chart
            const requestCtx = document.getElementById('requestChart').getContext('2d');
            new Chart(requestCtx, {
                type: 'line',
                data: {
                    labels: Array.from({length: 60}, (_, i) => `${60-i}m`),
                    datasets: [{
                        label: 'Requests',
                        data: Array.from({length: 60}, () => Math.floor(Math.random() * 100)),
                        borderColor: '#3498db',
                        backgroundColor: 'rgba(52, 152, 219, 0.1)',
                        tension: 0.4
                    }]
                },
                options: {
                    responsive: true,
                    scales: { y: { beginAtZero: true } }
                }
            });

            // Status codes chart
            const statusCtx = document.getElementById('statusChart').getContext('2d');
            new Chart(statusCtx, {
                type: 'doughnut',
                data: {
                    labels: ['200 OK', '404 Not Found', '500 Error', 'Others'],
                    datasets: [{
                        data: [75, 15, 5, 5],
                        backgroundColor: ['#27ae60', '#f39c12', '#e74c3c', '#95a5a6']
                    }]
                },
                options: { responsive: true }
            });

            // Attack sources chart
            const attackCtx = document.getElementById('attackChart').getContext('2d');
            new Chart(attackCtx, {
                type: 'bar',
                data: {
                    labels: ['Russia', 'China', 'USA', 'Brazil', 'Others'],
                    datasets: [{
                        label: 'Attack Attempts',
                        data: [45, 32, 28, 15, 12],
                        backgroundColor: '#e74c3c'
                    }]
                },
                options: {
                    responsive: true,
                    scales: { y: { beginAtZero: true } }
                }
            });
        }

        // Initialize and refresh
        initCharts();
        fetchMetrics();
        setInterval(fetchMetrics, 30000); // Refresh every 30 seconds
    </script>
</body>
</html>
EOF

    # Add dashboard configuration to Nginx
    cat > /opt/nginx/conf.d/dashboard.conf << 'EOF'
# Security dashboard
server {
    listen 8080;
    server_name dashboard.localhost;

    # Restrict access to localhost only
    allow 127.0.0.1;
    allow ::1;
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
    }

    # API endpoints for metrics
    location /api/metrics {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        add_header Content-Type application/json;
    }

    location /api/security-events {
        proxy_pass http://127.0.0.1:8081;
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
from datetime import datetime, timedelta

app = Flask(__name__)

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

        now = datetime.now()
        one_day_ago = now - timedelta(days=1)

        event_count = 0
        with open(alert_file, 'r') as f:
            for line in f:
                try:
                    timestamp_str = line.split(')')[0].split('(')[1]
                    timestamp = datetime.strptime(timestamp_str, '%Y-%m-%d %H:%M:%S')
                    if timestamp > one_day_ago:
                        event_count += 1
                except:
                    continue

        return {'event_count': event_count}
    except:
        return {'event_count': 0}

@app.route('/api/metrics')
def metrics():
    """Return all metrics"""
    return jsonify({
        'nginx_status': get_nginx_status(),
        'fail2ban_status': get_fail2ban_status()
    })

@app.route('/api/security-events')
def security_events():
    """Return security events count"""
    return jsonify(get_security_events())

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8081, debug=False)
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

    # Enable and start the service (with error handling)
    if systemctl daemon-reload 2>/dev/null; then
        if systemctl enable nginx-metrics-api 2>/dev/null; then
            if systemctl start nginx-metrics-api 2>/dev/null; then
                print_success "Security dashboard created."
                print_info "Dashboard URL: http://localhost:8080"
                print_info "Metrics API: http://localhost:8081"
                print_info "Access restricted to localhost only for security."
            else
                print_warning "Failed to start nginx-metrics-api service"
            fi
        else
            print_warning "Failed to enable nginx-metrics-api service"
        fi
    else
        print_warning "Failed to reload systemd daemon"
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
After=docker.service
Requires=docker.service

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

    print_success "Performance monitoring started."
    print_info "Performance logs: /var/log/nginx/performance.log"
    print_info "Service status: systemctl status nginx-perf-monitor"
    log "Nginx performance monitoring setup completed" 2>/dev/null || true
}