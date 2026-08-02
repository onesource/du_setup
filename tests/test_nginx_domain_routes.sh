#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$script_dir/modules/nginx_cert_manager.sh"
temp_dir=$(mktemp -d)

# shellcheck source=../modules/nginx_cert_manager.sh
source "$source_file"
trap 'rm -rf "$temp_dir"' EXIT

route_dir="$temp_dir/routes"
route_file="$route_dir/example.com.inc"

ensure_nginx_domain_route example.com "$route_dir" /srv/www
grep -Fqx '# This file is created once and is not overwritten by certificate operations.' "$route_file"
grep -Fqx '    root /srv/www;' "$route_file"
grep -Fqx '    try_files $uri $uri/ =404;' "$route_file"

cat > "$route_file" <<'EOF'
location / {
    proxy_pass http://example-app:8000;
}
EOF
expected=$(sha256sum "$route_file")
ensure_nginx_domain_route example.com "$route_dir" /different/root
[[ "$(sha256sum "$route_file")" == "$expected" ]]
grep -Fqx '    proxy_pass http://example-app:8000;' "$route_file"

# Both certificate-generation paths must include the persistent snippet, while
# the only generated try_files fallback lives in the create-once helper above.
[[ "$(grep -Fc 'include $ROUTE_INCLUDE_PATH;' "$source_file")" -eq 2 ]]
[[ "$(grep -Fc 'try_files \$uri \$uri/ =404;' "$source_file")" -eq 1 ]]

printf 'nginx domain route tests passed\n'
