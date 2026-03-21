#!/usr/bin/env bash
# =============================================================================
# deploy-mtproto.sh — High-load Telegram MTProto proxy (mtg v2)
#
# WHY MTProto instead of SOCKS5?
#   MTProto is Telegram's native protocol. mtg (Go) handles 50 000+
#   concurrent connections on a single core, auto-generates an obfuscated
#   secret, and disguises traffic as HTTPS (fake-TLS) — far more scalable
#   and reliable than generic SOCKS5 for a shared public proxy.
#
# Usage:
#   chmod +x deploy-mtproto.sh
#   ./deploy-mtproto.sh [OPTIONS]
#
# Options:
#   --port    <port>    Preferred port (auto-selected if busy/blocked)
#   --domain  <domain>  Fake-TLS SNI domain     (default: www.google.com)
#   --secret  <secret>  Reuse an existing secret (default: generate new)
#   --name    <name>    Container name           (default: mtproto-proxy)
#   --cpu     <cpus>    CPU cap e.g. 1.0         (default: auto / 50 %)
#   --mem     <mem>     Memory cap e.g. 512m     (default: auto / 50 %)
#   --help              Show this help
#
# After deploy the script prints:
#   • The obfuscated SECRET (the "key" users share)
#   • A one-tap tg:// deep link
#   • A https://t.me/proxy share link
#   • Step-by-step manual setup for Telegram Desktop / Mobile
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PREFERRED_PORT=444
CONTAINER_NAME="mtproto-proxy"
MTG_IMAGE="ghcr.io/9seconds/mtg:2"
FAKE_TLS_DOMAIN="www.google.com"
SECRET=""
CPU_LIMIT=""
MEM_LIMIT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PREFERRED_PORT="$2";    shift 2 ;;
        --domain)  FAKE_TLS_DOMAIN="$2";   shift 2 ;;
        --secret)  SECRET="$2";            shift 2 ;;
        --name)    CONTAINER_NAME="$2";    shift 2 ;;
        --cpu)     CPU_LIMIT="$2";         shift 2 ;;
        --mem)     MEM_LIMIT="$2";         shift 2 ;;
        --help)
            sed -n '/^# Usage/,/^# ====/p' "$0" | head -n -1
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."

# =============================================================================
# PORT SELECTION — use the preferred port directly.
# The old container is removed later (before docker run), so the port is free.
# Pass --port <N> to override.
# =============================================================================
PROXY_PORT="$PREFERRED_PORT"
ok "Using port: ${PROXY_PORT}"

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
    info "Auto memory limit: ${MEM_LIMIT} (50 % of ~$(( TOTAL_MEM_KB / 1024 )) MB)"
fi

# =============================================================================
# GENERATE SECRET (if not supplied)
# The secret is the "key" shared with users. It encodes the fake-TLS domain
# so Telegram clients know which SNI to use when connecting.
# =============================================================================
if [[ -z "$SECRET" ]]; then
    info "Pulling mtg image: ${MTG_IMAGE} ..."
    docker pull --quiet "$MTG_IMAGE"

    info "Generating MTProto secret (fake-TLS domain: ${FAKE_TLS_DOMAIN}) ..."

    # mtg v2 syntax: generate-secret <hostname>
    # Use --hex for predictable output; fall back without it if unsupported.
    SECRET=$(docker run --rm "$MTG_IMAGE" generate-secret --hex "${FAKE_TLS_DOMAIN}" 2>/dev/null || true)
    [[ -z "$SECRET" ]] && \
        SECRET=$(docker run --rm "$MTG_IMAGE" generate-secret "${FAKE_TLS_DOMAIN}" 2>/dev/null || true)
else
    info "Using provided secret."
fi

[[ -z "$SECRET" ]] && die "Failed to generate secret. Run manually to debug:
  docker run --rm ${MTG_IMAGE} generate-secret --help"

# =============================================================================
# REMOVE OLD CONTAINER
# =============================================================================
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing existing container '${CONTAINER_NAME}' ..."
    docker rm -f "$CONTAINER_NAME"
fi

