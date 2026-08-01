#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$script_dir/modules/user_management.sh"

confirm() { return 1; }
log() { :; }
print_info() { :; }

trap ':' INT
trap ':' TERM
expected_int_trap=$(trap -p INT)
expected_term_trap=$(trap -p TERM)

configure_custom_bashrc /tmp du-setup-test

[[ "$(trap -p INT)" == "$expected_int_trap" ]]
[[ "$(trap -p TERM)" == "$expected_term_trap" ]]
printf 'user-management trap tests passed\n'
