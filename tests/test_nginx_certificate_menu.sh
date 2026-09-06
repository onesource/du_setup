#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$script_dir/modules/nginx_cert_manager.sh"
temp_dir=$(mktemp -d)

# shellcheck source=../modules/nginx_cert_manager.sh
source "$source_file"
trap 'rm -rf "$temp_dir"' EXIT

# A negative answer to the unresolved-DNS warning is a cancellation, not an
# error. Certbot must not run and control must return to the caller.
command() {
    if [[ "${1:-}" == -v && "${2:-}" == certbot ]]; then
        printf '/usr/bin/certbot\n'
        return 0
    fi
    builtin command "$@"
}
dig() { return 0; }
certbot() {
    touch "$temp_dir/certbot-called"
    return 0
}

dns_output=$(setup_letsencrypt <<'EOF'
example.invalid
admin@example.com
n
EOF
)
grep -Fq "Let's Encrypt setup cancelled. Returning to certificate options." <<< "$dns_output"
[[ ! -e "$temp_dir/certbot-called" ]]

failed_task() { return 23; }
run_certificate_task "mock failure" failed_task

# After a completed task the main certificate options are displayed again;
# there is no second, redundant "perform another task" prompt.
setup_letsencrypt() { printf 'mock certificate task\n'; }
mkdir() { :; }
chown() { :; }
chmod() { :; }
menu_output=$(manage_certificates <<'EOF'
1
0
EOF
)
[[ "$(grep -Fc 'Certificate Management Options:' <<< "$menu_output")" -eq 2 ]]
! grep -Fq 'Would you like to perform another certificate management task?' <<< "$menu_output"

# The standalone maintenance option is documented and parsed by the launcher.
help_output=$(bash "$script_dir/du_setup_modular.sh" --help)
grep -Fq -- '--nginx-security' <<< "$help_output"
grep -Fq -- '--nginx-security) NGINX_SECURITY_ONLY=true' "$script_dir/du_setup_modular.sh"
grep -Fq "Deploy Existing Let's Encrypt Certificate" "$source_file"
! grep -Fq 'Issue a new one anyway?' "$source_file"
! grep -Fq 'Another security task?' "$script_dir/modules/nginx.sh"

printf 'nginx certificate menu tests passed\n'
