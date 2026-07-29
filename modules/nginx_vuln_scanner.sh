#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Nginx Vulnerability Management Module
# Handles security scanning, CVE monitoring, and vulnerability assessment
# ============================================================================

# Source dependencies
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/config.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/utils.sh"

# ============================================================================
# Secure Temporary Directory Setup
# ============================================================================

# Create secure temporary directory for Python scripts
NGINX_SCRIPTS_TEMP="/opt/nginx/scripts/temp"
mkdir -p "$NGINX_SCRIPTS_TEMP"
chmod 700 "$NGINX_SCRIPTS_TEMP"

# --- Vulnerability Management Function ---
manage_vulnerabilities() {
    print_section "Nginx Vulnerability Management"

    while true; do
        printf '%s\n' "${CYAN}Vulnerability Management Options:${NC}"
        printf '  0) Return to Main Menu%s\n' "$NC"
        printf '  1) Run Security Scan%s\n' "$NC"
        printf '  2) Check for CVEs%s\n' "$NC"
        printf '  3) Scan Configuration%s\n' "$NC"
        printf '  4) Container Security Scan%s\n' "$NC"
        printf '  5) Setup Automated Scanning%s\n' "$NC"
        printf '  6) Setup Auto-Update (Nginx, Alpine, Security Patches)%s\n' "$NC"

        read -rp "$(printf '%s' "${CYAN}Enter choice (0-6): ${NC}")" VULN_CHOICE
        case $VULN_CHOICE in
            0)
                print_info "Returning to main menu..."
                return 0
                ;;
            1) run_security_scan ;;
            2) check_cves ;;
            3) scan_configuration ;;
            4) container_security_scan ;;
            5) setup_automated_scanning ;;
            6) setup_auto_update ;;
            *)
                print_error "Invalid choice. Please enter 0-6."
                continue
                ;;
        esac

        # Ask if user wants to perform another task
        echo
        read -rp "$(printf '%s' "${CYAN}Do you want to perform another vulnerability management task? (y/n): ${NC}")" ANOTHER_VULN_CHOICE
        if [[ ! "$ANOTHER_VULN_CHOICE" =~ ^[Yy]$ ]]; then
            print_info "Exiting Nginx vulnerability management setup"
            return 0
        fi
        echo
    done
}

# --- Run Security Scan ---
run_security_scan() {
    print_info "Running comprehensive security scan..."

    # Create scan report directory
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir" || {
        print_error "Failed to create report directory: $report_dir"
        return 1
    }
    local report_file
    report_file="$report_dir/security_scan_$(date +%Y%m%d_%H%M%S).txt"

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
        # Get nginx version based on type
        local nginx_version="N/A"
        local nginx_type="unknown"

        # Try system nginx first
        if systemctl is-active --quiet nginx 2>/dev/null; then
            local version_output
            version_output=$(nginx -v 2>&1 || echo "")
            nginx_version=$(echo "$version_output" | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "N/A")
            if [[ "$nginx_version" != "N/A" ]] && [[ -n "$nginx_version" ]]; then
                nginx_type="system"
            fi
        fi

        # If system nginx not found, try Docker containers
        if [[ "$nginx_version" == "N/A" ]] || [[ -z "$nginx_version" ]]; then
            local nginx_containers
            nginx_containers=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -i nginx || echo "")
            if [[ -n "$nginx_containers" ]]; then
                while IFS=$'\t' read -r container status; do
                    if [[ -n "$container" ]]; then
                        # Check if container is actually running (not restarting)
                        if [[ "$status" =~ "Up" ]]; then
                            local version_output
                            version_output=$(docker exec "$container" nginx -v 2>&1 || echo "")
                            nginx_version=$(echo "$version_output" | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "N/A")
                            if [[ "$nginx_version" != "N/A" ]] && [[ -n "$nginx_version" ]]; then
                                nginx_type="docker ($container)"
                                break
                            fi
                        elif [[ "$status" =~ "Restarting" ]]; then
                            echo "Nginx Version: Container '$container' is restarting (Status: $status)"
                            echo "  Configuration error detected. Check: docker logs $container --tail=50"
                            nginx_version="Container Restarting"
                            nginx_type="docker ($container)"
                            break
                        fi
                    fi
                done <<< "$nginx_containers"
            fi
        fi
        echo "Nginx Version: $nginx_version ($nginx_type)"
        echo "Docker Version: $(docker --version)"
        echo

        # SSL/TLS Configuration Check
        echo "SSL/TLS Configuration:"
        echo "---------------------"
        local cert_file=""
        if [[ -f /opt/nginx/certs/cert.pem ]]; then
            cert_file="/opt/nginx/certs/cert.pem"
        else
            # Try to find any domain-specific certificate
            cert_file=$(find /opt/nginx/certs/ -maxdepth 1 -name "*.pem" ! -name "cert.pem" | head -n 1)
        fi

        if [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]]; then
            echo "Certificate found: $cert_file"

            # Check certificate strength
            local cert_info
            cert_info=$(openssl x509 -in "$cert_file" -text -noout 2>/dev/null || echo "Error reading certificate")
            echo "Key Size: $(echo "$cert_info" | grep "Public-Key Algorithm" | cut -d: -f2 | tr -d ' ' || echo "N/A")"
            echo "Signature Algorithm: $(echo "$cert_info" | grep "Signature Algorithm" | head -1 | cut -d: -f2 | tr -d ' ' || echo "N/A")"
            echo "Expires: $(echo "$cert_info" | grep "Not After" | sed 's/.*Not After ://' || echo "N/A")"

            # Check for weak ciphers (if HTTPS is configured)
            local ssl_ciphers_found=false
            if systemctl is-active --quiet nginx 2>/dev/null; then
                if nginx -T 2>/dev/null | grep -q "ssl_ciphers"; then
                    ssl_ciphers_found=true
                fi
            else
                # Try Docker containers
                local nginx_containers
                nginx_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx || echo "")
                if [[ -n "$nginx_containers" ]]; then
                    while IFS= read -r container; do
                        if [[ -n "$container" ]]; then
                            if docker exec "$container" nginx -T 2>/dev/null | grep -q "ssl_ciphers"; then
                                ssl_ciphers_found=true
                                break
                            fi
                        fi
                    done <<< "$nginx_containers"
                fi
            fi

            if [[ "$ssl_ciphers_found" == "true" ]]; then
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
        # Test HTTPS if available, otherwise fallback to HTTP
        local test_protocol="https"
        local test_host="localhost"
        local test_port="443"
        local mock_domain="localhost"

        # Try to detect domain for Host header
        if [[ -n "$cert_file" ]]; then
            mock_domain=$(basename "$cert_file" .pem)
            [[ "$mock_domain" == "cert" ]] && mock_domain="localhost"
        fi

        # Robust port detection: Try common HTTPS ports first, then HTTP
        if curl -s -k -I -L -H "Host: $mock_domain" "https://localhost:443" >/dev/null 2>&1; then
            test_protocol="https"
            test_port="443"
            echo "Note: Testing HTTPS (port 443) - Using Host: $mock_domain"
        elif curl -s -k -I -L -H "Host: $mock_domain" "https://localhost:8443" >/dev/null 2>&1; then
            test_protocol="https"
            test_port="8443"
            echo "Note: Testing HTTPS (port 8443) - Using Host: $mock_domain"
        elif curl -s -I -L -H "Host: $mock_domain" "http://localhost:80" >/dev/null 2>&1; then
            test_protocol="http"
            test_port="80"
            echo "Note: Testing HTTP (port 80) - HSTS check will be skipped"
        else
            test_protocol="http"
            test_port="8080"
            echo "Note: Testing HTTP (port 8080) - HSTS check will be skipped"
        fi

        local http_headers
        local curl_headers_cmd=(curl -s -k -I -L -H "Host: $mock_domain" "${test_protocol}://${test_host}:${test_port}")
        http_headers=$("${curl_headers_cmd[@]}" 2>/dev/null || echo "")
        if echo "$http_headers" | grep -qi "x-frame-options"; then
            echo "X-Frame-Options: ✓"
        else
            echo "X-Frame-Options: ✗"
        fi

        if echo "$http_headers" | grep -qi "x-content-type-options"; then
            echo "X-Content-Type-Options: ✓"
        else
            echo "X-Content-Type-Options: ✗"
        fi

        if echo "$http_headers" | grep -qi "x-xss-protection"; then
            echo "X-XSS-Protection: ✓"
        else
            echo "X-XSS-Protection: ✗"
        fi

        if echo "$http_headers" | grep -qi "strict-transport-security"; then
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
            local curl_cmd=(curl -s -o /dev/null -w "%{http_code}" -L -H "Host: $mock_domain")
            if [[ "$test_protocol" == "https" ]]; then
                curl_cmd+=(-k)
            fi
            local response
            response=$("${curl_cmd[@]}" "${test_protocol}://${test_host}:${test_port}$test_path" 2>/dev/null || echo "000")
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
        local curl_sqli_cmd=(curl -s -o /dev/null -w "%{http_code}" -L -H "Host: $mock_domain")
        if [[ "$test_protocol" == "https" ]]; then
            curl_sqli_cmd+=(-k)
        fi
        local sqli_response
        sqli_response=$("${curl_sqli_cmd[@]}" "${test_protocol}://${test_host}:${test_port}/?id=1' OR '1'='1" 2>/dev/null || echo "000")
        if [[ "$sqli_response" == "200" ]]; then
            echo "Potential SQL Injection vulnerability ✗"
        else
            echo "SQL Injection test passed ✓"
        fi

        # XSS test
        local xss_token
        xss_token="SCANNER_XSS_TEST_TOKEN_$(date +%s)"
        local curl_xss_cmd=(curl -s -L -H "Host: $mock_domain")
        if [[ "$test_protocol" == "https" ]]; then
            curl_xss_cmd+=(-k)
        fi
        local xss_response
        xss_response=$("${curl_xss_cmd[@]}" "${test_protocol}://${test_host}:${test_port}/?search=<script>alert('${xss_token}')</script>" 2>/dev/null | grep -i "${xss_token}" || echo "")
        if [[ -n "$xss_response" ]]; then
            echo "Potential XSS vulnerability ✗"
        else
            echo "XSS test passed ✓"
        fi

        # Information Disclosure Check
        local curl_info_cmd=(curl -s -I -L -H "Host: $mock_domain")
        if [[ "$test_protocol" == "https" ]]; then
            curl_info_cmd+=(-k)
        fi
        local server_info
        server_info=$("${curl_info_cmd[@]}" "${test_protocol}://${test_host}:${test_port}" 2>/dev/null | grep -i "^Server:" || echo "")
        if [[ -n "$server_info" ]]; then
            # Check if version is disclosed (e.g., "nginx/1.29.3")
            if echo "$server_info" | grep -q "/[0-9]"; then
                echo "Server version disclosure: $server_info ✗"
            else
                echo "Server header disclosure: $server_info (Warning: Requires headers-more module to hide fully) ⚠"
            fi
        else
            echo "Server header hidden ✓"
        fi
        echo

        # Rate Limiting Check
        echo "Rate Limiting Check:"
        echo "--------------------"

        # Check if rate limiting is configured in nginx
        local rate_limiting_configured=false
        local nginx_config=""

        if systemctl is-active --quiet nginx 2>/dev/null; then
            nginx_config=$(nginx -T 2>/dev/null || echo "")
        else
            # Try Docker containers
            local nginx_containers
            nginx_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx || echo "")
            if [[ -n "$nginx_containers" ]]; then
                while IFS= read -r container; do
                    if [[ -n "$container" ]]; then
                        nginx_config=$(docker exec "$container" nginx -T 2>/dev/null || echo "")
                        if [[ -n "$nginx_config" ]]; then
                            break
                        fi
                    fi
                done <<< "$nginx_containers"
            fi
        fi

        # Check for rate limiting configuration
        if echo "$nginx_config" | grep -q "limit_req_zone"; then
            rate_limiting_configured=true
        fi

        if [[ "$rate_limiting_configured" == "true" ]]; then
            echo "Rate limiting configured: ✓"
            # Extract and display rate limiting settings
            local rate_settings
            rate_settings=$(echo "$nginx_config" | grep -E "limit_req_zone|limit_req" | head -5)
            if [[ -n "$rate_settings" ]]; then
                echo "  Settings:"
                echo "$rate_settings" \
                | sed 's/^[[:space:]]*//' \
                | sed 's/^/        /'
            fi
        else
            echo "Rate limiting configured: ✗ (Add limit_req_zone directive)"
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
            local curl_file_cmd=(curl -s -o /dev/null -w "%{http_code}" -L -H "Host: $mock_domain")
            if [[ "$test_protocol" == "https" ]]; then
                curl_file_cmd+=(-k)
            fi
            local response
            response=$("${curl_file_cmd[@]}" "${test_protocol}://${test_host}:${test_port}$file" 2>/dev/null || echo "000")
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

    } > "$report_file" 2>&1

    print_success "Security scan completed."
    print_info "Report saved to: $report_file"
    log "Security scan completed: $report_file"
    return 0
}