# =============================================================================
# WRITE CONFIG FILE
# mtg v2 requires a TOML config file; it does not accept CLI arguments for
# the secret or bind address.
# =============================================================================
MTG_CONFIG_DIR="/etc/mtg"
MTG_CONFIG_FILE="${MTG_CONFIG_DIR}/config.toml"
mkdir -p "$MTG_CONFIG_DIR"
cat > "$MTG_CONFIG_FILE" <<TOML
secret    = "${SECRET}"
bind-to   = "0.0.0.0:${PROXY_PORT}"
stats-bind = "127.0.0.1:$((PROXY_PORT + 1))"
TOML
chmod 600 "$MTG_CONFIG_FILE"
ok "Config written to ${MTG_CONFIG_FILE}"

# =============================================================================
# START CONTAINER
# High-load tuning:
#   --ulimit nofile  — allow hundreds of thousands of open file descriptors
#   --network host   — bypass Docker NAT; bind directly on the host interface
# Note: --sysctl flags are not allowed with --network host (host-namespace
# sysctls must be set on the host itself, not via Docker).
# =============================================================================
info "Starting MTProto proxy container ..."
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
    --ulimit nofile=1048576:1048576 \
    \
    --cap-drop ALL \
    --cap-add  NET_BIND_SERVICE \
    --security-opt no-new-privileges \
    \
    --volume "${MTG_CONFIG_FILE}:/config.toml:ro" \
    \
    "$MTG_IMAGE" \
    run /config.toml \
    > /dev/null

# =============================================================================
# PROXY CONFIG CARD
# =============================================================================
sleep 2

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    die "Container failed to start. Logs: docker logs ${CONTAINER_NAME}"
fi

HOST_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
       || hostname -I | awk '{print $1}')

STATS_PORT=$((PROXY_PORT + 1))
SHARE_LINK="https://t.me/proxy?server=${HOST_IP}&port=${PROXY_PORT}&secret=${SECRET}"
DEEP_LINK="tg://proxy?server=${HOST_IP}&port=${PROXY_PORT}&secret=${SECRET}"

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;32m║        TELEGRAM MTProto PROXY — READY                        ║\033[0m"
echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "\033[1m  ── Your proxy secret (share this with users) ──\033[0m"
echo ""
echo "  SECRET : ${SECRET}"
echo ""
echo -e "\033[1m  ── One-tap connection links ──\033[0m"
echo ""
echo "  Share link  (works in browser / chat):"
echo "  ${SHARE_LINK}"
echo ""
echo "  Deep link (paste in Telegram → open directly):"
echo "  ${DEEP_LINK}"
echo ""
echo -e "\033[1m  ── Manual setup in Telegram ──\033[0m"
echo ""
echo "  Desktop:  Settings → Privacy & Security → Proxy → Add Proxy"
echo "  Mobile:   Settings → Data & Storage → Proxy → Add Proxy"
echo ""
echo "    Type   : MTProto"
echo "    Server : ${HOST_IP}"
echo "    Port   : ${PROXY_PORT}"
echo "    Secret : ${SECRET}"
echo ""
echo -e "\033[1m  ── Server info ──\033[0m"
echo ""
echo "  Container  : ${CONTAINER_NAME}"
echo "  Image      : ${MTG_IMAGE}"
echo "  CPU cap    : ${CPU_LIMIT} vCPUs"
echo "  Memory cap : ${MEM_LIMIT}"
echo "  Fake-TLS   : ${FAKE_TLS_DOMAIN}  (traffic looks like HTTPS)"
echo "  Stats      : curl http://127.0.0.1:${STATS_PORT}/stats  (on server)"
echo ""
echo -e "\033[1m  ── Commands ──\033[0m"
echo ""
echo "  Logs       : docker logs -f ${CONTAINER_NAME}"
echo "  Stats      : curl -s http://127.0.0.1:${STATS_PORT}/stats | python3 -m json.tool"
echo "  Stop       : docker stop ${CONTAINER_NAME}"
echo "  Remove     : docker rm -f ${CONTAINER_NAME}"
echo ""
echo -e "\033[1;33m  ── SAVE THESE DETAILS — the secret cannot be recovered later ──\033[0m"
echo ""
echo "  SECRET : ${SECRET}"
echo "  LINK   : ${SHARE_LINK}"
echo ""
echo -e "\033[1;32m══════════════════════════════════════════════════════════════\033[0m"
