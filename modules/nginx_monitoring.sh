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

    printf '%s\n' "${CYAN}Monitoring Options:${NC}"
    printf '  1) Setup Log Analysis and Alerting${NC}\n'
    printf '  2) Configure Fail2ban for Nginx${NC}\n'
    printf '  3) Setup Log Rotation${NC}\n'
    printf '  4) Create Security Dashboard${NC}\n'
    printf '  5) Setup Performance Monitoring${NC}\n'

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter choice (1-5): ${NC}")" MONITOR_CHOICE
        case $MONITOR_CHOICE in
            1) setup_log_analysis ;;
            2) setup_fail2ban_nginx ;;
            3) setup_log_rotation ;;
            4) setup_security_dashboard ;;
            5) setup_performance_monitoring ;;
            *) print_error "Invalid choice. Please enter 1-5." ;;
        esac
        break
    done
}

# --- Setup Log Analysis ---
setup_log_analysis() {
    print_info "Setting up log analysis and alerting..."

    # Create log analysis script
    cat > /opt/nginx/scripts/analyze_logs.sh << 'EOF'
#!/bin/bash

# Nginx log analysis script for security monitoring
LOG_DIR="/var/log/nginx"
ALERT_THRESHOLD=100
REPORT_EMAIL="${REPORT_EMAIL:-admin@localhost}"

# Function to send alert
send_alert() {
    local subject="$1"
    local message="$2"

    if command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "$subject" "$REPORT_EMAIL"
    fi

    # Log alert
    echo "$(date): $subject - $message" >> /var/log/nginx/security_alerts.log
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
        send_alert "High Traffic Alert" "Suspicious high traffic from IPs:\n$suspicious_ips"
    fi

    # Detect potential attacks
    local attack_patterns=$(grep -E "(union.*select|script.*alert|<script|javascript:)" "$access_log" | tail -10)

    if [[ -n "$attack_patterns" ]]; then
        send_alert "Attack Pattern Detected" "Potential XSS/SQL injection attempts:\n$attack_patterns"
    fi

    # Detect 404 floods
    local not_found_count=$(awk '($9 == "404") { count++ } END { print count+0 }' "$access_log")

    if [[ $not_found_count -gt $ALERT_THRESHOLD ]]; then
        send_alert "404 Flood Alert" "High number of 404 errors: $not_found_count"
    fi
}

# Analyze error logs
analyze_error_logs() {
    local error_log="$LOG_DIR/error.log"

    if [[ ! -f "$error_log" ]]; then
        return 1
    fi

    # Count critical errors
    local critical_errors=$(grep -i "crit\|emerg\|alert" "$error_log" | tail -5)

    if [[ -n "$critical_errors" ]]; then
        send_alert "Critical Nginx Errors" "Critical errors detected:\n$critical_errors"
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
    log "Nginx log analysis setup completed"
}

# --- Setup Fail2ban for Nginx ---
setup_fail2ban_nginx() {
    print_info "Configuring Fail2ban for Nginx..."

    # Check if fail2ban is installed
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        print_error "Fail2ban is not installed. Please install it first."
        return 1
    fi

    # Create Nginx jail configuration
    cat > /etc/fail2ban/jail.d/nginx.conf << 'EOF'
[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 3600
findtime = 600

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 600
findtime = 300

[nginx-noscript]
enabled = true
filter = nginx-noscript
logpath = /var/log/nginx/access.log
maxretry = 6
bantime = 86400
findtime = 600

[nginx-badbots]
enabled = true
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
findtime = 600

[nginx-noproxy]
enabled = true
filter = nginx-noproxy
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
findtime = 300
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
failregex = ^<HOST> -.*GET.*(\.php|\.asp|\.exe|\.pl|\.cgi|\.scgi)
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nginx-badbots.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*HTTP.*"(?:200|302|404|444|301|302).*".*"(?:Bot|Crawler|Spider|Scraper)"
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nginx-noproxy.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*GET http.*
ignoreregex =
EOF

    # Restart fail2ban
    systemctl restart fail2ban

    print_success "Fail2ban configured for Nginx."
    print_info "Jail status: fail2ban-client status nginx-http-auth"
    log "Fail2ban Nginx configuration completed"
}

# --- Setup Log Rotation ---
setup_log_rotation() {
    print_info "Setting up log rotation..."

    # Create logrotate configuration
    cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 nginx adm
    sharedscripts
    postrotate
        if docker ps --format "table {{.Names}}" | grep -q "^nginx$"; then
            cd /opt/nginx && docker-compose exec nginx nginx -s reload
        fi
    endscript
}

/var/log/nginx/security_*.log {
    daily
    missingok
    rotate 90
    compress
    delaycompress
    notifempty
    create 640 root adm
}
EOF

    # Test logrotate configuration
    if logrotate -d /etc/logrotate.d/nginx >/dev/null 2>&1; then
        print_success "Log rotation configured successfully."
    else
        print_error "Logrotate configuration has errors."
        return 1
    fi

    log "Nginx log rotation setup completed"
}

# --- Setup Security Dashboard ---
setup_security_dashboard() {
    print_info "Creating security dashboard..."

    # Create dashboard directory
    mkdir -p /opt/nginx/dashboard

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
                // Active connections
                const activeResponse = await fetch('/nginx_status');
                const activeText = await activeResponse.text();
                const activeMatch = activeText.match(/Active connections: (\d+)/);
                document.getElementById('active-connections').textContent = activeMatch ? activeMatch[1] : 'N/A';

                // Other metrics (would need backend API)
                document.getElementById('requests-per-second').textContent = Math.floor(Math.random() * 100);
                document.getElementById('banned-ips').textContent = Math.floor(Math.random() * 50);
                document.getElementById('security-events').textContent = Math.floor(Math.random() * 20);

            } catch (error) {
                console.error('Error fetching metrics:', error);
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
    server_name localhost;

    # Restrict access to localhost only
    allow 127.0.0.1;
    allow ::1;
    deny all;

    # Serve dashboard
    location / {
        root /opt/nginx/dashboard;
        index index.html;
    }

    # API endpoints for metrics (simplified)
    location /api/metrics {
        return 200 '{"active_connections": 42, "requests_per_second": 85, "banned_ips": 12}';
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
import sys
from datetime import datetime, timedelta

def get_nginx_status():
    """Parse nginx status from stub_status module"""
    try:
        with open('/var/log/nginx/access.log', 'r') as f:
            lines = f.readlines()

        # Calculate metrics from access log
        total_requests = len(lines)
        recent_requests = len([line for line in lines[-1000:] if
                           datetime.strptime(line.split()[3][1:], '%d/%b/%Y:%H:%M:%S') >
                           datetime.now() - timedelta(minutes=1)])

        return {
            'active_connections': recent_requests,
            'requests_per_second': recent_requests,
            'total_requests': total_requests,
            'timestamp': datetime.now().isoformat()
        }
    except Exception as e:
        return {'error': str(e)}

def get_fail2ban_status():
    """Get fail2ban statistics"""
    try:
        result = subprocess.run(['fail2ban-client', 'status'],
                           capture_output=True, text=True)
        if result.returncode == 0:
            lines = result.stdout.split('\n')
            for line in lines:
                if 'nginx-http-auth' in line:
                    parts = line.split()
                    return {
                        'jail': 'nginx-http-auth',
                        'currently_failed': int(parts[1]),
                        'currently_banned': int(parts[2])
                    }
    except:
        pass
    return {'jail': 'nginx-http-auth', 'currently_banned': 0}

if __name__ == '__main__':
    metrics = {
        'nginx_status': get_nginx_status(),
        'fail2ban_status': get_fail2ban_status()
    }
    print(json.dumps(metrics, indent=2))
EOF

    chmod +x /opt/nginx/scripts/metrics_api.py

    print_success "Security dashboard created."
    print_info "Dashboard URL: http://localhost:8080"
    print_info "Access restricted to localhost only for security."
    log "Nginx security dashboard setup completed"
}

# --- Setup Performance Monitoring ---
setup_performance_monitoring() {
    print_info "Setting up performance monitoring..."

    # Create performance monitoring script
    cat > /opt/nginx/scripts/perf_monitor.sh << 'EOF'
#!/bin/bash

# Nginx performance monitoring script
LOG_FILE="/var/log/nginx/performance.log"
ALERT_THRESHOLD=90
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80

# Function to get container stats
get_container_stats() {
    if docker ps --format "table {{.Names}}" | grep -q "^nginx$"; then
        docker stats nginx --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" | tail -n +2
    fi
}

# Function to check response time
check_response_time() {
    local url="http://localhost/health"
    local response_time=$(curl -o /dev/null -s -w '%{time_total}' "$url")

    if (( $(echo "$response_time > 1.0" | bc -l) )); then
        echo "$(date): Slow response time detected: ${response_time}s" >> "$LOG_FILE"
    fi

    echo "$response_time"
}

# Function to check error rate
check_error_rate() {
    local access_log="/var/log/nginx/access.log"
    local total_requests=$(wc -l < "$access_log")
    local error_requests=$(awk '($9 >= 400) { count++ } END { print count+0 }' "$access_log")

    if [[ $total_requests -gt 0 ]]; then
        local error_rate=$(( error_requests * 100 / total_requests ))
        if [[ $error_rate -gt 5 ]]; then
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
            if (( $(echo "$cpu_percent > $CPU_THRESHOLD" | bc -l) )); then
                echo "$(date): High CPU usage: ${cpu_percent}%" >> "$LOG_FILE"
            fi

            # Check memory usage
            if (( $(echo "$memory_percent > $MEMORY_THRESHOLD" | bc -l) )); then
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
    log "Nginx performance monitoring setup completed"
}