# --- Check for CVEs ---
check_cves() {
    print_info "Checking for Nginx CVEs..."

    # Get Nginx version based on type
    local nginx_version=""
    local nginx_type="unknown"
    local nginx_image=""

    # Try system nginx first
    if systemctl is-active --quiet nginx 2>/dev/null; then
        local version_output
        version_output=$(nginx -v 2>&1 || echo "")
        nginx_version=$(echo "$version_output" | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "")
        if [[ -n "$nginx_version" ]]; then
            nginx_type="system"
        fi
    fi

    # If system nginx not found, try Docker containers
    if [[ -z "$nginx_version" ]]; then
        # Get list of containers that might be nginx (including restarting ones)
        local nginx_containers
        nginx_containers=$(docker ps -a --format "{{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null | grep -i nginx || echo "")

        if [[ -n "$nginx_containers" ]]; then
            # Try each nginx container
            while IFS=$'\t' read -r container status image; do
                if [[ -n "$container" ]]; then
                    # Check if container is actually running (not restarting)
                    if [[ "$status" =~ "Up" ]]; then
                        # Try docker exec
                        local version_output
                        version_output=$(docker exec "$container" nginx -v 2>&1 || echo "")
                        nginx_version=$(echo "$version_output" | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "")
                        if [[ -n "$nginx_version" ]]; then
                            nginx_type="docker ($container)"
                            nginx_image="$image"
                            break
                        fi
                    elif [[ "$status" =~ "Restarting" ]]; then
                        print_error "Container '$container' is in restart state (Status: $status)"
                        print_info "This indicates a configuration error preventing Nginx from starting."
                        print_info "Check container logs for details: docker logs $container --tail=50"
                        print_info "Common issues:"
                        print_info "  - Invalid nginx directives (e.g., 'more_clear_headers' requires nginx-mod-http-headers-more module)"
                        print_info "  - Permission issues with log files"
                        print_info "  - Syntax errors in nginx.conf"
                        return 1
                    fi
                fi
            done <<< "$nginx_containers"
        fi
    fi

    if [[ -z "$nginx_version" ]]; then
        print_error "Could not determine Nginx version."
        print_info "Possible reasons:"
        print_info "  - Nginx is not running"
        print_info "  - Docker container is not accessible"
        print_info "  - Container name does not contain 'nginx'"
        print_info "  - Insufficient permissions to access container"
        return 1
    fi

    print_info "Nginx version: $nginx_version ($nginx_type)"

    # Create vulnerability report directory
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir" || {
        print_error "Failed to create report directory: $report_dir"
        return 1
    }
    local report_file
    report_file="$report_dir/cve_report_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx CVE Vulnerability Report"
        echo "==============================="
        echo "Date: $(date)"
        echo "Nginx Version: $nginx_version ($nginx_type)"
        echo

        # 1. Use Trivy for comprehensive vulnerability scanning
        echo "=== Trivy Vulnerability Scan ==="
        echo

        if command -v docker >/dev/null 2>&1; then
            # Check if Trivy is available or pull it
            print_info "Running Trivy vulnerability scan..."

            # Determine target for Trivy scan
            local trivy_command=""
            local trivy_target=""

            if [[ "$nginx_type" == docker* ]]; then
                # Scan the Docker image
                trivy_command="image"
                trivy_target="$nginx_image"
                echo "Scanning Docker image: $nginx_image"
            else
                # Scan system packages
                trivy_command="fs"
                trivy_target="/"
                echo "Scanning system filesystem"
            fi

            # Run Trivy scan
            docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v "$report_dir":/output \
                aquasec/trivy:latest \
                "$trivy_command" \
                "$trivy_target" \
                --severity HIGH,CRITICAL \
                --format table \
                --no-progress \
                --output "/output/trivy_scan_$(date +%Y%m%d_%H%M%S).txt" 2>&1 || echo "Trivy scan completed with warnings"

            # Check if Trivy found vulnerabilities
            local trivy_output
            trivy_output=$(docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                aquasec/trivy:latest \
                "$trivy_command" \
                "$trivy_target" \
                --severity HIGH,CRITICAL \
                --format json \
                --no-progress 2>/dev/null || echo "{}")

            # Parse and display results
            local vuln_count
            vuln_count=$(echo "$trivy_output" | jq -r '.Results[].Vulnerabilities | length' 2>/dev/null | awk '{s+=$1} END {print s+0}')

            if [[ "$vuln_count" -gt 0 ]]; then
                echo "⚠ Found $vuln_count HIGH/CRITICAL vulnerabilities"
                echo
                echo "Top vulnerabilities:"
                echo "$trivy_output" | jq -r '.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH") | "\(.Severity): \(.VulnerabilityID) - \(.Title)"' 2>/dev/null | head -10 || echo "Unable to parse vulnerability details"
            else
                echo "✓ No HIGH or CRITICAL vulnerabilities found"
            fi
        else
            echo "⚠ Docker not available. Skipping Trivy scan."
        fi

        echo
        echo

        # 2. Use NVD API for CVE lookup
        echo "=== NVD CVE Database Lookup ==="
        echo

        # Create enhanced CVE check script with proper NVD API v2.0
        local script_path="$NGINX_SCRIPTS_TEMP/cve_check_$$.py"
        cat > "$script_path" << 'EOF'
#!/usr/bin/env python3
import requests
import sys
import json
import time
from datetime import datetime, timedelta

def get_nginx_cves(version):
    """Get CVEs for specific Nginx version using NVD API v2.0"""
    try:
        # NVD API v2.0 endpoint
        base_url = "https://services.nvd.nist.gov/rest/json/cves/2.0"

        # Search for nginx vulnerabilities with proper parameter format
        # Note: NVD API requires both pubStartDate and pubEndDate when using date filters
        # Maximum allowable range is 120 consecutive days

        # Example CPE for nginx core (adjust version if you want a specific one)
        # Nginx CPEs in NVD look like cpe:2.3:a:nginx:nginx:1.29.4:*:*:*:*:*:*:*
        cpe_name = f"cpe:2.3:a:nginx:nginx:{version}:*:*:*:*:*:*:*"
        params = {
            'cpeName': cpe_name,
            'resultsPerPage': 20,
            'pubStartDate': (datetime.now() - timedelta(days=120)).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'pubEndDate': datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
        }

        headers = {
            'User-Agent': 'Nginx-Vulnerability-Scanner/1.0'
        }

        # Add retry logic for rate limiting
        max_retries = 3
        for attempt in range(max_retries):
            try:
                response = requests.get(base_url, params=params, headers=headers, timeout=30)

                if response.status_code == 200:
                    data = response.json()
                    cves = []

                    for item in data.get('vulnerabilities', []):
                        cve = item['cve']
                        cve_id = cve['id']

                        # Get description
                        descriptions = cve.get('descriptions', [])
                        description = descriptions[0]['value'] if descriptions else 'No description available'

                        # Get CVSS score and severity
                        metrics = cve.get('metrics', {})
                        cvss_data = metrics.get('cvssMetricV31', []) or metrics.get('cvssMetricV30', []) or metrics.get('cvssMetricV2', [])

                        severity = 'UNKNOWN'
                        score = 0.0

                        if cvss_data:
                            cvss = cvss_data[0].get('cvssData', {})
                            score = cvss.get('baseScore', 0.0)
                            severity = cvss.get('baseSeverity', 'UNKNOWN')

                        cves.append({
                            'id': cve_id,
                            'description': description[:200] + '...' if len(description) > 200 else description,
                            'severity': severity,
                            'score': score,
                            'published': cve.get('published', 'Unknown')
                        })

                    return cves
                elif response.status_code == 403:
                    # Rate limited
                    if attempt < max_retries - 1:
                        wait_time = 6 * (attempt + 1)
                        print(f"Rate limited by NVD API. Waiting {wait_time} seconds before retry...")
                        time.sleep(wait_time)
                        continue
                    else:
                        print("Error: NVD API rate limit exceeded after multiple retries")
                        return []
                elif response.status_code == 404:
                    print("Error: NVD API endpoint not found (404)")
                    print("Note: NVD API may be temporarily unavailable or the endpoint has changed")
                    print("Falling back to OSV database only")
                    return []
                else:
                    print(f"Error: NVD API returned status {response.status_code}")
                    if response.text:
                        print(f"Response: {response.text[:200]}")
                    return []
            except requests.exceptions.Timeout:
                if attempt < max_retries - 1:
                    print(f"Request timed out. Retrying... (Attempt {attempt + 1}/{max_retries})")
                    time.sleep(2)
                    continue
                else:
                    print("Error: Request to NVD API timed out after multiple retries")
                    return []

    except requests.exceptions.RequestException as e:
        print(f"Error fetching CVEs from NVD: {e}")
        return []
    except Exception as e:
        print(f"Unexpected error: {e}")
        return []

def get_osv_cves(package, version):
    """Get CVEs from OSV (Open Source Vulnerabilities) database"""
    try:
        url = "https://api.osv.dev/v1/query"
        payload = {
            "package": {
                "name": package,
                "ecosystem": "Alpine"
            },
            "version": version
        }

        response = requests.post(url, json=payload, timeout=15)

        if response.status_code == 200:
            data = response.json()
            vulns = data.get('vulns', [])

            cves = []
            for vuln in vulns:
                cve_id = vuln.get('id', 'UNKNOWN')
                summary = vuln.get('summary', 'No summary available')

                # Get severity from affected versions
                severity = 'MEDIUM'
                severity_data = vuln.get('severity', [])
                if severity_data:
                    severity = severity_data[0].get('score', 'MEDIUM')

                cves.append({
                    'id': cve_id,
                    'description': summary[:200] + '...' if len(summary) > 200 else summary,
                    'severity': severity,
                    'score': 0.0,
                    'published': vuln.get('published', 'Unknown')
                })

            return cves
        elif response.status_code == 404:
            print(f"No vulnerabilities found for {package} {version} in OSV database")
            return []
        else:
            print(f"Error: OSV API returned status {response.status_code}")
            return []
    except Exception as e:
        print(f"Error fetching CVEs from OSV: {e}")
        return []

if __name__ == '__main__':
    version = sys.argv[1] if len(sys.argv) > 1 else "1.0"

    # Get CVEs from NVD
    print("Querying NVD database...")
    nvd_cves = get_nginx_cves(version)

    if nvd_cves:
        print(f"\nFound {len(nvd_cves)} CVEs for Nginx {version}:")
        print("=" * 60)

        # Sort by severity (CRITICAL > HIGH > MEDIUM > LOW)
        severity_order = {'CRITICAL': 0, 'HIGH': 1, 'MEDIUM': 2, 'LOW': 3, 'UNKNOWN': 4}
        nvd_cves.sort(key=lambda x: severity_order.get(x['severity'], 99))

        for cve in nvd_cves[:10]:
            print(f"\nCVE ID: {cve['id']}")
            print(f"Severity: {cve['severity']} (Score: {cve['score']})")
            print(f"Description: {cve['description']}")
            print(f"Published: {cve['published']}")
            print("-" * 40)
    else:
        print(f"No CVEs found for Nginx {version} in NVD database")

    # Also check OSV for Alpine package vulnerabilities
    print("\nQuerying OSV database for Alpine packages...")
    osv_cves = get_osv_cves("nginx", version)

    if osv_cves:
        print(f"\nFound {len(osv_cves)} additional vulnerabilities in OSV database:")
        print("=" * 60)
        for cve in osv_cves[:5]:
            print(f"\nID: {cve['id']}")
            print(f"Severity: {cve['severity']}")
            print(f"Description: {cve['description']}")
            print("-" * 40)
    else:
        print(f"No OSV vulnerabilities found for Nginx {version} in Alpine ecosystem.")
EOF

        if command -v python3 >/dev/null 2>&1; then
            python3 "$script_path" "$nginx_version" 2>&1 || echo "CVE check encountered an error"
        else
            echo "⚠ Python3 not available, skipping NVD/OSV CVE check"
        fi
        rm -f "$script_path"

        echo
        echo

        # 3. Check Docker Scout if available
        echo "=== Docker Scout Vulnerability Check ==="
        echo

        if command -v docker >/dev/null 2>&1; then
            if docker scout 2>/dev/null | grep -q "Usage"; then
                print_info "Running Docker Scout vulnerability scan..."
                if [[ "$nginx_type" == docker* ]] && [[ -n "$nginx_image" ]]; then
                    docker scout cves "$nginx_image" 2>&1 || echo "Docker Scout scan completed"
                else
                    echo "Docker Scout requires Docker image. Skipping for system Nginx."
                fi
            else
                echo "ℹ Docker Scout not available"
                echo "   To enable Docker Scout, install Docker Desktop or update Docker CLI"
            fi
        fi

        echo
        echo

        # 4. Summary and recommendations
        echo "=== Summary and Recommendations ==="
        echo
        echo "Vulnerability scanning completed using:"
        echo "  ✓ Trivy - Comprehensive vulnerability scanner"
        echo "  ✓ NVD API v2.0 - National Vulnerability Database"
        echo "  ✓ OSV API - Open Source Vulnerabilities database"
        echo "  ✓ Docker Scout (if available)"
        echo
        echo "Recommendations:"
        echo "  1. Review all HIGH and CRITICAL vulnerabilities"
        echo "  2. Update Nginx to the latest stable version"
        echo "  3. Update Alpine packages if using Docker"
        echo "  4. Apply security patches promptly"
        echo "  5. Run vulnerability scans regularly"
        echo "  6. Monitor CVE databases for new vulnerabilities"
        echo
        echo "For more information on vulnerabilities found:"
        echo "  - NVD: https://nvd.nist.gov/"
        echo "  - OSV: https://osv.dev/"
        echo "  - Trivy: https://aquasecurity.github.io/trivy/"

    } | tee "$report_file"

    print_success "CVE check completed."
    print_info "Report saved to: $report_file"
    log "CVE check completed for Nginx $nginx_version"
    return 0
}

