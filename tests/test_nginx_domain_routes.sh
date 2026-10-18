#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$script_dir/modules/nginx_cert_manager.sh"
temp_dir=$(mktemp -d)

# shellcheck source=../modules/nginx_cert_manager.sh
source "$source_file"
# shellcheck source=../modules/nginx.sh
source "$script_dir/modules/nginx.sh"
trap 'rm -rf "$temp_dir"' EXIT

# Route creation under test must not prompt, even when stdin is a terminal.
# shellcheck disable=SC2034  # read by ensure_nginx_domain_route
NON_INTERACTIVE=true

route_dir="$temp_dir/routes"
route_file="$route_dir/example.com.inc"

expect_upstream_rejected() {
    local domain="$1"
    local upstream="$2"
    local message="$3"
    local nginx_type="${4:-docker}"
    local output
    if output=$(ensure_nginx_domain_route "$domain" "$route_dir" /srv/www "$upstream" "$nginx_type" 2>&1); then
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
# shellcheck disable=SC2016  # nginx variables are literal config text
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
preserve_output=$(ensure_nginx_domain_route example.com "$route_dir" /different/root 'other-app:9000' docker)
[[ "$(sha256sum "$route_file")" == "$expected" ]]
grep -Fqx '    proxy_pass http://example-app:8000;' "$route_file"
grep -Fq "Requested upstream 'other-app:9000' was not applied" <<< "$preserve_output"

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
ensure_nginx_domain_route host.example "$route_dir" /var/www/html '127.0.0.1:8080' system
assert_file_equals "$host_route" "# Application routing for host.example.
# This file is created once and is not overwritten by certificate operations.
# Host Nginx proxies only to 127.0.0.1 or localhost.
location / {
    proxy_pass http://127.0.0.1:8080;
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
ensure_nginx_domain_route localhost.example "$route_dir" /var/www/html 'localhost:443' system
grep -Fqx '    proxy_pass http://localhost:443;' "$route_dir/localhost.example.inc"

expect_upstream_rejected container-on-host.example 'app-1:8080' "Container names are not accepted" system
expect_upstream_rejected other-ip.example '10.0.0.1:80' "Use 127.0.0.1 or localhost" system
expect_upstream_rejected host-bad-port.example '127.0.0.1:65536' "Invalid upstream port '65536'" system
expect_upstream_rejected bad-name.example 'bad_name:80' "Invalid container name 'bad_name'"
expect_upstream_rejected dotted-name.example 'foo.bar:80' "Underscores and dots are rejected"
expect_upstream_rejected semicolon.example 'app;x:80' "Invalid container name 'app;x'"
expect_upstream_rejected spaced.example 'app :80' "Invalid container name 'app '"
expect_upstream_rejected traversal.example '../x:80' "Invalid container name '../x'"
expect_upstream_rejected missing-port.example 'app' "Expected container:port."
expect_upstream_rejected zero-port.example 'app:0' "Invalid upstream port '0'"
expect_upstream_rejected high-port.example 'app:65536' "Invalid upstream port '65536'"
expect_upstream_rejected extra-colon.example 'app:80:1' "Expected container:port."
expect_upstream_rejected weird-type.example 'app:80' "Unknown Nginx type 'weird'" weird

# shellcheck disable=SC2317  # invoked by ensure_nginx_domain_route
systemctl() { return 0; }
detect_host_output=$(ensure_nginx_domain_route detected-host.example "$route_dir" /var/www/html 'api:443' 2>&1 || true)
grep -Fq "Container names are not accepted" <<< "$detect_host_output"
[[ ! -e "$route_dir/detected-host.example.inc" ]]
unset -f systemctl

# shellcheck disable=SC2317  # invoked by ensure_nginx_domain_route
systemctl() { return 1; }
detected_docker="$route_dir/detected-docker.example.inc"
ensure_nginx_domain_route detected-docker.example "$route_dir" /usr/share/nginx/html 'api:443'
# shellcheck disable=SC2016  # nginx variables are literal config text
grep -Fqx '    resolver 127.0.0.11 valid=10s ipv6=off;' "$detected_docker"
# shellcheck disable=SC2016
grep -Fqx '    set $upstream_app http://api:443;' "$detected_docker"
# shellcheck disable=SC2016
grep -Fqx '    proxy_pass $upstream_app;' "$detected_docker"
unset -f systemctl

# A non-terminal stdin is not a prompt, even when NON_INTERACTIVE is unset.
# Piped upstream text must stay unread and the static stub must be written.
gated_route="$route_dir/gated.example.inc"
NON_INTERACTIVE=false ensure_nginx_domain_route gated.example "$route_dir" /srv/www "" docker <<<'app-1:9090'
grep -Fqx '    root /srv/www;' "$gated_route"
if grep -Fq 'proxy_pass' "$gated_route"; then
    printf 'non-tty prompt consumed piped upstream\n' >&2
    exit 1
fi
gated_host="$route_dir/gated-host.example.inc"
NON_INTERACTIVE=false ensure_nginx_domain_route gated-host.example "$route_dir" /var/www/html "" system <<<'localhost:8080'
grep -Fqx '    root /var/www/html;' "$gated_host"
if grep -Fq 'proxy_pass' "$gated_host"; then
    printf 'non-tty host prompt consumed piped upstream\n' >&2
    exit 1
fi

# A real terminal does prompt, and the answer becomes the route.
python3 - "$temp_dir" "$route_dir" "$source_file" << 'PY'
import os
import pty
import select
import subprocess
import sys

temp_dir, route_dir, source_file = sys.argv[1:4]
script = os.path.join(temp_dir, "pty-route.sh")
with open(script, "w", encoding="utf-8") as handle:
    handle.write(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        f"source {source_file!r}\n"
        "NON_INTERACTIVE=false\n"
        f"ensure_nginx_domain_route tty-prompt.example {route_dir!r} /srv/www \"\" docker\n"
    )
os.chmod(script, 0o755)
master, slave = pty.openpty()
proc = subprocess.Popen(
    ["bash", script],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    close_fds=True,
)
os.close(slave)
buffer = b""
answered = False
deadline_reads = 0
while proc.poll() is None and deadline_reads < 50:
    ready, _, _ = select.select([master], [], [], 0.2)
    deadline_reads += 1
    if not ready:
        continue
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    buffer += chunk
    if not answered and b"container:port" in buffer:
        os.write(master, b"app-1:9090\n")
        answered = True
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait(timeout=5)
os.close(master)
if proc.returncode != 0 or not answered:
    sys.stderr.write(buffer.decode("utf-8", "replace"))
    sys.stderr.write(f"\npty prompt failed: rc={proc.returncode} answered={answered}\n")
    sys.exit(1)
PY
# shellcheck disable=SC2016
grep -Fqx '    set $upstream_app http://app-1:9090;' "$route_dir/tty-prompt.example.inc"

# Older coreutils can return 0 from mv -n without moving. The temp file must
# be removed, the command must fail, and an existing route must stay put.
(
    # shellcheck disable=SC2317,SC2329  # mock invoked by install_new_nginx_route_file
    mv() {
        if [[ "${1:-}" == -n ]]; then
            return 0
        fi
        command mv "$@"
    }
    keep_route="$route_dir/move-keep.example.inc"
    printf 'original-route\n' > "$keep_route"
    move_output=""
    if move_output=$(printf 'replacement\n' | install_new_nginx_route_file "$keep_route" 2>&1); then
        printf 'expected a no-op mv -n to fail\n' >&2
        exit 1
    fi
    grep -Fq 'left unchanged' <<< "$move_output"
    grep -qx 'original-route' "$keep_route"
    fresh_output=""
    if fresh_output=$(printf 'brand-new\n' | install_new_nginx_route_file "$route_dir/move-fresh.example.inc" 2>&1); then
        printf 'expected a no-op mv -n to fail for a new route\n' >&2
        exit 1
    fi
    grep -Fq 'left unchanged' <<< "$fresh_output"
    [[ ! -e "$route_dir/move-fresh.example.inc" ]]
    shopt -s nullglob
    leftovers=("$route_dir"/.route.*)
    [[ ${#leftovers[@]} -eq 0 ]]
)

# A stopped Nginx container gets an actionable error before docker exec.
(
    # shellcheck disable=SC2317,SC2329
    docker() {
        printf '%s\n' "$*" >> "$temp_dir/docker-down.log"
        if [[ "${1:-}" == ps ]]; then
            return 0
        fi
        printf 'Error response from daemon: container is not running\n' >&2
        return 1
    }
    down_conf="$temp_dir/sites/down.example.conf"
    mkdir -p "$(dirname "$down_conf")"
    printf 'down-config\n' > "$down_conf"
    down_route="$temp_dir/routes/down.example.inc"
    printf 'down-route\n' > "$down_route"
    down_output=""
    if down_output=$(apply_nginx_config_after_test docker "$down_conf" "$down_route" true "" 2>&1); then
        printf 'expected a stopped container to fail nginx -t\n' >&2
        exit 1
    fi
    grep -Fq 'The Nginx container is not running' <<< "$down_output"
    grep -Fq '/opt/nginx' <<< "$down_output"
    grep -Fq 'docker compose up -d' <<< "$down_output"
    [[ ! -e "$down_route" ]]
    if grep -q '^exec ' "$temp_dir/docker-down.log"; then
        printf 'docker exec ran while the Nginx container was stopped\n' >&2
        exit 1
    fi
)

# nginx -t failure rolls back a route created in this run and restores the conf.
(
    # shellcheck disable=SC2317  # mock invoked by apply_nginx_config_after_test
    nginx() {
        printf 'nginx %s\n' "$*" >> "$temp_dir/nginx-fail.log"
        return 1
    }
    # shellcheck disable=SC2317
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$temp_dir/nginx-fail.log"
        return 0
    }
    conf="$temp_dir/sites/rollback.example.conf"
    mkdir -p "$(dirname "$conf")"
    printf 'old-config\n' > "$conf"
    cp "$conf" "$temp_dir/prior.conf"
    printf 'new-config\n' > "$conf"
    created_route="$temp_dir/routes/rollback.example.inc"
    printf 'created-route\n' > "$created_route"
    link="$temp_dir/enabled/rollback.example.conf"
    mkdir -p "$(dirname "$link")"
    ln -s "$conf" "$link"
    if apply_nginx_config_after_test system "$conf" "$created_route" true "$temp_dir/prior.conf" "$link"; then
        printf 'expected nginx -t failure to return non-zero\n' >&2
        exit 1
    fi
    [[ ! -e "$created_route" ]]
    grep -qx 'old-config' "$conf"
    [[ -L "$link" ]]
    grep -qx 'nginx -t' "$temp_dir/nginx-fail.log"
    if grep -q 'systemctl ' "$temp_dir/nginx-fail.log"; then
        printf 'nginx -t failure reloaded Nginx\n' >&2
        exit 1
    fi
)

# An .inc that already existed survives a failed test, and so does its conf.
(
    # shellcheck disable=SC2317
    nginx() { return 1; }
    conf="$temp_dir/sites/keep.example.conf"
    printf 'old-keep\n' > "$conf"
    cp "$conf" "$temp_dir/keep-prior.conf"
    printf 'new-keep\n' > "$conf"
    kept_route="$temp_dir/routes/keep.example.inc"
    printf 'preexisting-route\n' > "$kept_route"
    if apply_nginx_config_after_test system "$conf" "$kept_route" false "$temp_dir/keep-prior.conf"; then
        printf 'expected preexisting-route failure to return non-zero\n' >&2
        exit 1
    fi
    grep -qx 'preexisting-route' "$kept_route"
    grep -qx 'old-keep' "$conf"
)

# A config that did not exist is removed, along with a route this run created.
(
    # shellcheck disable=SC2317
    nginx() { return 1; }
    conf="$temp_dir/sites/fresh.example.conf"
    printf 'fresh-config\n' > "$conf"
    fresh_route="$temp_dir/routes/fresh.example.inc"
    printf 'fresh-route\n' > "$fresh_route"
    link="$temp_dir/enabled/fresh.example.conf"
    ln -s "$conf" "$link"
    if apply_nginx_config_after_test system "$conf" "$fresh_route" true "" "$link"; then
        printf 'expected fresh config failure to return non-zero\n' >&2
        exit 1
    fi
    [[ ! -e "$conf" ]]
    [[ ! -e "$fresh_route" ]]
    [[ ! -e "$link" ]]
)

# A passing nginx -t reloads and leaves the new files in place.
(
    # shellcheck disable=SC2317
    nginx() {
        printf 'nginx %s\n' "$*" >> "$temp_dir/nginx-ok.log"
        return 0
    }
    # shellcheck disable=SC2317
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$temp_dir/nginx-ok.log"
        return 0
    }
    conf="$temp_dir/sites/ok.example.conf"
    printf 'ok-config\n' > "$conf"
    ok_route="$temp_dir/routes/ok.example.inc"
    printf 'ok-route\n' > "$ok_route"
    apply_nginx_config_after_test system "$conf" "$ok_route" true ""
    grep -qx 'ok-config' "$conf"
    grep -qx 'ok-route' "$ok_route"
    grep -qx 'nginx -t' "$temp_dir/nginx-ok.log"
    grep -qx 'systemctl reload nginx' "$temp_dir/nginx-ok.log"
)

# Existing nginx_nginx-network without ip_range: warn and keep the subnet-only block.
(
    # shellcheck disable=SC2317  # invoked by nginx_live_network_ipam_state
    docker() {
        if [[ "${1:-}" == network && "${2:-}" == inspect && "${3:-}" == nginx_nginx-network ]]; then
            case "${NGINX_NETWORK_FIXTURE:-absent}" in
                legacy)
                    printf '%s\n' '[{"Subnet":"172.20.0.0/16","Gateway":"172.20.0.1"}]'
                    ;;
                current)
                    printf '%s\n' '[{"Subnet":"172.20.0.0/16","IPRange":"172.20.128.0/17","Gateway":"172.20.0.1"}]'
                    ;;
                *)
                    printf 'Error: No such network: nginx_nginx-network\n' >&2
                    return 1
                    ;;
            esac
            return 0
        fi
        printf 'unexpected docker args: %s\n' "$*" >&2
        return 1
    }
    # shellcheck disable=SC2034  # read by the docker mock above
    NGINX_NETWORK_FIXTURE=legacy
    legacy_file="$temp_dir/legacy-docker-compose.yml"
    legacy_output=$(write_nginx_container_compose "$legacy_file")
    grep -Fq 'Skipping network changes so Compose does not recreate nginx_nginx-network' <<< "$legacy_output"
    grep -Fq 'planned maintenance-window' <<< "$legacy_output"
    grep -Fq "needs George's approval" <<< "$legacy_output"
    grep -Fq 'The installer never recreates this network.' <<< "$legacy_output"
    grep -Fq '/opt/nginx' <<< "$legacy_output"
    grep -Fq '/opt/AlphaEngine' <<< "$legacy_output"
    grep -Fq 'sweetsaving.com' <<< "$legacy_output"
    grep -Fq 'frontend 172.20.0.3' <<< "$legacy_output"
    grep -Fq 'backend 172.20.0.5' <<< "$legacy_output"
    grep -Fq 'ui 172.20.0.4' <<< "$legacy_output"
    grep -Fq 'docker compose down' <<< "$legacy_output"
    grep -Fq 'docker compose up -d' <<< "$legacy_output"
    grep -Fq 'docker network rm' <<< "$legacy_output"
    grep -Fq 'docker network create' <<< "$legacy_output"
    grep -Fq 'docker network inspect nginx_nginx-network' <<< "$legacy_output"
    grep -Fq 'IPAM.Config shows IPRange 172.20.128.0/17' <<< "$legacy_output"
    grep -Fq 'https://www.myalphaengine.com/healthz' <<< "$legacy_output"
    grep -Fq 'subnet: 172.20.0.0/16' "$legacy_file"
    grep -Fq 'ipv4_address: 172.20.0.2' "$legacy_file"
    if grep -Fq 'ip_range:' "$legacy_file"; then
        printf 'legacy network compose file still sets ip_range\n' >&2
        exit 1
    fi

    NGINX_NETWORK_FIXTURE=current
    current_file="$temp_dir/current-docker-compose.yml"
    current_output=$(write_nginx_container_compose "$current_file")
    if grep -Fq 'Skipping network changes' <<< "$current_output"; then
        printf 'current network was treated as legacy\n' >&2
        exit 1
    fi
    grep -Fq 'ip_range: 172.20.128.0/17' "$current_file"
    grep -Fq 'gateway: 172.20.0.1' "$current_file"

    NGINX_NETWORK_FIXTURE=absent
    absent_file="$temp_dir/absent-docker-compose.yml"
    absent_output=$(write_nginx_container_compose "$absent_file")
    if grep -Fq 'Skipping network changes' <<< "$absent_output"; then
        printf 'missing network was treated as legacy\n' >&2
        exit 1
    fi
    grep -Fq 'ip_range: 172.20.128.0/17' "$absent_file"
)

# Both certificate-generation paths must include the persistent snippet, while
# the only generated try_files fallback lives in the create-once helper above.
# shellcheck disable=SC2016  # nginx variables are literal config text
[[ "$(grep -Fc 'include $ROUTE_INCLUDE_PATH;' "$source_file")" -eq 2 ]]
# shellcheck disable=SC2016
[[ "$(grep -Fc 'try_files \$uri \$uri/ =404;' "$source_file")" -eq 1 ]]

printf 'nginx domain route tests passed\n'
