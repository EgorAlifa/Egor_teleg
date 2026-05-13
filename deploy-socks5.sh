#!/usr/bin/env bash
# =============================================================================
# deploy-socks5.sh — SOCKS5 proxy (Dante) on port 444
#
# Stops the MTProto proxy if running, removes the 443→444 iptables redirect,
# then builds and starts a Dante SOCKS5 container on port 444.
#
# Usage:
#   ./deploy-socks5.sh [OPTIONS]
#
# Options:
#   --port  <port>   Listen port          (default: 444)
#   --user  <user>   SOCKS5 username      (default: no auth)
#   --pass  <pass>   SOCKS5 password      (default: no auth)
#   --name  <name>   Container name       (default: socks5-proxy)
#   --cpu   <cpus>   CPU cap e.g. 1.0     (default: auto / 50 %)
#   --mem   <mem>    Memory cap e.g. 512m (default: auto / 50 %)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXY_PORT=444
CONTAINER_NAME="socks5-proxy"
IMAGE_NAME="socks5-dante:latest"
MTG_CONTAINER="mtproto-proxy"
SOCKS_USER=""
SOCKS_PASS=""
CPU_LIMIT=""
MEM_LIMIT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  PROXY_PORT="$2";      shift 2 ;;
        --user)  SOCKS_USER="$2";      shift 2 ;;
        --pass)  SOCKS_PASS="$2";      shift 2 ;;
        --name)  CONTAINER_NAME="$2";  shift 2 ;;
        --cpu)   CPU_LIMIT="$2";       shift 2 ;;
        --mem)   MEM_LIMIT="$2";       shift 2 ;;
        --help)
            grep '^# ' "$0" | head -20
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed."

# =============================================================================
# REMOVE iptables redirect 443 → 444 (left over from MTProto deploy)
# =============================================================================
if iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 444 2>/dev/null; then
    info "Removing iptables redirect 443 → 444 ..."
    iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 444
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    ok "iptables redirect removed."
fi

# =============================================================================
# STOP MTProto proxy
# =============================================================================
if docker ps -a --format '{{.Names}}' | grep -q "^${MTG_CONTAINER}$"; then
    info "Stopping and removing MTProto container '${MTG_CONTAINER}' ..."
    docker rm -f "$MTG_CONTAINER"
    ok "MTProto container removed."
fi

# =============================================================================
# RESOURCE LIMITS (50 % of host)
# =============================================================================
if [[ -z "$CPU_LIMIT" ]]; then
    TOTAL_CPUS=$(nproc)
    HALF_CPUS=$(echo "$TOTAL_CPUS / 2" | bc -l | xargs printf "%.2f")
    CPU_LIMIT=$(echo "$HALF_CPUS 0.50" | awk '{print ($1 > $2) ? $1 : $2}')
    info "Auto CPU limit: ${CPU_LIMIT} vCPUs (50 % of ${TOTAL_CPUS})"
fi

if [[ -z "$MEM_LIMIT" ]]; then
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    HALF_MEM_MB=$(( TOTAL_MEM_KB / 2 / 1024 ))
    [[ $HALF_MEM_MB -lt 128 ]] && HALF_MEM_MB=128
    MEM_LIMIT="${HALF_MEM_MB}m"
    info "Auto memory limit: ${MEM_LIMIT}"
fi

# =============================================================================
# REMOVE OLD SOCKS5 CONTAINER
# =============================================================================
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing existing container '${CONTAINER_NAME}' ..."
    docker rm -f "$CONTAINER_NAME"
fi

# =============================================================================
# BUILD IMAGE
# =============================================================================
info "Building SOCKS5 image ..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR" --quiet
ok "Image built: $IMAGE_NAME"

# =============================================================================
# START CONTAINER
# =============================================================================
info "Starting SOCKS5 proxy on port ${PROXY_PORT} ..."

ENV_FLAGS=()
[[ -n "$SOCKS_USER" ]] && ENV_FLAGS+=(--env "SOCKS_USER=$SOCKS_USER")
[[ -n "$SOCKS_PASS" ]] && ENV_FLAGS+=(--env "SOCKS_PASS=$SOCKS_PASS")

docker run \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --detach \
    \
    --cpus "$CPU_LIMIT" \
    --memory "$MEM_LIMIT" \
    --memory-swap "$MEM_LIMIT" \
    \
    --network host \
    \
    --cap-drop ALL \
    --cap-add  NET_BIND_SERVICE \
    --security-opt no-new-privileges \
    \
    --env "SOCKS_PORT=${PROXY_PORT}" \
    "${ENV_FLAGS[@]}" \
    \
    "$IMAGE_NAME" \
    > /dev/null

sleep 2

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    die "Container failed to start. Logs: docker logs ${CONTAINER_NAME}"
fi

HOST_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
       || hostname -I | awk '{print $1}')

AUTH_INFO="no authentication (open proxy)"
[[ -n "$SOCKS_USER" ]] && AUTH_INFO="user: ${SOCKS_USER} / pass: ${SOCKS_PASS}"

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;32m║        TELEGRAM SOCKS5 PROXY — READY                         ║\033[0m"
echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "\033[1m  ── Connection details ──\033[0m"
echo ""
echo "  Server : ${HOST_IP}"
echo "  Port   : ${PROXY_PORT}"
echo "  Type   : SOCKS5"
echo "  Auth   : ${AUTH_INFO}"
echo ""
echo -e "\033[1m  ── One-tap link ──\033[0m"
echo ""
if [[ -n "$SOCKS_USER" ]]; then
    echo "  tg://socks?server=${HOST_IP}&port=${PROXY_PORT}&user=${SOCKS_USER}&pass=${SOCKS_PASS}"
    echo "  https://t.me/socks?server=${HOST_IP}&port=${PROXY_PORT}&user=${SOCKS_USER}&pass=${SOCKS_PASS}"
else
    echo "  tg://socks?server=${HOST_IP}&port=${PROXY_PORT}"
    echo "  https://t.me/socks?server=${HOST_IP}&port=${PROXY_PORT}"
fi
echo ""
echo -e "\033[1m  ── Manual setup in Telegram ──\033[0m"
echo ""
echo "  Desktop/Mobile: Settings → Data & Storage → Proxy → Add Proxy"
echo ""
echo "    Type   : SOCKS5"
echo "    Server : ${HOST_IP}"
echo "    Port   : ${PROXY_PORT}"
[[ -n "$SOCKS_USER" ]] && echo "    User   : ${SOCKS_USER}" && echo "    Pass   : ${SOCKS_PASS}"
echo ""
echo -e "\033[1m  ── Server info ──\033[0m"
echo ""
echo "  Container  : ${CONTAINER_NAME}"
echo "  CPU cap    : ${CPU_LIMIT} vCPUs"
echo "  Memory cap : ${MEM_LIMIT}"
echo ""
echo -e "\033[1m  ── Commands ──\033[0m"
echo ""
echo "  Logs   : docker logs -f ${CONTAINER_NAME}"
echo "  Stop   : docker stop ${CONTAINER_NAME}"
echo "  Remove : docker rm -f ${CONTAINER_NAME}"
echo ""
echo -e "\033[1;32m══════════════════════════════════════════════════════════════\033[0m"
