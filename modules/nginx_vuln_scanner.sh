#!/bin/bash

# ============================================================================
# du_setup.sh - Nginx Vulnerability Management Module
# Handles security scanning, CVE monitoring, and vulnerability assessment
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Vulnerability Management Function ---
manage_vulnerabilities() {
    print_section "Nginx Vulnerability Management"

    printf '%s\n' "${CYAN}Vulnerability Management Options:${NC}"
    printf '  1) Run Security Scan${NC}\n'
    printf '  2) Check for CVEs${NC}\n'
    printf '  3) Scan Configuration${NC}\n'
    printf '  4) Container Security Scan${NC}\n'
    printf '  5) Setup Automated Scanning${NC}\n'

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter choice (1-5): ${NC}")" VULN_CHOICE
        case $VULN_CHOICE in
            1) run_security_scan ;;
            2) check_cves ;;
            3) scan_configuration ;;
            4) container_security_scan ;;
            5) setup_automated_scanning ;;
            *) print_error "Invalid choice. Please enter 1-5." ;;
        esac
        break
    done
}

# --- Run Security Scan ---
run_security_scan() {
    print_info "Running comprehensive security scan..."

    # Create scan report directory
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir"
    local report_file="$report_dir/security_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx Security Scan Report"
        echo "=========================="
        echo "Date: $(date)"
        echo "Server: $(hostname)"
        echo

        # System information
        echo "System Information:"
        echo "------------------"
        echo "OS: $(uname -a)"
        echo "Nginx Version: $(docker-compose exec nginx nginx -v 2>&1 | cut -d'/' -f2 || echo 'N/A')"
        echo "Docker Version: $(docker --version)"
        echo

        # SSL/TLS Configuration Check
        echo "SSL/TLS Configuration:"
        echo "---------------------"
        if [[ -f /opt/nginx/certs/cert.pem ]]; then
            echo "Certificate found: /opt/nginx/certs/cert.pem"

            # Check certificate strength
            local cert_info=$(openssl x509 -in /opt/nginx/certs/cert.pem -text -noout)
            echo "Key Size: $(echo "$cert_info" | grep "Public-Key Algorithm" | cut -d: -f2 | tr -d ' ')"
            echo "Signature Algorithm: $(echo "$cert_info" | grep "Signature Algorithm" | head -1 | cut -d: -f2 | tr -d ' ')"
            echo "Expires: $(echo "$cert_info" | grep "Not After" | cut -d: -f2- | tr -d ' ')"

            # Check for weak ciphers (if HTTPS is configured)
            if docker-compose exec nginx nginx -T 2>/dev/null | grep -q "ssl_ciphers"; then
                echo "SSL Ciphers configured: ✓"
            else
                echo "SSL Ciphers: Not configured"
            fi
        else
            echo "No SSL certificate found"
        fi
        echo

        # Security Headers Check
        echo "Security Headers:"
        echo "----------------"
        if curl -s -I http://localhost 2>/dev/null | grep -qi "x-frame-options"; then
            echo "X-Frame-Options: ✓"
        else
            echo "X-Frame-Options: ✗"
        fi

        if curl -s -I http://localhost 2>/dev/null | grep -qi "x-content-type-options"; then
            echo "X-Content-Type-Options: ✓"
        else
            echo "X-Content-Type-Options: ✗"
        fi

        if curl -s -I http://localhost 2>/dev/null | grep -qi "x-xss-protection"; then
            echo "X-XSS-Protection: ✓"
        else
            echo "X-XSS-Protection: ✗"
        fi

        if curl -s -I http://localhost 2>/dev/null | grep -qi "strict-transport-security"; then
            echo "HSTS: ✓"
        else
            echo "HSTS: ✗"
        fi
        echo

        # Directory Traversal Check
        echo "Directory Traversal Check:"
        echo "-------------------------"
        local traversal_tests=(
            "/../../../etc/passwd"
            "/..%2F..%2F..%2Fetc%2Fpasswd"
            "/....//....//....//etc/passwd"
        )

        for test_path in "${traversal_tests[@]}"; do
            local response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost$test_path")
            if [[ "$response" == "200" ]]; then
                echo "Directory traversal vulnerability detected: $test_path ✗"
            else
                echo "Directory traversal test passed: $test_path ✓"
            fi
        done
        echo

        # Common Web Vulnerabilities Check
        echo "Common Vulnerabilities:"
        echo "---------------------"

        # SQL Injection test
        local sqli_response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/?id=1' OR '1'='1")
        if [[ "$sqli_response" == "200" ]]; then
            echo "Potential SQL Injection vulnerability ✗"
        else
            echo "SQL Injection test passed ✓"
        fi

        # XSS test
        local xss_response=$(curl -s "http://localhost/?search=<script>alert('xss')</script>" | grep -i "<script>")
        if [[ -n "$xss_response" ]]; then
            echo "Potential XSS vulnerability ✗"
        else
            echo "XSS test passed ✓"
        fi

        # Information Disclosure Check
        local server_info=$(curl -s -I http://localhost 2>/dev/null | grep -i server)
        if [[ -n "$server_info" ]]; then
            echo "Server header disclosure: $server_info ✗"
        else
            echo "Server header hidden ✓"
        fi
        echo

        # Rate Limiting Check
        echo "Rate Limiting Check:"
        echo "--------------------"
        local request_count=0
        for ((i=1; i<=50; i++)); do
            local response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/")
            if [[ "$response" == "429" ]] || [[ "$response" == "503" ]]; then
                echo "Rate limiting active (blocked after $i requests) ✓"
                request_count=$i
                break
            fi
            request_count=$i
        done

        if [[ $request_count -eq 50 ]]; then
            echo "No rate limiting detected ✗"
        fi
        echo

        # File Access Check
        echo "File Access Control:"
        echo "-------------------"
        local sensitive_files=(
            "/etc/passwd"
            "/etc/shadow"
            "/.env"
            "/config.php"
            "/wp-config.php"
            "/.git/config"
        )

        for file in "${sensitive_files[@]}"; do
            local response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost$file")
            if [[ "$response" == "200" ]]; then
                echo "Sensitive file accessible: $file ✗"
            else
                echo "Sensitive file protected: $file ✓"
            fi
        done
        echo

        # Recommendations
        echo "Security Recommendations:"
        echo "----------------------"
        echo "1. Enable HTTPS with valid SSL certificates"
        echo "2. Implement strong security headers"
        echo "3. Configure rate limiting"
        echo "4. Regularly update Nginx and dependencies"
        echo "5. Monitor logs for suspicious activity"
        echo "6. Use Web Application Firewall (WAF)"
        echo "7. Implement Content Security Policy (CSP)"
        echo "8. Regular security scans and penetration testing"

    } > "$report_file"

    print_success "Security scan completed."
    print_info "Report saved to: $report_file"
    log "Security scan completed: $report_file"
}

