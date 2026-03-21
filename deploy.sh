#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy a Dante SOCKS5 proxy in Docker
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [OPTIONS]
#
# Options:
#   --port   <port>     Host port to expose SOCKS5 on    (default: 1080)
#   --name   <name>     Container name                   (default: socks5-proxy)
#   --user   <user>     Optional SOCKS5 username
#   --pass   <pass>     Optional SOCKS5 password
#   --cpu    <cpus>     CPU limit (e.g. 0.5 = half a core, default: auto)
#   --mem    <mem>      Memory limit  (e.g. 512m, default: auto)
#   --help              Show this help
#
# The script:
#   1. Detects available CPU/RAM and caps the container at 50 %
#   2. Builds the Docker image if not already present
#   3. Removes any previously running container with the same name
#   4. Starts the container with host-network so it can see the VPN interface
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
SOCKS_PORT=1080
CONTAINER_NAME="socks5-proxy"
IMAGE_NAME="socks5-dante"
SOCKS_USER=""
SOCKS_PASS=""
CPU_LIMIT=""
MEM_LIMIT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  SOCKS_PORT="$2";      shift 2 ;;
        --name)  CONTAINER_NAME="$2";  shift 2 ;;
        --user)  SOCKS_USER="$2";      shift 2 ;;
        --pass)  SOCKS_PASS="$2";      shift 2 ;;
        --cpu)   CPU_LIMIT="$2";       shift 2 ;;
        --mem)   MEM_LIMIT="$2";       shift 2 ;;
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

# ── Pre-flight checks ─────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f Dockerfile ]]  || die "Dockerfile not found in $SCRIPT_DIR"
[[ -f dante.conf ]]  || die "dante.conf not found in $SCRIPT_DIR"
[[ -f entrypoint.sh ]] || die "entrypoint.sh not found in $SCRIPT_DIR"

# ── Resource limit auto-detection (50 % of host) ──────────────────────────────
if [[ -z "$CPU_LIMIT" ]]; then
    TOTAL_CPUS=$(nproc)
    # Use half, minimum 0.5
    HALF_CPUS=$(echo "$TOTAL_CPUS / 2" | bc -l | xargs printf "%.2f")
    CPU_LIMIT=$(echo "$HALF_CPUS 0.50" | awk '{print ($1 > $2) ? $1 : $2}')
    info "Auto CPU limit: ${CPU_LIMIT} vCPUs (50 % of ${TOTAL_CPUS})"
fi

if [[ -z "$MEM_LIMIT" ]]; then
    # /proc/meminfo gives kB — convert to MB, take 50 %
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    HALF_MEM_MB=$(( TOTAL_MEM_KB / 2 / 1024 ))
    # Floor at 64 MB
    [[ $HALF_MEM_MB -lt 64 ]] && HALF_MEM_MB=64
    MEM_LIMIT="${HALF_MEM_MB}m"
    info "Auto memory limit: ${MEM_LIMIT} (50 % of ~$(( TOTAL_MEM_KB / 1024 )) MB)"
fi

# ── Optional auth: rebuild config with username/password ──────────────────────
DANTE_CONF_SRC="$SCRIPT_DIR/dante.conf"
DANTE_CONF_TMP=""

if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
    info "Enabling username/password authentication"
    DANTE_CONF_TMP=$(mktemp /tmp/danted_XXXXXX.conf)
    # Create Linux system user inside image is complex; use PAM-free approach:
    # We switch to username+password auth via /etc/passwd trick in entrypoint.
    # For simplicity, write the credentials to a file the entrypoint will use.
    sed 's/socksmethod: none/socksmethod: username/' "$DANTE_CONF_SRC" \
      | sed 's/clientmethod: none/clientmethod: none/' > "$DANTE_CONF_TMP"
    DANTE_CONF_SRC="$DANTE_CONF_TMP"

    warn "Note: for username auth Dante requires a real system user in the container."
    warn "The deploy script will pass SOCKS_USER/SOCKS_PASS to the container."
    warn "entrypoint.sh will create the user automatically."
fi

# ── Build image ───────────────────────────────────────────────────────────────
info "Building Docker image '${IMAGE_NAME}' ..."
docker build \
    --no-cache \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR"
ok "Image '${IMAGE_NAME}' built."

# ── Remove old container (if any) ─────────────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing existing container '${CONTAINER_NAME}' ..."
    docker rm -f "$CONTAINER_NAME"
fi

# ── Assemble docker run arguments ─────────────────────────────────────────────
DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    --detach

    # Resource caps — never exceed 50 % of the host
    --cpus "$CPU_LIMIT"
    --memory "$MEM_LIMIT"
    --memory-swap "$MEM_LIMIT"   # disable swap for the container

    # Use host network so the container sees the VPN interface (tun0/ppp0/wg0)
    # This means SOCKS_PORT is bound directly on the host interface — no -p needed.
    --network host

    # Pass credentials if provided
    --env SOCKS_USER="${SOCKS_USER}"
    --env SOCKS_PASS="${SOCKS_PASS}"
    --env SOCKS_PORT="${SOCKS_PORT}"

    # Read-only root fs for security, writable /var/log for daemon logs
    --read-only
    --tmpfs /var/log:rw,noexec,nosuid,size=32m
    --tmpfs /tmp:rw,noexec,nosuid,size=16m
    --tmpfs /run:rw,noexec,nosuid,size=8m

    # Drop all capabilities — Dante doesn't need any
    --cap-drop ALL
    --security-opt no-new-privileges
)

# ── Start container ───────────────────────────────────────────────────────────
info "Starting container '${CONTAINER_NAME}' ..."
docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME"

# ── Clean up temp file ────────────────────────────────────────────────────────
[[ -n "$DANTE_CONF_TMP" ]] && rm -f "$DANTE_CONF_TMP"

# ── Status ────────────────────────────────────────────────────────────────────
sleep 2
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    ok "Container '${CONTAINER_NAME}' is running."
    echo ""
    echo "  SOCKS5 proxy endpoint : socks5://$(hostname -I | awk '{print $1}'):${SOCKS_PORT}"
    echo "  CPU limit             : ${CPU_LIMIT} vCPUs"
    echo "  Memory limit          : ${MEM_LIMIT}"
    echo ""
    echo "  Check logs : docker logs -f ${CONTAINER_NAME}"
    echo "  Stop       : docker stop ${CONTAINER_NAME}"
    echo "  Remove     : docker rm -f ${CONTAINER_NAME}"
    echo ""
    echo "  Quick test (from this host):"
    echo "    curl -x socks5h://127.0.0.1:${SOCKS_PORT} https://ifconfig.me"
else
    die "Container failed to start. Check: docker logs ${CONTAINER_NAME}"
fi
