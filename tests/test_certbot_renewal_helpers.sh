#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$script_dir/modules/nginx_cert_manager.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

hook_index=0
capturing=false
while IFS= read -r line; do
    # Match the literal heredoc opener in the generated module.
    # shellcheck disable=SC2016
    if [[ "$line" == '    cat > "$staged" <<'\''EOF'\''' ]]; then
        hook_index=$((hook_index + 1))
        capturing=true
        continue
    fi
    if [[ "$capturing" == true && "$line" == EOF ]]; then
        capturing=false
        continue
    fi
    if [[ "$capturing" == true ]]; then
        printf '%s\n' "$line" >> "$temp_dir/hook-$hook_index"
    fi
done < "$source_file"

[[ "$hook_index" -eq 3 ]]
for hook in "$temp_dir"/hook-*; do
    bash -n "$hook"
done

cat > "$temp_dir/crontab" <<'EOF'
0 12 * * * /usr/bin/certbot renew --quiet --post-hook old
0 2 * * * /opt/nginx/scripts/auto_security_scan.sh
# /usr/bin/certbot renew --quiet
MAILTO=ops@example.com
0 3 * * * certbot renew --quiet
EOF

awk '
    !($0 !~ /^[[:space:]]*#/ &&
      $0 ~ /(^|[[:space:]\/])certbot[[:space:]]+renew([[:space:]]|$)/)
' "$temp_dir/crontab" > "$temp_dir/filtered"

grep -qx '0 2 \* \* \* /opt/nginx/scripts/auto_security_scan.sh' "$temp_dir/filtered"
grep -qx '# /usr/bin/certbot renew --quiet' "$temp_dir/filtered"
grep -qx 'MAILTO=ops@example.com' "$temp_dir/filtered"
[[ "$(wc -l < "$temp_dir/filtered")" -eq 3 ]]

printf 'certbot renewal helper tests passed\n'