# --- Check for CVEs ---
check_cves() {
    print_info "Checking for Nginx CVEs..."

    # Get Nginx version
    local nginx_version=$(docker-compose exec nginx nginx -v 2>&1 | cut -d'/' -f2 | sed 's/[^0-9.]//g')

    if [[ -z "$nginx_version" ]]; then
        print_error "Could not determine Nginx version."
        return 1
    fi

    print_info "Nginx version: $nginx_version"

    # Fetch CVE data from NVD (simplified version)
    print_info "Fetching CVE information..."

    # Create CVE check script
    cat > /tmp/cve_check.py << 'EOF'
#!/usr/bin/env python3
import requests
import sys
import re
from datetime import datetime

def get_nginx_cves(version):
    """Get CVEs for specific Nginx version"""
    try:
        # This is a simplified version - in production, use proper NVD API
        url = f"https://services.nvd.nist.gov/rest/json/cves/1.0?keywordPattern=nginx:{version}"
        response = requests.get(url, timeout=10)

        if response.status_code == 200:
            data = response.json()
            cves = []

            for item in data.get('CVE_Items', []):
                cve_id = item['cve']['CVE_data_meta']['ID']
                description = item['cve']['description']['description_data'][0]['value']
                severity = item.get('impact', {}).get('baseMetricV3', {}).get('cvssV3', {}).get('baseSeverity', 'UNKNOWN')

                cves.append({
                    'id': cve_id,
                    'description': description[:100] + '...',
                    'severity': severity,
                    'published': item['publishedDate']
                })

            return cves
        else:
            return []
    except Exception as e:
        print(f"Error fetching CVEs: {e}")
        return []

if __name__ == '__main__':
    version = sys.argv[1] if len(sys.argv) > 1 else "1.0"
    cves = get_nginx_cves(version)

    if cves:
        print(f"Found {len(cves)} CVEs for Nginx {version}:")
        print("-" * 50)
        for cve in cves[:10]:  # Show first 10
            print(f"CVE ID: {cve['id']}")
            print(f"Severity: {cve['severity']}")
            print(f"Description: {cve['description']}")
            print(f"Published: {cve['published']}")
            print("-" * 30)
    else:
        print(f"No CVEs found for Nginx {version} in recent data")
        print("Note: This is a simplified check. Use proper vulnerability databases for comprehensive scanning.")
EOF

    python3 /tmp/cve_check.py "$nginx_version"
    rm -f /tmp/cve_check.py

    # Check Docker image vulnerabilities
    print_info "Checking Docker image vulnerabilities..."
    if command -v docker >/dev/null 2>&1; then
        # Use docker scout if available, otherwise show manual instructions
        if docker scout 2>/dev/null | grep -q "Usage"; then
            print_info "Running Docker vulnerability scan..."
            docker scout cves nginx:alpine
        else
            print_info "Docker Scout not available. Manual vulnerability check recommended:"
            print_info "  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                aquasec/trivy image nginx:alpine"
        fi
    fi

    log "CVE check completed for Nginx $nginx_version"
}

