#!/usr/bin/env bash
# =============================================================================
# deploy-relay.sh — TCP relay: forwards port 444 to the real proxy server.
#
# Run this on the RELAY server (clean European VPS).
# The MTProto proxy stays on the original server.
#
# Usage:
#   ./deploy-relay.sh --target <proxy_ip> [--port <port>]
#
# Options:
#   --target <ip>    IP of the real MTProto proxy server (REQUIRED)
#   --port   <port>  Port to relay (default: 444)
# =============================================================================
set -euo pipefail

TARGET_IP=""
RELAY_PORT=444

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET_IP="$2"; shift 2 ;;
        --port)   RELAY_PORT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
die()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

[[ -z "$TARGET_IP" ]] && die "Required: --target <proxy_ip>"
[[ "$(id -u)" -eq 0 ]] || die "Run as root."

command -v apt-get >/dev/null 2>&1 || die "apt-get not found."

info "Installing nginx ..."
apt-get update -qq
apt-get install -y --no-install-recommends nginx

# Remove IPv6 from default config to avoid startup failure
for f in /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default; do
    [[ -f "$f" ]] && sed -i '/\[::\]/d' "$f"
done

# Write stream relay config
mkdir -p /etc/nginx/stream.conf.d
cat > /etc/nginx/stream.conf.d/mtproto-relay.conf <<EOF
server {
    listen ${RELAY_PORT};
    proxy_pass ${TARGET_IP}:${RELAY_PORT};
    proxy_timeout 1d;
    proxy_connect_timeout 5s;
}
EOF

# Add stream block to nginx.conf if not already there
if ! grep -q '^stream' /etc/nginx/nginx.conf; then
    echo 'stream { include /etc/nginx/stream.conf.d/*.conf; }' >> /etc/nginx/nginx.conf
fi

nginx -t || die "nginx config test failed."
systemctl enable nginx
systemctl restart nginx

RELAY_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || hostname -I | awk '{print $1}')

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;32m║        RELAY SERVER — READY                                  ║\033[0m"
echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════╝\033[0m"
echo ""
echo "  Relay IP  : ${RELAY_IP}"
echo "  Port      : ${RELAY_PORT}"
echo "  Forwards  : ${TARGET_IP}:${RELAY_PORT}"
echo ""
echo "  Пользователям менять только IP в ссылке:"
echo "  tg://proxy?server=${RELAY_IP}&port=${RELAY_PORT}&secret=<тот_же_секрет>"
echo ""
echo "  Секрет взять командой на основном сервере: sudo mtbuddy links"
echo ""
echo -e "\033[1;32m══════════════════════════════════════════════════════════════\033[0m"
