#!/usr/bin/env bash
# watch-users.sh — tail mtproto-proxy logs, print first connection per IP
#
# Usage:
#   ./watch-users.sh [--container NAME] [--db FILE]
#
# Output (stdout + appended to log file):
#   [NEW USER #3] 91.108.4.12  2026-03-21 14:22:01 UTC
#
# Seen IPs are stored one-per-line in DB_FILE (default: /var/lib/mtg-users.txt)
# so the counter survives restarts.

set -euo pipefail

CONTAINER="mtproto-proxy"
DB_FILE="/var/lib/mtg-users.txt"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container) CONTAINER="$2"; shift 2 ;;
        --db)        DB_FILE="$2";   shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$DB_FILE")"
touch "$DB_FILE"

user_count() { wc -l < "$DB_FILE" | tr -d ' '; }

is_new() {
    local ip=$1
    grep -qxF "$ip" "$DB_FILE" && return 1
    return 0
}

record() {
    local ip=$1
    echo "$ip" >> "$DB_FILE"
    local n
    n=$(user_count)
    local ts
    ts=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    local msg="[NEW USER #${n}] ${ip}  ${ts}"
    echo "$msg"
}

echo "[watch-users] following container '${CONTAINER}' — total known users: $(user_count)"

# Follow logs from now onward; also replay last 200 lines to catch connections
# that happened before this script started.
docker logs --tail 200 -f "$CONTAINER" 2>&1 | \
while IFS= read -r line; do
    # mtg v2 logs JSON; extract "remote_addr" or "addr" value, strip port
    ip=$(echo "$line" | grep -oP '"(?:remote_addr|addr)"\s*:\s*"\K[\d\.a-fA-F:]+(?=:\d+")' 2>/dev/null || true)
    [[ -z "$ip" ]] && continue

    # skip loopback
    [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]] && continue

    if is_new "$ip"; then
        record "$ip"
    fi
done