# --- Scan Configuration ---
scan_configuration() {
    print_info "Scanning Nginx configuration for security issues..."

    local config_file="/opt/nginx/nginx.conf"
    local config_dir="/opt/nginx/conf.d"

    # Create configuration scan report
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir"
    local report_file="$report_dir/config_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx Configuration Security Scan"
        echo "================================"
        echo "Date: $(date)"
        echo

        # Test configuration syntax
        echo "Configuration Syntax Check:"
        echo "------------------------"
        if docker-compose exec nginx nginx -t 2>/dev/null; then
            echo "Configuration syntax: ✓ Valid"
        else
            echo "Configuration syntax: ✗ Invalid"
            echo "Error details:"
            docker-compose exec nginx nginx -t
        fi
        echo

        # Security settings analysis
        echo "Security Settings Analysis:"
        echo "------------------------"

        # Check server_tokens
        if grep -q "server_tokens off" "$config_file"; then
            echo "Server tokens hidden: ✓"
        else
            echo "Server tokens hidden: ✗ (Add: server_tokens off;)"
        fi

        # Check for security headers
        if [[ -f "$config_dir/security-headers.conf" ]]; then
            echo "Security headers configured: ✓"
        else
            echo "Security headers configured: ✗ (Missing security-headers.conf)"
        fi

        # Check for rate limiting
        if grep -q "limit_req_zone" "$config_file"; then
            echo "Rate limiting configured: ✓"
        else
            echo "Rate limiting configured: ✗ (Add limit_req_zone)"
        fi

        # Check for SSL configuration
        if grep -q "ssl_certificate" "$config_dir"/*.conf 2>/dev/null; then
            echo "SSL configured: ✓"

            # Check SSL protocols
            if grep -q "ssl_protocols.*TLSv1.2.*TLSv1.3" "$config_dir"/*.conf 2>/dev/null; then
                echo "Modern SSL protocols: ✓"
            else
                echo "Modern SSL protocols: ✗ (Use TLSv1.2+ only)"
            fi
        else
            echo "SSL configured: ✗ (No SSL certificates found)"
        fi

        # Check for access restrictions
        echo
        echo "Access Restrictions:"
        echo "-------------------"

        # Check for hidden file protection
        if grep -q "location ~ /\." "$config_dir"/*.conf 2>/dev/null; then
            echo "Hidden file protection: ✓"
        else
            echo "Hidden file protection: ✗ (Add location ~ /\. { deny all; })"
        fi

        # Check for backup file protection
        if grep -q "\.(bak|backup|old)" "$config_dir"/*.conf 2>/dev/null; then
            echo "Backup file protection: ✓"
        else
            echo "Backup file protection: ✗ (Add protection for backup files)"
        fi

        # Check for log configuration
        echo
        echo "Logging Configuration:"
        echo "---------------------"

        if grep -q "access_log" "$config_file"; then
            echo "Access logging: ✓"
        else
            echo "Access logging: ✗ (Add access_log directive)"
        fi

        if grep -q "error_log" "$config_file"; then
            echo "Error logging: ✓"
        else
            echo "Error logging: ✗ (Add error_log directive)"
        fi

        # Performance settings
        echo
        echo "Performance Settings:"
        echo "-------------------"

        if grep -q "worker_processes auto" "$config_file"; then
            echo "Auto worker processes: ✓"
        else
            echo "Auto worker processes: ✗ (Use: worker_processes auto;)"
        fi

        if grep -q "keepalive_timeout" "$config_file"; then
            echo "Keep-alive timeout: ✓"
        else
            echo "Keep-alive timeout: ✗ (Add keepalive_timeout directive)"
        fi

        # Recommendations
        echo
        echo "Configuration Recommendations:"
        echo "----------------------------"
        echo "1. Hide server tokens: server_tokens off;"
        echo "2. Implement security headers"
        echo "3. Configure rate limiting"
        echo "4. Enable SSL/TLS with modern protocols"
        echo "5. Restrict access to sensitive files"
        echo "6. Configure proper logging"
        echo "7. Optimize performance settings"
        echo "8. Regular configuration testing"

    } > "$report_file"

    print_success "Configuration scan completed."
    print_info "Report saved to: $report_file"
    log "Configuration scan completed: $report_file"
}

# --- Container Security Scan ---
container_security_scan() {
    print_info "Running container security scan..."

    # Check if Docker is running
    if ! docker ps --format "table {{.Names}}" | grep -q "^nginx$"; then
        print_error "Nginx container is not running."
        return 1
    fi

    # Create container scan report
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir"
    local report_file="$report_dir/container_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx Container Security Scan"
        echo "============================="
        echo "Date: $(date)"
        echo

        # Container information
        echo "Container Information:"
        echo "-------------------"
        docker inspect nginx | jq -r '.[0] | {
            Name: .Name,
            Image: .Config.Image,
            Created: .Created,
            State: .State.Status,
            Ports: .NetworkSettings.Ports
        }'
        echo

        # Security settings check
        echo "Security Settings:"
        echo "----------------"

        # Check if running as root
        local user_id=$(docker exec nginx id -u)
        if [[ "$user_id" == "0" ]]; then
            echo "Running as root: ✗ (Security risk)"
        else
            echo "Running as non-root: ✓ (User ID: $user_id)"
        fi

        # Check for privileged mode
        local privileged=$(docker inspect nginx | jq -r '.[0].Host.Privileged')
        if [[ "$privileged" == "true" ]]; then
            echo "Privileged mode: ✗ (Security risk)"
        else
            echo "Privileged mode: ✓ (Disabled)"
        fi

        # Check for capabilities
        echo "Capabilities:"
        docker inspect nginx | jq -r '.[0].Host.Capabilities[]' 2>/dev/null || echo "No additional capabilities"

        # Check for security options
        echo "Security Options:"
        docker inspect nginx | jq -r '.[0].HostSecurityOpt[]' 2>/dev/null || echo "No security options"

        # Check for read-only filesystem
        local read_only=$(docker inspect nginx | jq -r '.[0].HostConfig.ReadonlyRootfs')
        if [[ "$read_only" == "true" ]]; then
            echo "Read-only filesystem: ✓"
        else
            echo "Read-only filesystem: ✗ (Consider enabling)"
        fi

        # Check resource limits
        echo
        echo "Resource Limits:"
        echo "---------------"

        local memory_limit=$(docker inspect nginx | jq -r '.[0].HostConfig.Memory')
        if [[ "$memory_limit" != "0" ]]; then
            echo "Memory limit: ✓ ($(echo "$memory_limit" | awk '{print $1/1024/1024" MB"}'))"
        else
            echo "Memory limit: ✗ (Unlimited)"
        fi

        local cpu_limit=$(docker inspect nginx | jq -r '.[0].HostConfig.CpuShares')
        if [[ "$cpu_limit" != "0" ]]; then
            echo "CPU limit: ✓ (Shares: $cpu_limit)"
        else
            echo "CPU limit: ✗ (Unlimited)"
        fi

        # Network configuration
        echo
        echo "Network Configuration:"
        echo "--------------------"

        local network_mode=$(docker inspect nginx | jq -r '.[0].HostConfig.NetworkMode')
        echo "Network mode: $network_mode"

        if [[ "$network_mode" == "bridge" ]]; then
            echo "Bridge network: ✓ (Isolated)"
        else
            echo "Network mode: ⚠ (Review security implications)"
        fi

        # Port bindings
        echo "Port bindings:"
        docker inspect nginx | jq -r '.[0].NetworkSettings.Ports | to_entries[] | "\(.key): \(.value | if . != null then .[0].HostPort else "not bound" end)"'

        # Volume mounts
        echo
        echo "Volume Mounts:"
        echo "--------------"
        docker inspect nginx | jq -r '.[0].Mounts[] | "\(.Type): \(.Source) -> \(.Destination) (RW: \(.RW))"'

        # Recommendations
        echo
        echo "Container Security Recommendations:"
        echo "--------------------------------"
        echo "1. Run as non-root user"
        echo "2. Use read-only filesystem"
        echo "3. Set resource limits"
        echo "4. Use bridge networking"
        echo "5. Minimize exposed ports"
        echo "6. Use security profiles (AppArmor/SELinux)"
        echo "7. Regular image updates"
        echo "8. Scan images for vulnerabilities"

    } > "$report_file"

    print_success "Container security scan completed."
    print_info "Report saved to: $report_file"
    log "Container security scan completed: $report_file"
}

# --- Setup Automated Scanning ---
setup_automated_scanning() {
    print_info "Setting up automated security scanning..."

    # Create automated scan script
    cat > /opt/nginx/scripts/auto_security_scan.sh << 'EOF'
#!/bin/bash

# Automated security scanning script
REPORT_DIR="/opt/nginx/security_reports"
LOG_FILE="/var/log/nginx/auto_security_scan.log"

# Create directories
mkdir -p "$REPORT_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to run security scan
run_security_scan() {
    log_message "Starting automated security scan"

    local report_file="$REPORT_DIR/auto_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Automated Security Scan Report"
        echo "============================="
        echo "Date: $(date)"
        echo

        # Basic health check
        if curl -f http://localhost/health >/dev/null 2>&1; then
            echo "Nginx health check: ✓"
        else
            echo "Nginx health check: ✗"
        fi

        # Check for recent security events
        if [[ -f /var/log/nginx/security_alerts.log ]]; then
            local recent_alerts=$(find /var/log/nginx/security_alerts.log -mtime -1 | wc -l)
            echo "Recent security alerts (24h): $recent_alerts"
        fi

        # Check SSL certificate expiry
        if [[ -f /opt/nginx/certs/cert.pem ]]; then
            local expiry_date=$(openssl x509 -in /opt/nginx/certs/cert.pem -noout -enddate | cut -d= -f2)
            local expiry_epoch=$(date -d "$expiry_date" +%s)
            local current_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

            if [[ $days_left -lt 30 ]]; then
                echo "SSL certificate expiry: ⚠ $days_left days remaining"
            else
                echo "SSL certificate expiry: ✓ $days_left days remaining"
            fi
        fi

        # Check for failed login attempts
        if [[ -f /var/log/nginx/access.log ]]; then
            local failed_logins=$(grep " 401 " /var/log/nginx/access.log | wc -l)
            echo "Failed login attempts (24h): $failed_logins"
        fi

        # Check for blocked IPs
        if command -v fail2ban-client >/dev/null 2>&1; then
            local banned_ips=$(fail2ban-client status nginx-http-auth 2>/dev/null | grep "Currently banned:" | awk '{print $3}')
            echo "Currently banned IPs: ${banned_ips:-0}"
        fi

        # Check container status
        if docker ps --format "table {{.Names}}" | grep -q "^nginx$"; then
            echo "Container status: ✓ Running"
        else
            echo "Container status: ✗ Not running"
        fi

        # Check disk space
        local disk_usage=$(df /opt/nginx | tail -1 | awk '{print $5}' | sed 's/%//')
        if [[ $disk_usage -gt 80 ]]; then
            echo "Disk usage: ⚠ $disk_usage% (High)"
        else
            echo "Disk usage: ✓ $disk_usage%"
        fi

    } > "$report_file"

    log_message "Security scan completed: $report_file"

    # Send alert if critical issues found
    if grep -q "✗\|⚠" "$report_file"; then
        log_message "CRITICAL: Security issues detected in automated scan"
        # Send email notification if configured
        if [[ -n "${REPORT_EMAIL:-}" ]]; then
            mail -s "Nginx Security Alert" "$REPORT_EMAIL" < "$report_file"
        fi
    fi
}

# Main execution
run_security_scan
EOF

    chmod +x /opt/nginx/scripts/auto_security_scan.sh

    # Setup cron job for automated scanning
    if ! crontab -l 2>/dev/null | grep -q "auto_security_scan.sh"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * /opt/nginx/scripts/auto_security_scan.sh") | crontab -
        print_success "Automated security scan scheduled for daily 2:00 AM."
    else
        print_info "Automated security scan already scheduled."
    fi

    # Setup weekly comprehensive scan
    if ! crontab -l 2>/dev/null | grep -q "weekly_scan"; then
        (crontab -l 2>/dev/null; echo "0 3 * * 0 /opt/nginx/scripts/weekly_scan.sh") | crontab -

        # Create weekly scan script
        cat > /opt/nginx/scripts/weekly_scan.sh << 'EOF'
#!/bin/bash
# Weekly comprehensive security scan
/opt/nginx/scripts/auto_security_scan.sh
/opt/nginx/scripts/vulnerability_check.sh
EOF
        chmod +x /opt/nginx/scripts/weekly_scan.sh

        print_success "Weekly comprehensive scan scheduled for Sundays 3:00 AM."
    fi

    print_success "Automated security scanning configured."
    log "Automated security scanning setup completed"
}