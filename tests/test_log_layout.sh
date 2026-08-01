#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$script_dir/lib/config.sh"

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
legacy_dir="$temp_dir/legacy"
destination="$temp_dir/du-setup"
mkdir -p "$legacy_dir" "$destination"

printf 'new backup log\n' > "$legacy_dir/backup_rsync.log"
printf 'existing backup log\n' > "$destination/backup_rsync.log"
printf 'installer log\n' > "$legacy_dir/du_setup_20260801_010101.log"
printf 'report\n' > "$legacy_dir/du_setup_report_20260801_010101.txt"
printf 'leave me\n' > "$legacy_dir/unrelated.log"

migrate_legacy_du_setup_logs "$legacy_dir" "$destination"

grep -qx 'new backup log' "$destination/backup_rsync.log"
grep -qx 'existing backup log' "$destination/backup_rsync.log.~1~"
grep -qx 'installer log' "$destination/du_setup_20260801_010101.log"
grep -qx 'report' "$destination/du_setup_report_20260801_010101.txt"
grep -qx 'leave me' "$legacy_dir/unrelated.log"
[[ ! -e "$legacy_dir/backup_rsync.log" ]]

printf 'log layout tests passed\n'
