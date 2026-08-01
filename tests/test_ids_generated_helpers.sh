#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$script_dir/modules/intrusion_detection.sh"

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
mock_dir="$temp_dir/mock-bin"
mkdir -p "$mock_dir"

write_anomaly_detector "$temp_dir/anomaly-detector.sh"
bash -n "$temp_dir/anomaly-detector.sh"

cat > "$mock_dir/top" <<'EOF'
#!/bin/bash
printf '%s\n' '%Cpu(s):  1.0 us,  2.0 sy, 87.0 ni, 10.0 id,  0.0 wa'
EOF
cat > "$mock_dir/bc" <<'EOF'
#!/bin/bash
expression=$(cat)
[[ "$expression" == '90.0 > 80' ]]
printf '1\n'
EOF
cat > "$mock_dir/free" <<'EOF'
#!/bin/bash
printf '%s\n' '              total used free' 'Mem:          100  10   90'
EOF
cat > "$mock_dir/ss" <<'EOF'
#!/bin/bash
printf '%s\n' 'State Recv-Q Send-Q Local Peer'
EOF
cat > "$mock_dir/ps" <<'EOF'
#!/bin/bash
printf '%s\n' 'PID TTY TIME CMD' '1 ? 00:00 init'
EOF
cat > "$mock_dir/df" <<'EOF'
#!/bin/bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/root 100 5 95 5% /'
EOF
chmod +x "$mock_dir"/* "$temp_dir/anomaly-detector.sh"

ANOMALY_ALERT_LOG="$temp_dir/alerts.log" \
PATH="$mock_dir:$PATH" \
    "$temp_dir/anomaly-detector.sh"

grep -q 'High CPU: 90.0%' "$temp_dir/alerts.log"
printf 'IDS generated helper tests passed\n'