# --- Scan Configuration ---
scan_configuration() {
    print_info "Scanning Nginx configuration for security issues..."

    # Detect nginx configuration location
    local config_file=""
    local config_dir=""
    local nginx_type=""

    # Try to detect nginx type and configuration location
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_type="system"
        config_file="/etc/nginx/nginx.conf"
        config_dir="/etc/nginx/conf.d"
        print_info "Detected system nginx installation"
    else
        # Try Docker containers
        local nginx_container
        nginx_container=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1 || echo "")
        if [[ -n "$nginx_container" ]]; then
            nginx_type="docker"
            # For Docker, check if configs are mounted from /opt/nginx
            if [[ -d "/opt/nginx/conf.d" ]]; then
                config_file="/opt/nginx/nginx.conf"
                config_dir="/opt/nginx/conf.d"
                print_info "Detected Docker nginx with /opt/nginx configuration"
            else
                # Use container's internal paths
                config_file="/etc/nginx/nginx.conf"
                config_dir="/etc/nginx/conf.d"
                print_info "Detected Docker nginx (using container paths)"
            fi
        fi
    fi

    if [[ -z "$config_file" ]]; then
        print_error "Unable to detect nginx configuration location"
        print_info "Please ensure nginx is running and try again"
        return 1
    fi

    # Create configuration scan report
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir" || {
        print_error "Failed to create report directory: $report_dir"
        return 1
    }
    local report_file
    report_file="$report_dir/config_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx Configuration Security Scan"
        echo "================================"
        echo "Date: $(date)"
        echo

        # Test configuration syntax
        echo "Configuration Syntax Check:"
        echo "------------------------"
        local config_test_passed=false
        local nginx_container=""

        if systemctl is-active --quiet nginx 2>/dev/null; then
            if nginx -t 2>/dev/null; then
                config_test_passed=true
                echo "Configuration syntax: ✓ Valid (System Nginx)"
            else
                echo "Configuration syntax: ✗ Invalid (System Nginx)"
                echo "Error details:"
                nginx -t 2>&1 || echo "Unable to retrieve error details"
            fi
        else
            # Try Docker containers
            local nginx_containers
            nginx_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx || echo "")
            if [[ -n "$nginx_containers" ]]; then
                while IFS= read -r container; do
                    if [[ -n "$container" ]]; then
                        if docker exec "$container" nginx -t 2>/dev/null; then
                            config_test_passed=true
                            echo "Configuration syntax: ✓ Valid (Docker: $container)"
                            nginx_container="$container"
                            break
                        else
                            echo "Configuration syntax: ✗ Invalid (Docker: $container)"
                            echo "Error details:"
                            docker exec "$container" nginx -t 2>&1 || echo "Unable to retrieve error details"
                            nginx_container="$container"
                            break
                        fi
                    fi
                done <<< "$nginx_containers"
            fi
        fi

        if [[ "$config_test_passed" == "false" ]] && [[ -z "$nginx_container" ]]; then
            echo "Configuration syntax: ⚠ Nginx not running or not accessible"
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

        # Hidden file protection (match ANY common patterns)
        if grep -q "location.*~.*\\." "$config_file" 2>/dev/null || \
        [[ -d "$config_dir" ]] && grep -q "location.*~.*\\." "$config_dir"/*.conf 2>/dev/null; then
            echo "Hidden file protection: ✓"
        else
            echo "Hidden file protection: ✗ (Add location ~ /\. { deny all; })"
        fi

        # Backup file protection (match location blocks with common extensions)
        if grep -q "location.*\(bak\|backup\|old\)" "$config_file" 2>/dev/null || \
        [[ -d "$config_dir" ]] && grep -q "location.*\(bak\|backup\|old\)" "$config_dir"/*.conf 2>/dev/null; then
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

    } > "$report_file" 2>&1

    print_success "Configuration scan completed."
    print_info "Report saved to: $report_file"
    log "Configuration scan completed: $report_file"
    return 0
}

# --- Function to Get Package Versions from Container ---
get_container_package_versions() {
    local container="$1"
    local versions_json="{\"nginx\":\"\",\"openssl\":\"\",\"libcrypto\":\"\"}"

    if [[ -z "$container" ]]; then
        echo "$versions_json"
        return 1
    fi

    # Get nginx version
    local nginx_version
    nginx_version=$(docker exec "$container" nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "")
    if [[ -n "$nginx_version" ]]; then
        versions_json=$(echo "$versions_json" | jq --arg v "$nginx_version" '.nginx = $v')
    fi

    # Get openssl version
    local openssl_version
    openssl_version=$(docker exec "$container" openssl version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-z]?' | head -n 1 || echo "")
    if [[ -n "$openssl_version" ]]; then
        versions_json=$(echo "$versions_json" | jq --arg v "$openssl_version" '.openssl = $v')
    fi

    # Get libcrypto version (same as openssl version)
    if [[ -n "$openssl_version" ]]; then
        versions_json=$(echo "$versions_json" | jq --arg v "$openssl_version" '.libcrypto = $v')
    fi

    echo "$versions_json"
}

# --- Container Security Scan ---
container_security_scan() {
    print_info "Running container security scan..."

    # Check if Docker nginx is running or restarting
    local nginx_container_info
    nginx_container_info=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -i nginx | head -1 || echo "")
    local nginx_container=""
    local nginx_status=""

    if [[ -n "$nginx_container_info" ]]; then
        nginx_container=$(echo "$nginx_container_info" | cut -f1)
        nginx_status=$(echo "$nginx_container_info" | cut -f2)

        # Check if container is restarting
        if [[ "$nginx_status" =~ "Restarting" ]]; then
            print_error "Container '$nginx_container' is in restart state (Status: $nginx_status)"
            print_info "This indicates a configuration error preventing Nginx from starting."
            print_info "Check container logs for details: docker logs $nginx_container --tail=50"
            print_info "Common issues:"
            print_info "  - Invalid nginx directives (e.g., 'more_clear_headers' requires nginx-mod-http-headers-more module)"
            print_info "  - Permission issues with log files"
            print_info "  - Syntax errors in nginx.conf"
            return 1
        fi
    fi

    if [[ -z "$nginx_container" ]]; then
        # Check if system nginx is running instead
        if systemctl is-active --quiet nginx 2>/dev/null; then
            print_info "System Nginx detected. Running system-level security scan..."
            # Create system nginx scan report
            local report_dir="/opt/nginx/security_reports"
            mkdir -p "$report_dir" || {
                print_error "Failed to create report directory: $report_dir"
                return 1
            }
            local report_file
            report_file="$report_dir/system_scan_$(date +%Y%m%d_%H%M%S).txt"

            {
                echo "Nginx System Security Scan"
                echo "==========================="
                echo "Date: $(date)"
                echo

                echo "Nginx Information:"
                echo "------------------"
                echo "Version: $(nginx -v 2>&1 || echo 'Unable to determine')"
                echo "Status: $(systemctl is-active nginx 2>/dev/null || echo 'unknown')"
                echo

                echo "Process Information:"
                echo "-------------------"
                pgrep -l nginx || echo "No nginx processes found"
                echo

                echo "Configuration Files:"
                echo "-------------------"
                echo "Main config: /etc/nginx/nginx.conf"
                echo "Config directory: /etc/nginx/conf.d/"
                echo "Sites available: /etc/nginx/sites-available/"
                echo "Sites enabled: /etc/nginx/sites-enabled/"
                echo

                echo "Security Recommendations:"
                echo "----------------------"
                echo "1. Regularly update Nginx package"
                echo "2. Monitor access logs for suspicious activity"
                echo "3. Use security headers"
                echo "4. Implement rate limiting"
                echo "5. Keep SSL certificates updated"

            } > "$report_file" 2>&1

            print_success "System security scan completed."
            print_info "Report saved to: $report_file"
            log "System security scan completed: $report_file"
            return 0
        else
            print_error "Nginx is not running (neither Docker nor system)."
            return 0
        fi
    fi

    # Create container scan report
    local report_dir="/opt/nginx/security_reports"
    mkdir -p "$report_dir" || {
        print_error "Failed to create report directory: $report_dir"
        return 1
    }
    local report_file
    report_file="$report_dir/container_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx Container Security Scan"
        echo "============================="
        echo "Date: $(date)"
        echo

        # Container information
        echo "Container Information:"
        echo "-------------------"
        docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0] | {
            Name: .Name,
            Image: .Config.Image,
            Created: .Created,
            State: .State.Status,
            Ports: .NetworkSettings.Ports
        }' 2>/dev/null || echo "Unable to retrieve container information"
        echo

        # Security settings check
        echo "Security Settings:"
        echo "----------------"

        # Check if running as root
        local user_id
        user_id=$(docker exec "$nginx_container" id -u 2>/dev/null || echo "0")
        if [[ "$user_id" == "0" ]]; then
            echo "Running as root: ✗ (Security risk)"
        else
            echo "Running as non-root: ✓ (User ID: $user_id)"
        fi

        # Check for privileged mode
        local privileged
        privileged=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].Host.Privileged' 2>/dev/null || echo "false")
        if [[ "$privileged" == "true" ]]; then
            echo "Privileged mode: ✗ (Security risk)"
        else
            echo "Privileged mode: ✓ (Disabled)"
        fi

        # Check for capabilities
        echo "Capabilities:"
        docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].Host.Capabilities[]' 2>/dev/null || echo "No additional capabilities"

        # Check for security options
        echo "Security Options:"
        docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].HostSecurityOpt[]' 2>/dev/null || echo "No security options"

        # Check for read-only filesystem
        local read_only
        read_only=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].HostConfig.ReadonlyRootfs' 2>/dev/null || echo "false")
        if [[ "$read_only" == "true" ]]; then
            echo "Read-only filesystem: ✓"
        else
            echo "Read-only filesystem: ✗ (Consider enabling)"
        fi

        # Check resource limits
        echo
        echo "Resource Limits:"
        echo "---------------"

        local memory_limit
        memory_limit=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].HostConfig.Memory' 2>/dev/null || echo "0")
        if [[ "$memory_limit" != "0" ]]; then
            echo "Memory limit: ✓ ($(echo "$memory_limit" | awk '{print $1/1024/1024" MB"}'))"
        else
            echo "Memory limit: ✗ (Unlimited)"
        fi

        local cpu_limit
        local nano_cpus
        nano_cpus=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].HostConfig.NanoCpus' 2>/dev/null || echo "0")
        cpu_limit=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].HostConfig.CpuShares' 2>/dev/null || echo "0")
        
        if [[ "$nano_cpus" != "0" && "$nano_cpus" != "null" ]]; then
            # NanoCpus is in units of 10^-9 CPUs
            local cpus_count
            cpus_count=$(echo "scale=2; $nano_cpus / 1000000000" | bc 2>/dev/null || echo "Unknown")
            echo "CPU limit: ✓ ($cpus_count CPUs)"
        elif [[ "$cpu_limit" != "0" && "$cpu_limit" != "1024" && "$cpu_limit" != "null" ]]; then
            echo "CPU limit: ✓ (Shares: $cpu_limit)"
        else
            echo "CPU limit: ✗ (Unlimited)"
        fi

        # Network configuration
        echo
        echo "Network Configuration:"
        echo "--------------------"

        local network_mode
        network_mode=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].HostConfig.NetworkMode' 2>/dev/null || echo "unknown")
        echo "Network mode: $network_mode"
        
        if [[ "$network_mode" == "bridge" ]]; then
            echo "Bridge network: ✓ (Isolated)"
        else
            echo "Network mode: ⚠ (Review security implications)"
        fi

        # Port bindings
        echo "Port bindings:"
        docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].NetworkSettings.Ports | to_entries[] | "\(.key): \(.value | if . != null then .[0].HostPort else "not bound" end)"' 2>/dev/null || echo "Unable to retrieve port bindings"

        # Volume mounts
        echo
        echo "Volume Mounts:"
        echo "--------------"
        docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].Mounts[] | "\(.Type): \(.Source) -> \(.Destination) (RW: \(.RW))"' 2>/dev/null || echo "Unable to retrieve volume mounts"

        # Recommendations
        echo
        echo "Container Security Recommendations:"
        echo "--------------------------------"
        echo "1. Run as non-root user"
        echo "2. Use read-only filesystem"
        echo "3. Set resource limits"
        echo "4. Use bridge networking"
        echo "5. Minimize exposed ports"
        echo "6. Use security profiles (SELinux)"
        echo "7. Regular image updates"
        echo "8. Scan images for vulnerabilities"
        echo

        # Automated Vulnerability Scanning with Trivy
        echo "=== Automated Vulnerability Scan ==="
        echo

        if command -v docker >/dev/null 2>&1; then
            print_info "Running comprehensive vulnerability scan with Trivy..."

            # Get the image name from the container
            local image_name
            image_name=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].Config.Image' || echo "")
            
            if [[ -n "$image_name" ]]; then
                echo "Scanning image: $image_name"
                echo

                # Run Trivy scan with multiple output formats
                echo "--- Trivy Vulnerability Report ---"
                docker run --rm \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    aquasec/trivy:latest \
                    image "$image_name" \
                    --severity HIGH,CRITICAL,MEDIUM \
                    --format table \
                    --no-progress \
                    --scanners vuln,misconfig,secret \
                    2>&1 || echo "Trivy scan completed with warnings"

                echo
                echo "--- Trivy JSON Output for Analysis ---"
                local trivy_json
                trivy_json=$(docker run --rm \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    aquasec/trivy:latest \
                    image "$image_name" \
                    --severity HIGH,CRITICAL \
                    --format json \
                    --no-progress \
                    --scanners vuln,misconfig,secret \
                    2>/dev/null || echo "{}")

                # Parse and summarize vulnerabilities
                local total_vulns
                total_vulns=$(echo "$trivy_json" | jq -r '.Results[].Vulnerabilities | length' 2>/dev/null | awk '{s+=$1} END {print s+0}')
                local critical_vulns
                critical_vulns=$(echo "$trivy_json" | jq -r '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
                local high_vulns
                high_vulns=$(echo "$trivy_json" | jq -r '[.Results[].Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo "0")
                local medium_vulns
                medium_vulns=$(echo "$trivy_json" | jq -r '[.Results[].Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' 2>/dev/null || echo "0")

                echo
                echo "Vulnerability Summary:"
                echo "  Total: $total_vulns"
                echo "  CRITICAL: $critical_vulns"
                echo "  HIGH: $high_vulns"
                echo "  MEDIUM: $medium_vulns"
                echo

                # Display top critical vulnerabilities
                if [[ "$critical_vulns" -gt 0 ]]; then
                    echo "Top CRITICAL Vulnerabilities:"
                    echo "$trivy_json" | jq -r '.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL") | "\nCVE: \(.VulnerabilityID)\nPackage: \(.PkgName)\nVersion: \(.InstalledVersion)\nFixed in: \(.FixedVersion // "N/A")\nTitle: \(.Title)"' 2>/dev/null | head -50 || echo "Unable to parse critical vulnerabilities"
                    echo
                fi

                # Display top high vulnerabilities
                if [[ "$high_vulns" -gt 0 ]]; then
                    echo "Top HIGH Vulnerabilities:"
                    echo "$trivy_json" | jq -r '.Results[].Vulnerabilities[]? | select(.Severity == "HIGH") | "\nCVE: \(.VulnerabilityID)\nPackage: \(.PkgName)\nVersion: \(.InstalledVersion)\nFixed in: \(.FixedVersion // "N/A")\nTitle: \(.Title)"' 2>/dev/null | head -50 || echo "Unable to parse high vulnerabilities"
                    echo
                fi

                # Save detailed JSON report
                local json_report_file
                json_report_file="$report_dir/trivy_detailed_$(date +%Y%m%d_%H%M%S).json"
                echo "$trivy_json" > "$json_report_file" 2>/dev/null || echo "Failed to save JSON report"
                echo "Detailed JSON report saved to: $json_report_file"
                echo
            else
                echo "⚠ Unable to determine container image name. Skipping Trivy scan."
            fi
        else
            echo "⚠ Docker not available. Skipping Trivy scan."
        fi

        echo
        echo "=== Vulnerability Database Cross-Check ==="
        echo

        # Create Python script for NVD and OSV cross-check
        local script_path="$NGINX_SCRIPTS_TEMP/container_vuln_check_$$.py"
        cat > "$script_path" << 'EOF'
#!/usr/bin/env python3
import requests
import json
import sys
from datetime import datetime, timedelta

def check_nvd_for_package(package_name, version):
    """Check NVD database for package vulnerabilities"""
    try:
        base_url = "https://services.nvd.nist.gov/rest/json/cves/2.0"
        # Note: NVD API requires both pubStartDate and pubEndDate when using date filters
        # Maximum allowable range is 120 consecutive days

        # Example CPE for nginx core (adjust version if you want a specific one)
        # Nginx CPEs in NVD look like cpe:2.3:a:nginx:nginx:1.29.4:*:*:*:*:*:*:*
        cpe_name = f"cpe:2.3:a:nginx:nginx:{version}:*:*:*:*:*:*:*"
        params = {
            'cpeName': cpe_name,
            'resultsPerPage': 10,
            'pubStartDate': (datetime.now() - timedelta(days=120)).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'pubEndDate': datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
        }

        response = requests.get(base_url, params=params, timeout=15)
        if response.status_code == 200:
            data = response.json()
            return len(data.get('vulnerabilities', []))
        return 0
    except:
        return 0

def check_osv_for_package(package_name, version, ecosystem="Alpine"):
    """Check OSV database for package vulnerabilities"""
    try:
        url = "https://api.osv.dev/v1/query"
        payload = {
            "package": {
                "name": package_name,
                "ecosystem": ecosystem
            },
            "version": version
        }

        response = requests.post(url, json=payload, timeout=10)

        # Debug: log response status
        print(f"  OSV query for {package_name} {version} in {ecosystem}: HTTP {response.status_code}")

        if response.status_code == 200:
            data = response.json()
            vulns = data.get('vulns', [])
            if vulns:
                print(f"  Found {len(vulns)} vulnerabilities")
            else:
                print(f"  No vulnerabilities found in this ecosystem")
            return len(vulns)
        elif response.status_code == 404:
            print(f"  Package/version not found in OSV database")
            return 0
        else:
            print(f"  OSV API error: HTTP {response.status_code}")
            if response.text:
                print(f"  Response: {response.text[:200]}")
            return 0
    except Exception as e:
        print(f"  Exception querying OSV: {e}")
        return 0

if __name__ == '__main__':
    print("Cross-checking vulnerabilities with external databases...")
    print()

    # Get package versions from container (passed as JSON argument)
    import json
    if len(sys.argv) > 1:
        try:
            versions = json.loads(sys.argv[1])
            packages = [
                ("nginx", versions.get("nginx", "unknown")),
                ("openssl", versions.get("openssl", "unknown")),
                ("libcrypto", versions.get("libcrypto", "unknown"))
            ]
            print("Using detected package versions from container:")
        except:
            print("Warning: Could not parse version information, using fallback")
            packages = [
                ("nginx", "unknown"),
                ("openssl", "unknown"),
                ("libcrypto", "unknown")
            ]
    else:
        print("Warning: No version information provided, using fallback")
        packages = [
            ("nginx", "unknown"),
            ("openssl", "unknown"),
            ("libcrypto", "unknown")
        ]
    print()

    for pkg, ver in packages:
        if ver == "unknown":
            print(f"{pkg}: Version unknown - skipping vulnerability check")
            print()
            continue

        nvd_count = check_nvd_for_package(pkg, ver)
        osv_count = check_osv_for_package(pkg, ver)

        print(f"{pkg} {ver}:")
        print(f"  NVD: {nvd_count} vulnerabilities")
        print(f"  OSV: {osv_count} vulnerabilities")
        print()
EOF

        # Get actual package versions from container
        local package_versions
        package_versions=$(get_container_package_versions "$nginx_container")

        if command -v python3 >/dev/null 2>&1; then
            python3 "$script_path" "$package_versions" 2>&1 || echo "Cross-check encountered an error"
        else
            echo "⚠ Python3 not available, skipping database cross-check"
        fi
        rm -f "$script_path"

        echo
        echo "=== Final Security Assessment ==="
        echo
        echo "Vulnerability scanning completed using:"
        echo "  ✓ Trivy - Comprehensive container vulnerability scanner"
        echo "  ✓ NVD API - National Vulnerability Database"
        echo "  ✓ OSV API - Open Source Vulnerabilities database"
        echo
        echo "Next Steps:"
        echo "  1. Review all CRITICAL and HIGH vulnerabilities"
        echo "  2. Update base image to latest version"
        echo "  3. Rebuild container with updated packages"
        echo "  4. Implement security hardening measures"
        echo "  5. Schedule regular vulnerability scans"
        echo "  6. Set up automated vulnerability alerts"
        echo

    } > "$report_file" 2>&1

    print_success "Container security scan completed."
    print_info "Report saved to: $report_file"
    log "Container security scan completed: $report_file"
    return 0
}

# --- Setup Automated Scanning ---
setup_automated_scanning() {
    print_info "Setting up automated security scanning..."

    # Create scripts directory
    mkdir -p /opt/nginx/scripts || {
        print_error "Failed to create scripts directory"
        return 1
    }

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

    local report_file
    report_file="$REPORT_DIR/auto_scan_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Automated Security Scan Report"
        echo "============================="
        echo "Date: $(date)"
        echo

        # Basic health check
        if curl -f http://localhost:8080/health >/dev/null 2>&1; then
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
        local cert_file=""
        if [[ -f /opt/nginx/certs/cert.pem ]]; then
            cert_file="/opt/nginx/certs/cert.pem"
        else
            cert_file=$(find /opt/nginx/certs/ -maxdepth 1 -name "*.pem" ! -name "cert.pem" | head -n 1)
        fi

        if [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]]; then
            local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
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

        # Check nginx status
        local nginx_status="✗ Not running"
        local nginx_container=""
        local container_status=""

        if systemctl is-active --quiet nginx 2>/dev/null; then
            nginx_status="✓ Running (System)"
        else
            # Try Docker containers (including restarting ones)
            local nginx_container_info=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -i nginx | head -1 || echo "")
            if [[ -n "$nginx_container_info" ]]; then
                nginx_container=$(echo "$nginx_container_info" | cut -f1)
                container_status=$(echo "$nginx_container_info" | cut -f2)

                if [[ "$container_status" =~ "Up" ]]; then
                    nginx_status="✓ Running (Docker: $nginx_container)"
                elif [[ "$container_status" =~ "Restarting" ]]; then
                    nginx_status="⚠ Restarting (Docker: $nginx_container)"
                else
                    nginx_status="✗ Not running (Docker: $nginx_container)"
                fi
            fi
        fi
        echo "Nginx status: $nginx_status"

        # Check Hardening
        if [[ -n "$nginx_container" ]]; then
            local read_only=$(docker inspect "$nginx_container" --format='{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || echo "false")
            if [[ "$read_only" == "true" ]]; then
                echo "Read-only FS: ✓"
            else
                echo "Read-only FS: ✗"
            fi

            local nano_cpus=$(docker inspect "$nginx_container" --format='{{.HostConfig.NanoCpus}}' 2>/dev/null || echo "0")
            if [[ "$nano_cpus" != "0" && "$nano_cpus" != "null" ]]; then
                local cpus_count=$(echo "scale=2; $nano_cpus / 1000000000" | bc 2>/dev/null || echo "Unknown")
                echo "CPU limit: ✓ ($cpus_count CPUs)"
            else
                echo "CPU limit: ✗ (Unlimited)"
            fi
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
}   # End of run_security_scan function

# Main execution
run_security_scan
EOF

    chmod +x /opt/nginx/scripts/auto_security_scan.sh || print_error "Failed to set execute permissions"

    # Setup cron job for automated scanning
    if ! crontab -l 2>/dev/null | grep -q "auto_security_scan.sh"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * /opt/nginx/scripts/auto_security_scan.sh") | crontab - 2>/dev/null || print_error "Failed to setup cron job"
        print_success "Automated security scan scheduled for daily 2:00 AM."
    else
        print_info "Automated security scan already scheduled."
    fi

    # Create comprehensive vulnerability check script
    print_info "Regenerating vulnerability check script..."
    cat > /opt/nginx/scripts/vulnerability_check.sh << 'EOF'
#!/bin/bash

# Comprehensive vulnerability check script
REPORT_DIR="/opt/nginx/security_reports"
LOG_FILE="/var/log/nginx/vulnerability_check.log"

# Create directories
mkdir -p "$REPORT_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Temporary directory for Python scripts
NGINX_SCRIPTS_TEMP="/opt/nginx/scripts/temp"
mkdir -p "$NGINX_SCRIPTS_TEMP"

# Function to get package versions from container
get_container_package_versions() {
    local container="$1"
    local versions_json="{\"nginx\":\"\",\"openssl\":\"\",\"libcrypto\":\"\"}"

    if [[ -z "$container" ]]; then
        echo "$versions_json"
        return 1
    fi

    # Get nginx version
    local nginx_version
    nginx_version=$(docker exec "$container" nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "")
    if [[ -n "$nginx_version" ]]; then
        versions_json=$(echo "$versions_json" | jq --arg v "$nginx_version" '.nginx = $v')
    fi

    # Get openssl version
    local openssl_version
    openssl_version=$(docker exec "$container" openssl version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-z]?' | head -n 1 || echo "")
    if [[ -n "$openssl_version" ]]; then
        versions_json=$(echo "$versions_json" | jq --arg v "$openssl_version" '.openssl = $v')
    fi

    # Get libcrypto version (same as openssl version)
    if [[ -n "$openssl_version" ]]; then
        versions_json=$(echo "$versions_json" | jq --arg v "$openssl_version" '.libcrypto = $v')
    fi

    echo "$versions_json"
}

# Function to run Trivy scan
run_trivy_scan() {
    log_message "Starting Trivy vulnerability scan"

    local report_file="$REPORT_DIR/trivy_scan_$(date +%Y%m%d_%H%M%S).txt"

    # Determine scan target
    local trivy_command=""
    local trivy_target=""
    local nginx_image=""

    # Check for Docker nginx
    local nginx_container=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1 || echo "")

    if [[ -n "$nginx_container" ]]; then
        nginx_image=$(docker inspect "$nginx_container" 2>/dev/null | jq -r '.[0].Config.Image' || echo "")
        if [[ -n "$nginx_image" ]]; then
            trivy_command="image"
            trivy_target="$nginx_image"
            log_message "Scanning Docker image: $nginx_image"
        fi
    else
        # Scan system filesystem
        trivy_command="fs"
        trivy_target="/"
        log_message "Scanning system filesystem"
    fi

    if [[ -n "$trivy_command" ]] && [[ -n "$trivy_target" ]]; then
        # Run Trivy scan
        docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$REPORT_DIR":/output \
            aquasec/trivy:latest \
            $trivy_command \
            "$trivy_target" \
            --severity HIGH,CRITICAL,MEDIUM \
            --format table \
            --no-progress \
            --scanners vuln,misconfig,secret \
            --output /output/trivy_scan_$(date +%Y%m%d_%H%M%S).txt 2>&1 || log_message "Trivy scan completed with warnings"

        # Get JSON output for analysis
        local trivy_json=$(docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:latest \
            $trivy_command \
            "$trivy_target" \
            --severity HIGH,CRITICAL \
            --format json \
            --no-progress \
            --scanners vuln,misconfig,secret \
            2>/dev/null || echo "{}")

        # Parse vulnerabilities
        local total_vulns=$(echo "$trivy_json" | jq -r '.Results[].Vulnerabilities | length' 2>/dev/null | awk '{s+=$1} END {print s+0}')
        local critical_vulns=$(echo "$trivy_json" | jq -r '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
        local high_vulns=$(echo "$trivy_json" | jq -r '[.Results[].Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo "0")

        log_message "Trivy scan completed: $total_vulns total vulnerabilities ($critical_vulns CRITICAL, $high_vulns HIGH)"

        # Save detailed JSON report
        local json_report_file="$REPORT_DIR/trivy_detailed_$(date +%Y%m%d_%H%M%S).json"
        echo "$trivy_json" > "$json_report_file" 2>/dev/null || log_message "Failed to save JSON report"

        # Alert if critical vulnerabilities found
        if [[ "$critical_vulns" -gt 0 ]]; then
            log_message "ALERT: Found $critical_vulns CRITICAL vulnerabilities"
            return 1
        fi
    else
        log_message "Unable to determine scan target. Skipping Trivy scan."
    fi

    return 0
}

# Function to check NVD database
check_nvd_database() {
    log_message "Checking NVD database for vulnerabilities"

    local report_file="$REPORT_DIR/nvd_check_$(date +%Y%m%d_%H%M%S).txt"

    # Get Nginx version
    local nginx_version=""
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "")
    else
        local nginx_container=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1 || echo "")
        if [[ -n "$nginx_container" ]]; then
            nginx_version=$(docker exec "$nginx_container" nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || echo "")
        fi
    fi

    if [[ -n "$nginx_version" ]]; then
        # Create Python script for NVD check
        local script_path="$NGINX_SCRIPTS_TEMP/nvd_check_$$.py"
        cat > "$script_path" << 'PYEOF'
#!/usr/bin/env python3
import requests
import sys
import time
from datetime import datetime, timedelta

def check_nvd(version):
    try:
        base_url = "https://services.nvd.nist.gov/rest/json/cves/2.0"
        # Note: NVD API requires both pubStartDate and pubEndDate when using date filters
        # Maximum allowable range is 120 consecutive days

        # Example CPE for nginx core (adjust version if you want a specific one)
        # Nginx CPEs in NVD look like cpe:2.3:a:nginx:nginx:1.29.4:*:*:*:*:*:*:*
        cpe_name = f"cpe:2.3:a:nginx:nginx:{version}:*:*:*:*:*:*:*"
        params = {
            'cpeName': cpe_name,
            'resultsPerPage': 20,
            'pubStartDate': (datetime.now() - timedelta(days=120)).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'pubEndDate': datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
        }

        headers = {
            'User-Agent': 'Nginx-Vulnerability-Scanner/1.0'
        }

        # Add retry logic for rate limiting
        max_retries = 3
        for attempt in range(max_retries):
            try:
                response = requests.get(base_url, params=params, headers=headers, timeout=30)

                if response.status_code == 200:
                    data = response.json()
                    vulns = data.get('vulnerabilities', [])

                    critical_count = 0
                    high_count = 0

                    for vuln in vulns:
                        cve = vuln['cve']
                        metrics = cve.get('metrics', {})
                        cvss_data = metrics.get('cvssMetricV31', []) or metrics.get('cvssMetricV30', [])

                        if cvss_data:
                            severity = cvss_data[0].get('cvssData', {}).get('baseSeverity', '')
                            if severity == 'CRITICAL':
                                critical_count += 1
                            elif severity == 'HIGH':
                                high_count += 1

                    print(f"Found {len(vulns)} vulnerabilities for nginx {version}")
                    print(f"CRITICAL: {critical_count}, HIGH: {high_count}")
                    return critical_count + high_count
                elif response.status_code == 403:
                    # Rate limited
                    if attempt < max_retries - 1:
                        wait_time = 6 * (attempt + 1)
                        print(f"Rate limited by NVD API. Waiting {wait_time} seconds before retry...")
                        time.sleep(wait_time)
                        continue
                    else:
                        print("Error: NVD API rate limit exceeded after multiple retries")
                        return 0
                elif response.status_code == 404:
                    print("Error: NVD API endpoint not found (404)")
                    print("Note: NVD API may be temporarily unavailable")
                    return 0
                else:
                    print(f"Error: NVD API returned status {response.status_code}")
                    return 0
            except requests.exceptions.Timeout:
                if attempt < max_retries - 1:
                    print(f"Request timed out. Retrying... (Attempt {attempt + 1}/{max_retries})")
                    time.sleep(2)
                    continue
                else:
                    print("Error: Request to NVD API timed out after multiple retries")
                    return 0

        return 0
    except Exception as e:
        print(f"Error checking NVD: {e}")
        return 0

if __name__ == '__main__':
    version = sys.argv[1] if len(sys.argv) > 1 else "1.0"
    check_nvd(version)
PYEOF

        if command -v python3 >/dev/null 2>&1; then
            python3 "$script_path" "$nginx_version" 2>&1 | tee -a "$report_file" || log_message "NVD check encountered an error"
            rm -f "$script_path"
        else
            log_message "Python3 not available, skipping NVD check"
        fi
    else
        log_message "Unable to determine Nginx version. Skipping NVD check."
    fi

    return 0
} # End of check_nvd_database function

# Function to check OSV database
check_osv_database() {
    log_message "Checking OSV database for vulnerabilities"

    local report_file="$REPORT_DIR/osv_check_$(date +%Y%m%d_%H%M%S).txt"

    # Create Python script for OSV check
    local script_path="$NGINX_SCRIPTS_TEMP/osv_check_$$.py"
    cat > "$script_path" << 'PYEOF'
#!/usr/bin/env python3
import requests
import sys

def check_osv(package, version, ecosystem="Alpine"):
    try:
        url = "https://api.osv.dev/v1/query"
        payload = {
            "package": {
                "name": package,
                "ecosystem": ecosystem
            },
            "version": version
        }

        response = requests.post(url, json=payload, timeout=15)

        # Debug: log response status
        print(f"  OSV query for {package} {version} in {ecosystem}: HTTP {response.status_code}")

        if response.status_code == 200:
            data = response.json()
            vulns = data.get('vulns', [])
            if vulns:
                print(f"  Found {len(vulns)} vulnerabilities")
            else:
                print(f"  No vulnerabilities found in this ecosystem")
            return len(vulns)
        elif response.status_code == 404:
            print(f"  Package/version not found in OSV database")
            return 0
        else:
            print(f"  OSV API error: HTTP {response.status_code}")
            if response.text:
                print(f"  Response: {response.text[:200]}")
            return 0
    except Exception as e:
        print(f"  Exception querying OSV: {e}")
        return 0

if __name__ == '__main__':
    import json

    # Get package versions from container (passed as JSON argument)
    if len(sys.argv) > 1:
        try:
            versions = json.loads(sys.argv[1])
            packages = [
                ("nginx", versions.get("nginx", "unknown")),
                ("openssl", versions.get("openssl", "unknown")),
                ("libcrypto", versions.get("libcrypto", "unknown"))
            ]
            print("Using detected package versions from container:")
        except:
            print("Warning: Could not parse version information, using fallback")
            packages = [
                ("nginx", "unknown"),
                ("openssl", "unknown"),
                ("libcrypto", "unknown")
            ]
    else:
        print("Warning: No version information provided, using fallback")
        packages = [
            ("nginx", "unknown"),
            ("openssl", "unknown"),
            ("libcrypto", "unknown")
        ]
    print()

    total_vulns = 0
    for pkg, ver in packages:
        if ver == "unknown":
            print(f"{pkg}: Version unknown - skipping vulnerability check")
            continue
        total_vulns += check_osv(pkg, ver)

    print(f"Total vulnerabilities: {total_vulns}")
PYEOF

    # Get actual package versions from container
    local package_versions_json="{}"
    local nginx_container=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1 || echo "")

    if [[ -n "$nginx_container" ]]; then
        package_versions_json=$(get_container_package_versions "$nginx_container")
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 "$script_path" "$package_versions_json" 2>&1 | tee -a "$report_file" || log_message "OSV check encountered an error"
        rm -f "$script_path"
    else
        log_message "Python3 not available, skipping OSV check"
    fi

    return 0
}

# Main execution
log_message "Starting comprehensive vulnerability check"

# Run all vulnerability checks
run_trivy_scan
check_nvd_database
check_osv_database

log_message "Comprehensive vulnerability check completed"
EOF

    chmod +x /opt/nginx/scripts/vulnerability_check.sh || print_error "Failed to set execute permissions"

    # Setup additional cron jobs for vulnerability scanning
    if ! crontab -l 2>/dev/null | grep -q "vulnerability_check.sh"; then
        (crontab -l 2>/dev/null; echo "0 4 * * * /opt/nginx/scripts/vulnerability_check.sh") | crontab - 2>/dev/null || print_error "Failed to setup vulnerability check cron job"
        print_success "Vulnerability check scheduled for daily 4:00 AM."
    fi

    # Create weekly scan script
    cat > /opt/nginx/scripts/weekly_scan.sh << 'EOF'
#!/bin/bash
# Weekly comprehensive security scan

REPORT_DIR="/opt/nginx/security_reports"
LOG_FILE="/var/log/nginx/weekly_scan.log"

# Create directories
mkdir -p "$REPORT_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_message "Starting weekly comprehensive security scan"

# Run automated security scan
/opt/nginx/scripts/auto_security_scan.sh

# Run comprehensive vulnerability check
/opt/nginx/scripts/vulnerability_check.sh

# Generate weekly summary report
local report_file="$REPORT_DIR/weekly_summary_$(date +%Y%m%d).txt"
{
    echo "Weekly Security Scan Summary"
    echo "============================"
    echo "Date: $(date)"
    echo "Server: $(hostname)"
    echo

    echo "Vulnerability Reports Generated:"
    echo "--------------------------------"
    ls -lh "$REPORT_DIR"/*.txt 2>/dev/null | tail -10 || echo "No reports found"
    echo

    echo "Recommendations:"
    echo "---------------"
    echo "1. Review all vulnerability reports"
    echo "2. Update packages with known vulnerabilities"
    echo "3. Apply security patches"
    echo "4. Review and update security configurations"
    echo "5. Schedule regular scans"
} > "$report_file"

log_message "Weekly comprehensive scan completed. Report: $report_file"
EOF
    chmod +x /opt/nginx/scripts/weekly_scan.sh || print_error "Failed to set execute permissions"

    # Setup weekly comprehensive scan
    if ! crontab -l 2>/dev/null | grep -q "weekly_scan"; then
        (crontab -l 2>/dev/null; echo "0 3 * * 0 /opt/nginx/scripts/weekly_scan.sh") | crontab - 2>/dev/null || print_error "Failed to setup weekly cron job"
        print_success "Weekly comprehensive scan scheduled for Sundays 3:00 AM."
    fi

    # Create monthly scan script
    cat > /opt/nginx/scripts/monthly_scan.sh << 'EOF'
#!/bin/bash
# Monthly comprehensive security scan

REPORT_DIR="/opt/nginx/security_reports"
LOG_FILE="/var/log/nginx/monthly_scan.log"

# Create directories
mkdir -p "$REPORT_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_message "Starting monthly comprehensive security scan"

# Run all security checks
/opt/nginx/scripts/auto_security_scan.sh
/opt/nginx/scripts/vulnerability_check.sh

# Run container security scan if Docker is available
if command -v docker >/dev/null 2>&1; then
    docker scan --accept-license nginx > "$REPORT_DIR/docker_scan_$(date +%Y%m).txt" 2>/dev/null || true
fi

# Archive old reports
log_message "Archiving old security reports"
mkdir -p "$REPORT_DIR/archive/$(date +%Y)"
find "$REPORT_DIR" -maxdepth 1 -name "*.txt" -mtime +30 -exec mv {} "$REPORT_DIR/archive/$(date +%Y)/" \;

log_message "Monthly comprehensive security scan completed"

# Generate monthly summary
local report_file="$REPORT_DIR/monthly_summary_$(date +%Y%m).txt"
{
    echo "Monthly Security Scan Summary"
    echo "============================"
    echo "Date: $(date)"
    echo "Server: $(hostname)"
    echo "Month: $(date +%Y-%m)"
    echo

    echo "All Security Reports:"
    echo "--------------------"
    ls -lh "$REPORT_DIR"/*.txt 2>/dev/null | tail -20 || echo "No reports found"
    echo

    echo "Vulnerability Trends:"
    echo "--------------------"
    echo "Check reports for patterns and trends"
    echo

    echo "Action Items:"
    echo "-------------"
    echo "1. Address all CRITICAL vulnerabilities"
    echo "2. Plan updates for HIGH vulnerabilities"
    echo "3. Review security policies"
    echo "4. Update documentation"
    echo "5. Schedule training if needed"
} > "$report_file"

log_message "Monthly comprehensive scan completed. Report: $report_file"
EOF

    chmod +x /opt/nginx/scripts/monthly_scan.sh || print_error "Failed to set execute permissions"

    # Setup monthly comprehensive scan
    if ! crontab -l 2>/dev/null | grep -q "monthly_scan"; then
        (crontab -l 2>/dev/null; echo "0 5 1 * * /opt/nginx/scripts/monthly_scan.sh") | crontab - 2>/dev/null || print_error "Failed to setup monthly cron job"
        print_success "Monthly comprehensive scan scheduled for 1st of each month at 5:00 AM."
    fi

    print_success "Automated security scanning configured."
    print_info "Scheduled scans:"
    print_info "  - Daily security scan: 2:00 AM"
    print_info "  - Daily vulnerability check: 4:00 AM"
    print_info "  - Weekly comprehensive scan: Sundays 3:00 AM"
    print_info "  - Monthly comprehensive scan: 1st of month at 5:00 AM"
    log "Automated security scanning setup completed"
    return 0
}

# --- Setup Auto-Update ---
setup_auto_update() {
    print_section "Nginx Auto-Update Setup"

    # Check if Docker is available
    local docker_available=false
    if command -v docker >/dev/null 2>&1; then
        docker_available=true
        print_info "Docker detected - can update Docker images"
    fi

    # Check if system nginx is available
    local system_nginx=false
    if systemctl is-active --quiet nginx 2>/dev/null || command -v nginx >/dev/null 2>&1; then
        system_nginx=true
        print_info "System Nginx detected - can update system packages"
    fi

    if [[ "$docker_available" == "false" ]] && [[ "$system_nginx" == "false" ]]; then
        print_error "Neither Docker nor system Nginx detected. Cannot setup auto-update."
        return 1
    fi

    # Ask for update frequency
    printf '%s\n' "${CYAN}Choose update frequency:${NC}"
    printf '  1) Daily (recommended for security patches)%s\n' "$NC"
    printf '  2) Weekly%s\n' "$NC"
    printf '  3) Monthly%s\n' "$NC"

    local update_frequency=""
    local cron_schedule=""
    local frequency_name=""

    while true; do
        read -rp "$(printf '%s' "${CYAN}Enter choice (1-3) [1]: ${NC}")" freq_choice
        freq_choice=${freq_choice:-1}
        case $freq_choice in
            1)
                update_frequency="daily"
                cron_schedule="0 3 * * *"
                frequency_name="Daily at 3:00 AM"
                break
                ;;
            2)
                update_frequency="weekly"
                cron_schedule="0 3 * * 0"
                frequency_name="Weekly on Sundays at 3:00 AM"
                break
                ;;
            3)
                update_frequency="monthly"
                cron_schedule="0 3 1 * *"
                frequency_name="Monthly on the 1st at 3:00 AM"
                break
                ;;
            *)
                print_error "Invalid choice. Please enter 1-3."
                ;;
        esac
    done

    # Ask for notification email (optional)
    local notify_email=""
    read -rp "$(printf '%s' "${CYAN}Enter email for update notifications (leave blank to skip): ${NC}")" notify_email

    # Create scripts directory
    mkdir -p /opt/nginx/scripts || {
        print_error "Failed to create scripts directory"
        return 1
    }

    # Create auto-update script (idempotent - only write if different)
    local script_hash=""
    if [[ -f /opt/nginx/scripts/auto_update.sh ]]; then
        script_hash=$(md5sum /opt/nginx/scripts/auto_update.sh 2>/dev/null | awk '{print $1}' || echo "")
    fi

    # Write script to temp file first
    local temp_script="/opt/nginx/scripts/auto_update.sh.tmp"
    cat > "$temp_script" << 'EOF'
#!/bin/bash

# Nginx Auto-Update Script
# Updates Nginx, Alpine packages, and applies security patches
LOG_FILE="/var/log/nginx/auto_update.log"
REPORT_DIR="/opt/nginx/security_reports"
LOCK_FILE="/var/run/nginx_auto_update.lock"

# Create directories
mkdir -p "$REPORT_DIR"

# Lock file mechanism (idempotent - prevent concurrent executions)
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Another update is already running (PID: $lock_pid). Exiting."
            exit 1
        else
            echo "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Cleanup on exit
cleanup() {
    rm -f "$LOCK_FILE"
    exit $?
}

trap cleanup EXIT INT TERM

# Check for lock at start
check_lock

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to send email notification
send_notification() {
    local subject="$1"
    local message="$2"

    if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
        echo "$message" | mail -s "$subject" "$NOTIFY_EMAIL" 2>/dev/null || log_message "Failed to send email notification"
    fi
}

# Function to update Docker Nginx
update_docker_nginx() {
    log_message "Starting Docker Nginx update"

    local updated=false
    local container_name=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1 || echo "")

    if [[ -z "$container_name" ]]; then
        log_message "No Docker Nginx container found"
        return 0
    fi

    log_message "Found Docker container: $container_name"

    # Get current image
    local current_image=$(docker inspect "$container_name" 2>/dev/null | jq -r '.[0].Config.Image' || echo "")
    if [[ -z "$current_image" ]]; then
        log_message "Failed to get current image"
        return 1
    fi

    log_message "Current image: $current_image"

    # Pull Compose images, then recreate only when the running image ID
    # differs. Production containers are never rebuilt by this cron job.
    log_message "Checking Compose images for updates"
    cd /opt/nginx || {
        log_message "Failed to change to /opt/nginx directory"
        return 1
    }
    local running_image_id desired_image desired_image_id
    running_image_id=$(docker inspect --format '{{.Image}}' "$container_name" 2>/dev/null || true)
    if ! docker compose pull >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: Failed to pull Compose images"
        return 1
    fi
    desired_image=$(docker compose config --images 2>/dev/null | head -n1)
    desired_image_id=$(docker image inspect --format '{{.Id}}' "$desired_image" 2>/dev/null || true)
    if [[ -n "$desired_image_id" && "$desired_image_id" != "$running_image_id" ]]; then
        log_message "A new immutable image is available; recreating the service"
        if docker compose up -d --no-build >> "$LOG_FILE" 2>&1; then
            updated=true
        else
            log_message "ERROR: Failed to recreate service with pulled image"
            return 1
        fi
    else
        log_message "Running image already matches the desired image; no restart needed"
    fi

    if [[ "$updated" == "true" ]]; then
        log_message "Docker Nginx update completed successfully"
        send_notification "Nginx Auto-Update Success" "Docker Nginx has been updated successfully on $(hostname)."
        return 0
    fi

    return 0
}

# Function to update system Nginx
update_system_nginx() {
    log_message "Starting system Nginx update"

    local updated=false

    # Update package list
    log_message "Updating package list"
    if apt-get update -qq >> "$LOG_FILE" 2>&1; then
        log_message "Package list updated"
    else
        log_message "ERROR: Failed to update package list"
        return 1
    fi

    # Check for Nginx updates
    log_message "Checking for Nginx updates"
    local installed_version=$(apt-cache policy nginx 2>/dev/null | grep -A 1 "Installed:" | grep -v "Installed:" | awk '{print $1}' || echo "")
    local candidate_version=$(apt-cache policy nginx 2>/dev/null | grep -A 1 "Candidate:" | grep -v "Candidate:" | awk '{print $1}' || echo "")

    if [[ -n "$candidate_version" ]] && [[ "$candidate_version" != "$installed_version" ]]; then
        log_message "Nginx update available: $installed_version -> $candidate_version"

        # Update Nginx
        log_message "Updating Nginx package"
        if apt-get install -y -qq nginx >> "$LOG_FILE" 2>&1; then
            log_message "Nginx updated successfully"
            updated=true

            # Reload Nginx
            log_message "Reloading Nginx"
            if systemctl reload nginx >> "$LOG_FILE" 2>&1; then
                log_message "Nginx reloaded successfully"
            else
                log_message "Warning: Failed to reload Nginx"
            fi
        else
            log_message "ERROR: Failed to update Nginx"
            return 1
        fi
    else
        log_message "Nginx is already up to date (version: $installed_version)"
    fi

    # Update system packages (security patches) - idempotent check
    log_message "Checking for system package updates"
    local upgrades_available=$(apt-get upgrade -s -qq 2>/dev/null | grep -c "^Inst " || echo "0")

    if [[ "$upgrades_available" -gt 0 ]]; then
        log_message "$upgrades_available package updates available"
        log_message "Updating system packages for security patches"
        if apt-get upgrade -y -qq >> "$LOG_FILE" 2>&1; then
            log_message "System packages updated successfully"
        else
            log_message "Warning: Some system packages failed to update"
        fi
    else
        log_message "System packages already up to date (no updates needed)"
    fi

    # Clean up
    log_message "Cleaning up old packages"
    apt-get autoremove -y -qq >> "$LOG_FILE" 2>&1 || log_message "Warning: Failed to autoreve packages"

    if [[ "$updated" == "true" ]]; then
        log_message "System Nginx update completed successfully"
        send_notification "Nginx Auto-Update Success" "System Nginx has been updated successfully on $(hostname)."
        return 0
    fi

    return 0
}

# Function to update Alpine packages in Docker
update_alpine_packages() {
    log_message "Starting Alpine packages update in Docker"

    local container_name=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1 || echo "")

    if [[ -z "$container_name" ]]; then
        log_message "No Docker Nginx container found"
        return 0
    fi

    log_message "Updating Alpine packages in container: $container_name"

    # Check if updates are available (idempotent)
    local update_check=$(docker exec "$container_name" sh -c "apk update -q 2>/dev/null && apk upgrade -s 2>/dev/null" || echo "")

    if echo "$update_check" | grep -q "Upgrading"; then
        log_message "Updates available, proceeding with upgrade..."

        # Update package index and upgrade packages
        if docker exec "$container_name" sh -c "apk update && apk upgrade" >> "$LOG_FILE" 2>&1; then
            log_message "Alpine packages updated successfully"

            # Check if container needs restart
            log_message "Checking if container restart is needed"
            if docker exec "$container_name" nginx -t >> "$LOG_FILE" 2>&1; then
                log_message "Nginx configuration is valid"

                # Reload Nginx
                if docker exec "$container_name" nginx -s reload >> "$LOG_FILE" 2>&1; then
                    log_message "Nginx reloaded successfully"
                else
                    log_message "Warning: Failed to reload Nginx"
                fi
            else
                log_message "Warning: Nginx configuration test failed"
            fi
        else
            log_message "ERROR: Failed to update Alpine packages"
            return 1
        fi
    else
        log_message "Alpine packages already up to date (no updates needed)"
    fi

    return 0
}

# Function to generate update report
generate_update_report() {
    local report_file="$REPORT_DIR/update_report_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Nginx Auto-Update Report"
        echo "======================="
        echo "Date: $(date)"
        echo "Server: $(hostname)"
        echo

        echo "Update Summary:"
        echo "--------------"
        echo "Docker Nginx: $DOCKER_UPDATE_STATUS"
        echo "System Nginx: $SYSTEM_UPDATE_STATUS"
        echo "Alpine Packages: $ALPINE_UPDATE_STATUS"
        echo

        echo "Update Log:"
        echo "----------"
        tail -50 "$LOG_FILE"

    } > "$report_file"

    log_message "Update report generated: $report_file"
    echo "$report_file"
}

# Main execution
log_message "=========================================="
log_message "Starting Nginx auto-update"
log_message "=========================================="

# Initialize status variables
DOCKER_UPDATE_STATUS="Skipped"
SYSTEM_UPDATE_STATUS="Skipped"
ALPINE_UPDATE_STATUS="Skipped"

# Check update type from environment or auto-detect
UPDATE_TYPE="${UPDATE_TYPE:-auto}"

if [[ "$UPDATE_TYPE" == "auto" ]]; then
    # Auto-detect which Nginx to update
    if command -v docker >/dev/null 2>&1; then
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qi nginx; then
            UPDATE_TYPE="docker"
        elif systemctl is-active --quiet nginx 2>/dev/null || command -v nginx >/dev/null 2>&1; then
            UPDATE_TYPE="system"
        fi
    elif systemctl is-active --quiet nginx 2>/dev/null || command -v nginx >/dev/null 2>&1; then
        UPDATE_TYPE="system"
    fi
fi

# Perform updates based on type
case "$UPDATE_TYPE" in
    docker)
        log_message "Updating Docker Nginx"
        if update_docker_nginx; then
            DOCKER_UPDATE_STATUS="Success"
        else
            DOCKER_UPDATE_STATUS="Failed"
        fi

        ALPINE_UPDATE_STATUS="Immutable image; rebuild in CI"
        ;;
    system)
        log_message "Updating system Nginx"
        if update_system_nginx; then
            SYSTEM_UPDATE_STATUS="Success"
        else
            SYSTEM_UPDATE_STATUS="Failed"
        fi
        ;;
    both)
        log_message "Updating both Docker and system Nginx"
        if update_docker_nginx; then
            DOCKER_UPDATE_STATUS="Success"
        else
            DOCKER_UPDATE_STATUS="Failed"
        fi

        if update_alpine_packages; then
            ALPINE_UPDATE_STATUS="Success"
        else
            ALPINE_UPDATE_STATUS="Failed"
        fi

        if update_system_nginx; then
            SYSTEM_UPDATE_STATUS="Success"
        else
            SYSTEM_UPDATE_STATUS="Failed"
        fi
        ;;
    *)
        log_message "Unknown update type: $UPDATE_TYPE"
        exit 1
        ;;
esac

# Generate report
report_file=$(generate_update_report)

# Send notification
if [[ "$DOCKER_UPDATE_STATUS" == "Failed" ]] || [[ "$SYSTEM_UPDATE_STATUS" == "Failed" ]] || [[ "$ALPINE_UPDATE_STATUS" == "Failed" ]]; then
    send_notification "Nginx Auto-Update Failed" "One or more updates failed on $(hostname). Check the log file: $LOG_FILE"
    log_message "ERROR: Some updates failed"
    exit 1
fi

log_message "=========================================="
log_message "Nginx auto-update completed successfully"
log_message "=========================================="
log_message "Report: $report_file"

exit 0
EOF

    # Compare hashes and only overwrite if different (idempotent)
    local new_hash
    new_hash=$(md5sum "$temp_script" 2>/dev/null | awk '{print $1}' || echo "")

    if [[ "$script_hash" != "$new_hash" ]]; then
        mv "$temp_script" /opt/nginx/scripts/auto_update.sh
        chmod +x /opt/nginx/scripts/auto_update.sh || print_error "Failed to set execute permissions"
        print_info "Auto-update script updated"
    else
        rm -f "$temp_script"
        print_info "Auto-update script already up to date"
    fi

    # Setup cron job (idempotent)
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    # Remove existing auto_update.sh cron entries (more precise)
    local new_cron
    new_cron=$(echo "$current_cron" | grep -v "/opt/nginx/scripts/auto_update.sh" || echo "")

    # Remove existing MAILTO entries (to avoid duplicates)
    new_cron=$(echo "$new_cron" | grep -v "^MAILTO=" || echo "")

    # Add new cron entry
    if [[ -n "$notify_email" ]]; then
        new_cron=$(echo -e "$new_cron\nMAILTO=$notify_email\n$cron_schedule /opt/nginx/scripts/auto_update.sh")
    else
        new_cron=$(echo -e "$new_cron\n$cron_schedule /opt/nginx/scripts/auto_update.sh")
    fi

    # Update crontab
    if echo "$new_cron" | crontab - 2>/dev/null; then
        print_success "Auto-update scheduled: $frequency_name"
    else
        print_error "Failed to setup cron job"
        return 1
    fi

    # Create log file (idempotent)
    if [[ ! -f /var/log/nginx/auto_update.log ]]; then
        touch /var/log/nginx/auto_update.log
        chmod 644 /var/log/nginx/auto_update.log
        print_info "Log file created"
    else
        print_info "Log file already exists"
    fi

    print_success "Auto-update setup completed successfully."
    echo
    print_info "Auto-update features:"
    print_info "  ✓ Updates Docker Nginx images to latest version"
    print_info "  ✓ Updates Alpine packages in Docker containers"
    print_info "  ✓ Updates system Nginx packages"
    print_info "  ✓ Applies security patches"
    print_info "  ✓ Generates update reports"
    print_info "  ✓ Sends email notifications (if configured)"
    echo
    print_info "Configuration:"
    print_info "  Update frequency: $frequency_name"
    print_info "  Cron schedule: $cron_schedule"
    print_info "  Update script: /opt/nginx/scripts/auto_update.sh"
    print_info "  Log file: /var/log/nginx/auto_update.log"
    print_info "  Reports directory: /opt/nginx/security_reports/"
    echo
    print_info "Manual update commands:"
    print_info "  Run update now: /opt/nginx/scripts/auto_update.sh"
    print_info "  View logs: tail -f /var/log/nginx/auto_update.log"
    print_info "  View cron jobs: crontab -l"
    echo
    print_info "To disable auto-update:"
    print_info "  crontab -l | grep -v auto_update.sh | crontab -"
    echo
    if [[ -n "$notify_email" ]]; then
        print_info "Email notifications will be sent to: $notify_email"
    else
        print_info "No email notification configured. To add email, re-run setup."
    fi

    log "Auto-update setup completed with frequency: $update_frequency"
    return 0
}