#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$script_dir/modules/nginx.sh"

prefix=$(mktemp -d)
bin_dir=$(mktemp -d)
trap 'rm -rf "$prefix" "$bin_dir"' EXIT

cat > "$bin_dir/openssl" << 'EOF'
#!/bin/bash
key=""
cert=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -keyout) key="$2"; shift 2 ;;
        -out) cert="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$key" && -n "$cert" ]]
printf 'key\n' > "$key"
printf 'cert\n' > "$cert"
EOF
cat > "$bin_dir/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
    printf 'nginx\n'
    exit 0
fi
if [[ "$1" == "exec" && "$2" == "nginx" && "$3" == "nginx" && "$4" == "-t" ]]; then
    printf 'nginx -t\n' >> "${DOCKER_LOG:?}"
    exit "${NGINX_TEST_STATUS:-0}"
fi
if [[ "$1" == "exec" && "$2" == "nginx" && "$3" == "nginx" && "$4" == "-s" && "$5" == "reload" ]]; then
    printf 'nginx reload\n' >> "${DOCKER_LOG:?}"
    exit 0
fi
printf 'unexpected docker args: %s\n' "$*" >&2
exit 1
EOF
chmod 755 "$bin_dir/openssl" "$bin_dir/docker"

export NGINX_PREFIX="$prefix"
export PATH="$bin_dir:$PATH"
export DOCKER_LOG="$prefix/docker.log"
export NGINX_TEST_STATUS=0
: > "$DOCKER_LOG"

apply_nginx_default_site
grep -Fq 'listen 8080 default_server;' "$prefix/conf.d/default.conf"
grep -Fq 'listen 8443 ssl default_server;' "$prefix/conf.d/default.conf"
grep -Fq 'root   /usr/share/nginx/html;' "$prefix/conf.d/default.conf"
grep -Fq 'try_files $uri $uri/ /index.html;' "$prefix/conf.d/default.conf"
grep -Fq 'ssl_certificate /etc/nginx/certs/default.pem;' "$prefix/conf.d/default.conf"
[[ -s "$prefix/certs/default.pem" && -s "$prefix/certs/default.key" ]]
grep -Fq 'nginx -t' "$DOCKER_LOG"
grep -Fq 'nginx reload' "$DOCKER_LOG"

printf 'previous default config\n' > "$prefix/conf.d/default.conf"
export NGINX_TEST_STATUS=1
: > "$DOCKER_LOG"
if apply_nginx_default_site; then
    printf 'a failed nginx -t was treated as success\n' >&2
    exit 1
fi
grep -Fq 'previous default config' "$prefix/conf.d/default.conf"
grep -Fq 'nginx -t' "$DOCKER_LOG"
if grep -Fq 'nginx reload' "$DOCKER_LOG"; then
    printf 'nginx reloaded after a failed test\n' >&2
    exit 1
fi

printf 'nginx default site tests passed\n'
