#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$script_dir/modules/nginx_cert_manager.sh"
temp_dir=$(mktemp -d)

# shellcheck source=../modules/nginx_cert_manager.sh
source "$source_file"
trap 'rm -rf "$temp_dir"' EXIT

# Route creation under test must not prompt, even when stdin is a terminal.
NON_INTERACTIVE=true

route_dir="$temp_dir/routes"
route_file="$route_dir/example.com.inc"

expect_upstream_rejected() {
    local domain="$1"
    local upstream="$2"
    local message="$3"
    local output
    if output=$(ensure_nginx_domain_route "$domain" "$route_dir" /srv/www "$upstream" docker 2>&1); then
        printf 'expected upstream %s to be rejected\n' "$upstream" >&2
        exit 1
    fi
    grep -Fq "$message" <<< "$output"
    [[ ! -e "$route_dir/$domain.inc" ]]
}

assert_file_equals() {
    local path="$1"
    local expected="$2"
    local actual
    actual=$(cat "$path")
    if [[ "$actual" != "$expected" ]]; then
        printf 'unexpected route file %s\n' "$path" >&2
        printf '--- actual ---\n%s\n--- expected ---\n%s\n' "$actual" "$expected" >&2
        exit 1
    fi
}

ensure_nginx_domain_route example.com "$route_dir" /srv/www
grep -Fqx '# This file is created once and is not overwritten by certificate operations.' "$route_file"
grep -Fqx '    root /srv/www;' "$route_file"
grep -Fqx '    try_files $uri $uri/ =404;' "$route_file"
if grep -Fq 'proxy_pass' "$route_file"; then
    printf 'static route unexpectedly contained proxy_pass\n' >&2
    exit 1
fi

cat > "$route_file" <<'EOF'
location / {
    proxy_pass http://example-app:8000;
}
EOF
expected=$(sha256sum "$route_file")
ensure_nginx_domain_route example.com "$route_dir" /different/root
[[ "$(sha256sum "$route_file")" == "$expected" ]]
grep -Fqx '    proxy_pass http://example-app:8000;' "$route_file"
ensure_nginx_domain_route example.com "$route_dir" /different/root 'other-app:9000' docker
[[ "$(sha256sum "$route_file")" == "$expected" ]]
grep -Fqx '    proxy_pass http://example-app:8000;' "$route_file"

docker_route="$route_dir/proxy.example.inc"
ensure_nginx_domain_route proxy.example "$route_dir" /srv/www 'app-1:8080' docker
assert_file_equals "$docker_route" "# Application routing for proxy.example.
# This file is created once and is not overwritten by certificate operations.
location / {
    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$upstream_app http://app-1:8080;
    proxy_pass \$upstream_app;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header CF-IPCountry \$http_cf_ipcountry;
}"

host_route="$route_dir/host.example.inc"
ensure_nginx_domain_route host.example "$route_dir" /var/www/html 'app-1:8080' system
assert_file_equals "$host_route" "# Application routing for host.example.
# This file is created once and is not overwritten by certificate operations.
# Host Nginx does not use Docker DNS, so the upstream is resolved when Nginx starts.
location / {
    proxy_pass http://app-1:8080;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header CF-IPCountry \$http_cf_ipcountry;
}"
if grep -Fq 'resolver 127.0.0.11' "$host_route"; then
    printf 'host route unexpectedly used the Docker DNS resolver\n' >&2
    exit 1
fi

# The same systemctl check used by certificate setup selects the host fallback
# when no Nginx type is passed.
systemctl() { return 0; }
detected_host="$route_dir/detected-host.example.inc"
ensure_nginx_domain_route detected-host.example "$route_dir" /var/www/html 'api:443'
grep -Fqx '    proxy_pass http://api:443;' "$detected_host"
if grep -Fq 'resolver 127.0.0.11' "$detected_host"; then
    printf 'detected host route unexpectedly used the Docker DNS resolver\n' >&2
    exit 1
fi
unset -f systemctl

systemctl() { return 1; }
detected_docker="$route_dir/detected-docker.example.inc"
ensure_nginx_domain_route detected-docker.example "$route_dir" /usr/share/nginx/html 'api:443'
grep -Fqx '    resolver 127.0.0.11 valid=10s ipv6=off;' "$detected_docker"
grep -Fqx '    set $upstream_app http://api:443;' "$detected_docker"
grep -Fqx '    proxy_pass $upstream_app;' "$detected_docker"
unset -f systemctl

expect_upstream_rejected bad-name.example 'bad_name:80' "Invalid container name 'bad_name'"
expect_upstream_rejected missing-port.example 'app' "Expected container:port."
expect_upstream_rejected zero-port.example 'app:0' "Invalid upstream port '0'"
expect_upstream_rejected high-port.example 'app:65536' "Invalid upstream port '65536'"
expect_upstream_rejected extra-colon.example 'app:80:1' "Expected container:port."

# Both certificate-generation paths must include the persistent snippet, while
# the only generated try_files fallback lives in the create-once helper above.
[[ "$(grep -Fc 'include $ROUTE_INCLUDE_PATH;' "$source_file")" -eq 2 ]]
[[ "$(grep -Fc 'try_files \$uri \$uri/ =404;' "$source_file")" -eq 1 ]]

printf 'nginx domain route tests passed\n'
