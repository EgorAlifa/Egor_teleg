#!/usr/bin/env bash
# =============================================================================
# deploy-admin.sh — MTProto Proxy Admin Panel
#
# Builds and runs a small Flask dashboard that reads stats from the mtg proxy
# stats endpoint, stores history in SQLite, and serves a web UI.
#
# Usage:
#   ./deploy-admin.sh [OPTIONS]
#
# Options:
#   --stats-url URL   mtg stats endpoint  (default: http://127.0.0.1:445/stats)
#   --port PORT       panel listen port   (default: 8080)
#   --user USER       admin username      (default: admin)
#   --pass PASS       admin password      (REQUIRED or set ADMIN_PASS env var)
#   --name NAME       proxy display name  (default: MTProto Proxy)
#   --data DIR        SQLite data dir     (default: /opt/mtproto-admin)
#   --poll SECS       poll interval secs  (default: 60)
# =============================================================================
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_DIR="$SCRIPT_DIR/admin"

# ── defaults ─────────────────────────────────────────────────────────────────
STATS_URL="http://127.0.0.1:445/stats"
PANEL_PORT=8080
PANEL_HOST="127.0.0.1"   # bind localhost-only; use SSH tunnel or nginx to expose
ADMIN_USER="admin"
ADMIN_PASS="${ADMIN_PASS:-}"
PROXY_NAME="MTProto Proxy"
DATA_DIR="/opt/mtproto-admin"
POLL_SECS=60
CONTAINER_NAME="mtproto-admin"
IMAGE_NAME="mtproto-admin:latest"
SSH_PORT=2222            # server SSH port (for tunnel instructions)

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stats-url)  STATS_URL="$2";   shift 2 ;;
    --port)       PANEL_PORT="$2";  shift 2 ;;
    --bind)       PANEL_HOST="$2";  shift 2 ;;
    --user)       ADMIN_USER="$2";  shift 2 ;;
    --pass)       ADMIN_PASS="$2";  shift 2 ;;
    --name)       PROXY_NAME="$2";  shift 2 ;;
    --data)       DATA_DIR="$2";    shift 2 ;;
    --poll)       POLL_SECS="$2";   shift 2 ;;
    --ssh-port)   SSH_PORT="$2";    shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ── validate ──────────────────────────────────────────────────────────────────
[[ -z "$ADMIN_PASS" ]] && die "Admin password is required. Use --pass or set ADMIN_PASS env var."
[[ -d "$ADMIN_DIR"  ]] || die "admin/ directory not found at $ADMIN_DIR"

# ── check dependencies ────────────────────────────────────────────────────────
command -v docker &>/dev/null || die "docker not found"

# ── stop & remove existing container ─────────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  info "Removing existing container '$CONTAINER_NAME' ..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# ── build image ───────────────────────────────────────────────────────────────
info "Building admin panel image ..."
docker build -t "$IMAGE_NAME" "$ADMIN_DIR" --quiet
ok "Image built: $IMAGE_NAME"

# ── prepare data dir ─────────────────────────────────────────────────────────
mkdir -p "$DATA_DIR"

# ── run container ─────────────────────────────────────────────────────────────
info "Starting admin panel container on port $PANEL_PORT ..."
docker run \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --detach \
    \
    --network host \
    \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    \
    --volume "$DATA_DIR:/data" \
    \
    --env "STATS_URL=$STATS_URL"     \
    --env "PANEL_PORT=$PANEL_PORT"   \
    --env "PANEL_HOST=$PANEL_HOST"   \
    --env "ADMIN_USER=$ADMIN_USER"   \
    --env "ADMIN_PASS=$ADMIN_PASS"   \
    --env "PROXY_NAME=$PROXY_NAME"   \
    --env "POLL_SECS=$POLL_SECS"     \
    --env "DB_PATH=/data/stats.db"   \
    \
    "$IMAGE_NAME" >/dev/null

ok "Container '$CONTAINER_NAME' started."

# ── wait for health ───────────────────────────────────────────────────────────
info "Waiting for panel to become ready ..."
for i in $(seq 1 15); do
  if curl -sf "http://127.0.0.1:$PANEL_PORT/health" >/dev/null 2>&1; then
    ok "Panel is up!"
    break
  fi
  sleep 1
done

# ── summary ───────────────────────────────────────────────────────────────────
HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Admin Panel is running"
echo "──────────────────────────────────────────────────────────────"
echo "  Bound    : ${PANEL_HOST}:${PANEL_PORT}  (localhost-only)"
echo "  User     : ${ADMIN_USER}"
echo "  Stats src: ${STATS_URL}"
echo "  Data dir : ${DATA_DIR}"
echo "  Poll     : every ${POLL_SECS}s"
echo "──────────────────────────────────────────────────────────────"
echo "  ── Access via SSH tunnel (recommended) ──"
echo "  ssh -p ${SSH_PORT} -N -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${HOST_IP}"
echo "  Then open: http://127.0.0.1:${PANEL_PORT}/"
echo ""
echo "  ── OR expose via nginx (add to server block) ──"
echo "  location /admin/ {"
echo "    proxy_pass         http://127.0.0.1:${PANEL_PORT}/;"
echo "    proxy_set_header   Host \$host;"
echo "    proxy_set_header   X-Real-IP \$remote_addr;"
echo "    auth_basic         \"Admin\";"
echo "    auth_basic_user_file /etc/nginx/.htpasswd;  # optional extra layer"
echo "  }"
echo "──────────────────────────────────────────────────────────────"
echo "  Logs   : docker logs -f ${CONTAINER_NAME}"
echo "  Stop   : docker stop ${CONTAINER_NAME}"
echo "  Remove : docker rm -f ${CONTAINER_NAME}"
echo "══════════════════════════════════════════════════════════════"
