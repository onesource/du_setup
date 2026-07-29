#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
VERBOSE=false
NON_INTERACTIVE=true
LOG_FILE=/dev/null
# shellcheck source=../lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"

[[ "$(prompt_bool_current test true)" == true ]]
[[ "$(prompt_bool_current test false)" == false ]]
[[ "$(prompt_value_current port 2222 validate_ssh_port)" == 2222 ]]
if prompt_value_current required '' validate_backup_destination >/dev/null 2>&1; then
    echo 'missing non-interactive value unexpectedly succeeded' >&2
    exit 1
fi

# Re-sourcing config must not reset parsed runtime flags.
source "$SCRIPT_DIR/lib/config.sh"
[[ "$VERBOSE" == false ]]
[[ "$NON_INTERACTIVE" == true ]]
printf 'reconciler helper tests passed\n'
