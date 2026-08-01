#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SCRIPT_DIR="$script_dir"
test_log=$(mktemp)
test_backup=$(mktemp -d)

source "$script_dir/lib/config.sh"
source "$script_dir/lib/utils.sh"

export LOG_FILE="$test_log"
export BACKUP_DIR="$test_backup"
export VERBOSE=false
export CLEANUP_PREVIEW=false
export CLEANUP_ONLY=false
export SKIP_CLEANUP=false
trap 'rm -f "$test_log"; rm -rf "$test_backup"' EXIT

expected_err_trap=$(trap -p ERR)
# Module loading must not require write access to production directories.
mkdir() { :; }
chmod() { :; }
for module in "$script_dir"/modules/*.sh; do
    source "$module"
done
unset -f mkdir chmod

[[ "$(trap -p ERR)" == "$expected_err_trap" ]]
trap - EXIT
rm -f "$test_log"
rm -rf "$test_backup"
printf 'module loading tests passed\n'
