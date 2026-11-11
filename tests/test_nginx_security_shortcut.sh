#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$script_dir/modules/system_config.sh"

hostname_is_already_configured stockscreen-prod
hostname_is_already_configured my-server.example
if hostname_is_already_configured localhost; then
    printf 'localhost was treated as already configured\n' >&2
    exit 1
fi
if hostname_is_already_configured localhost.localdomain; then
    printf 'localhost.localdomain was treated as already configured\n' >&2
    exit 1
fi
if hostname_is_already_configured debian || hostname_is_already_configured ubuntu; then
    printf 'a fresh-image hostname was treated as already configured\n' >&2
    exit 1
fi
if hostname_is_already_configured '(none)' || hostname_is_already_configured ''; then
    printf 'an empty hostname was treated as already configured\n' >&2
    exit 1
fi

NON_INTERACTIVE=true
HOSTNAME_ALREADY_CONFIGURED=true
CONFIGURED_HOSTNAME=stockscreen-prod
SERVER_NAME=stockscreen-prod
if offer_nginx_security_shortcut; then
    printf 'non-interactive mode offered the shortcut\n' >&2
    exit 1
fi

NON_INTERACTIVE=false
HOSTNAME_ALREADY_CONFIGURED=false
if offer_nginx_security_shortcut; then
    printf 'unset hostname offered the shortcut\n' >&2
    exit 1
fi

HOSTNAME_ALREADY_CONFIGURED=true
SERVER_NAME=new-name
confirm() {
    printf 'confirm ran when the hostname changed\n' >&2
    exit 1
}
if offer_nginx_security_shortcut; then
    printf 'a changed hostname offered the shortcut\n' >&2
    exit 1
fi

SERVER_NAME=stockscreen-prod
confirm() {
    [[ "$1" == *"Nginx Security Configuration"* ]]
    [[ "$2" == "n" ]]
    return 1
}
if offer_nginx_security_shortcut; then
    printf 'declining the shortcut was treated as yes\n' >&2
    exit 1
fi

confirm() {
    return 0
}
offer_nginx_security_shortcut

grep -Fq 'offer_nginx_security_shortcut' "$script_dir/du_setup_modular.sh"
grep -Fq 'configure_nginx_security' "$script_dir/du_setup_modular.sh"

printf 'nginx security shortcut tests passed\n'
