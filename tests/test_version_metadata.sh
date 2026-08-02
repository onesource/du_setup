#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

current_version=$(awk -F'"' '/^CURRENT_VERSION=/{print $2; exit}' "$script_dir/lib/config.sh")
release_date=$(awk '/^\*\*Last Updated:\*\*/{print $3; exit}' "$script_dir/README.md")

[[ -n "$current_version" ]]
[[ "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
grep -Fqx "**Version:** v$current_version" "$script_dir/README.md"
grep -Fqx "## Version $current_version | $release_date" "$script_dir/CHANGELOG.md"
[[ "$(grep -Fc "v$current_version | $release_date" "$script_dir/lib/utils.sh")" -eq 2 ]]

printf 'version metadata tests passed\n'
