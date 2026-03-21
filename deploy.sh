#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy a Dante SOCKS5 proxy in Docker (Telegram-optimised)
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [OPTIONS]
#
# Options:
#   --port   <port>     Preferred SOCKS5 port (script finds a free one if busy)
#   --name   <name>     Container name                 (default: socks5-proxy)
#   --user   <user>     Optional SOCKS5 username
#   --pass   <pass>     Optional SOCKS5 password
#   --cpu    <cpus>     CPU limit e.g. 0.5             (default: auto / 50 %)
#   --mem    <mem>      Memory limit e.g. 512m         (default: auto / 50 %)
#   --help              Show this help
#
# The script:
#   1. Scans candidate ports and picks one that is both free locally
#      and allowed through the firewall (iptables / ufw / nftables)
#   2. Caps the container at 50 % host CPU and RAM
#   3. Builds the Docker image, removes old container if any
#   4. Starts with --network host so it sees the VPN interface
#   5. Prints a ready-to-use Telegram proxy config card
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PREFERRED_PORT=1080
CONTAINER_NAME="socks5-proxy"
IMAGE_NAME="socks5-dante"
SOCKS_USER=""
SOCKS_PASS=""
CPU_LIMIT=""
MEM_LIMIT=""

# Ordered list of ports to try — common SOCKS/proxy ports that firewalls often allow
CANDIDATE_PORTS=(1080 1081 8080 8888 3128 9050 4145 8118 2080 10800)

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  PREFERRED_PORT="$2"; shift 2 ;;
        --name)  CONTAINER_NAME="$2"; shift 2 ;;
        --user)  SOCKS_USER="$2";     shift 2 ;;
        --pass)  SOCKS_PASS="$2";     shift 2 ;;
        --cpu)   CPU_LIMIT="$2";      shift 2 ;;
        --mem)   MEM_LIMIT="$2";      shift 2 ;;
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f Dockerfile    ]] || die "Dockerfile not found in $SCRIPT_DIR"
[[ -f dante.conf    ]] || die "dante.conf not found in $SCRIPT_DIR"
[[ -f entrypoint.sh ]] || die "entrypoint.sh not found in $SCRIPT_DIR"

# =============================================================================
# PORT SELECTION
# Strategy:
#   1. Build a set of ports already bound on the host (ss / netstat / /proc/net)
#   2. Build a set of ports explicitly ALLOWED by the active firewall
#      (iptables ACCEPT rules, ufw, nftables)
#   3. Pick the first candidate that is free AND in the allowed set
#      (or just free, with a warning, when we cannot read firewall rules)
# =============================================================================

# ── 1. Ports currently in use (bound by any process) ─────────────────────────
used_ports() {
    # ss is preferred; fall back to /proc/net/tcp{,6}
    if command -v ss &>/dev/null; then
        ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un
    else
        # Parse /proc/net/tcp and /proc/net/tcp6 (hex port in field 2 after ':')
        for f in /proc/net/tcp /proc/net/tcp6; do
            [[ -f "$f" ]] || continue
            awk 'NR>1 && $4=="0A" {print $2}' "$f" \
              | awk -F: '{printf "%d\n", strtonum("0x"$NF)}'
        done | sort -un
    fi
}

USED_PORTS_LIST=$(used_ports)
is_port_used() { echo "$USED_PORTS_LIST" | grep -qx "$1"; }

# ── 2. Firewall-allowed ports ─────────────────────────────────────────────────
# Returns a newline-separated list of TCP ports explicitly ACCEPTed inbound.
# Leaves list empty (unknown) when no firewall tool is available — the caller
# then skips the firewall filter and only checks "not in use".
firewall_allowed_ports() {
    local ports=()

    # ── iptables ──────────────────────────────────────────────────────────────
    if command -v iptables &>/dev/null && iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT"; then
        while IFS= read -r line; do
            # Match lines like: ACCEPT tcp -- anywhere anywhere tcp dpt:1080
            if echo "$line" | grep -qE "ACCEPT.*tcp.*dpt:[0-9]+"; then
                p=$(echo "$line" | grep -oE "dpt:[0-9]+" | grep -oE "[0-9]+")
                [[ -n "$p" ]] && ports+=("$p")
            fi
            # Match port ranges: dpts:1024:65535
            if echo "$line" | grep -qE "ACCEPT.*tcp.*dpts:[0-9]+:[0-9]+"; then
                range=$(echo "$line" | grep -oE "dpts:[0-9]+:[0-9]+" | grep -oE "[0-9]+:[0-9]+")
                lo=${range%%:*}; hi=${range##*:}
                # Record the range as lo:hi — expanded later
                ports+=("RANGE:${lo}:${hi}")
            fi
        done < <(iptables -L INPUT -n 2>/dev/null)
    fi

    # ── nftables ──────────────────────────────────────────────────────────────
    if command -v nft &>/dev/null; then
        while IFS= read -r line; do
            if echo "$line" | grep -qiE "accept" && echo "$line" | grep -qE "dport"; then
                p=$(echo "$line" | grep -oE "dport [0-9]+" | grep -oE "[0-9]+")
                [[ -n "$p" ]] && ports+=("$p")
                # dport { 80, 443, 1080 }
                for p in $(echo "$line" | grep -oE "\{[^}]+\}" | tr -d '{},' | tr ' ' '\n' | grep -E '^[0-9]+$'); do
                    ports+=("$p")
                done
            fi
        done < <(nft list ruleset 2>/dev/null)
    fi

    # ── ufw ───────────────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        while IFS= read -r line; do
            if echo "$line" | grep -qiE "ALLOW"; then
                p=$(echo "$line" | grep -oE "^[0-9]+(/(tcp|udp))?" | grep -oE "^[0-9]+")
                [[ -n "$p" ]] && ports+=("$p")
            fi
        done < <(ufw status numbered 2>/dev/null)
    fi

    # ── cloud / hosting provider — check common metadata ─────────────────────
    # (no-op; cloud security groups are not readable from inside the VM)

    printf "%s\n" "${ports[@]:-}"
}

# Check if a given port falls within any RANGE:lo:hi entry
port_in_range() {
    local port=$1
    local ranges
    ranges=$(echo "$FW_PORTS" | grep "^RANGE:")
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        lo=$(echo "$entry" | cut -d: -f2)
        hi=$(echo "$entry" | cut -d: -f3)
        if (( port >= lo && port <= hi )); then return 0; fi
    done <<< "$ranges"
    return 1
}

FW_PORTS=$(firewall_allowed_ports)
FW_KNOWN=false
[[ -n "$FW_PORTS" ]] && FW_KNOWN=true

is_port_fw_allowed() {
    local port=$1
    $FW_KNOWN || return 0   # firewall rules unreadable — assume OK, warn later
    echo "$FW_PORTS" | grep -qx "$port" && return 0
    port_in_range "$port" && return 0
    return 1
}

# ── 3. Find best port ─────────────────────────────────────────────────────────
# Insert preferred port at the front of the candidate list (deduplicated)
ALL_CANDIDATES=("$PREFERRED_PORT")
for p in "${CANDIDATE_PORTS[@]}"; do
    [[ "$p" != "$PREFERRED_PORT" ]] && ALL_CANDIDATES+=("$p")
done

SOCKS_PORT=""
SKIPPED_USED=()
SKIPPED_FW=()

info "Scanning candidate ports for availability ..."
for port in "${ALL_CANDIDATES[@]}"; do
    if is_port_used "$port"; then
        SKIPPED_USED+=("$port")
        continue
    fi
    if ! is_port_fw_allowed "$port"; then
        SKIPPED_FW+=("$port")
        continue
    fi
    SOCKS_PORT="$port"
    break
done

if [[ -z "$SOCKS_PORT" ]]; then
    # Last resort: any free port, ignoring firewall check
    warn "No ideal port found — picking first free port regardless of firewall rules."
    for port in "${ALL_CANDIDATES[@]}"; do
        if ! is_port_used "$port"; then
            SOCKS_PORT="$port"
            warn "Port ${SOCKS_PORT} may not be open in the firewall — verify manually."
            break
        fi
    done
    [[ -z "$SOCKS_PORT" ]] && die "All candidate ports are in use. Pass --port <free-port> manually."
fi

[[ ${#SKIPPED_USED[@]} -gt 0 ]] && \
    info "Skipped (already bound): ${SKIPPED_USED[*]}"
[[ ${#SKIPPED_FW[@]} -gt 0 ]] && \
    info "Skipped (not in firewall): ${SKIPPED_FW[*]}"
! $FW_KNOWN && \
    warn "Firewall rules could not be read — run as root for accurate port filtering."

ok "Selected port: ${SOCKS_PORT}"

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
    [[ $HALF_MEM_MB -lt 64 ]] && HALF_MEM_MB=64
    MEM_LIMIT="${HALF_MEM_MB}m"
    info "Auto memory limit: ${MEM_LIMIT} (50 % of ~$(( TOTAL_MEM_KB / 1024 )) MB)"
fi

# =============================================================================
# BUILD IMAGE
# =============================================================================
info "Building Docker image '${IMAGE_NAME}' ..."
docker build --no-cache -t "$IMAGE_NAME" "$SCRIPT_DIR"
ok "Image '${IMAGE_NAME}' built."

# =============================================================================
# REMOVE OLD CONTAINER
# =============================================================================
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing existing container '${CONTAINER_NAME}' ..."
    docker rm -f "$CONTAINER_NAME"
fi

# =============================================================================
# START CONTAINER
# =============================================================================
DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    --detach

    # Resource caps
    --cpus "$CPU_LIMIT"
    --memory "$MEM_LIMIT"
    --memory-swap "$MEM_LIMIT"

    # Host network — sees VPN interface (tun0 / ppp0 / wg0) directly
    --network host

    --env SOCKS_USER="${SOCKS_USER}"
    --env SOCKS_PASS="${SOCKS_PASS}"
    --env SOCKS_PORT="${SOCKS_PORT}"

    # Hardened filesystem
    --read-only
    --tmpfs /var/log:rw,noexec,nosuid,size=32m
    --tmpfs /tmp:rw,noexec,nosuid,size=16m
    --tmpfs /run:rw,noexec,nosuid,size=8m

    --cap-drop ALL
    --security-opt no-new-privileges
)

info "Starting container '${CONTAINER_NAME}' ..."
docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME"

# =============================================================================
# PROXY CONFIG CARD
# =============================================================================
sleep 2

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    die "Container failed to start. Check: docker logs ${CONTAINER_NAME}"
fi

# Resolve public/external IP (try multiple sources, fall back to primary iface IP)
HOST_IP=$(curl -s --max-time 4 https://ifconfig.me 2>/dev/null \
       || curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
       || hostname -I | awk '{print $1}')

AUTH_LINE=""
[[ -n "$SOCKS_USER" ]] && AUTH_LINE="  Username   : ${SOCKS_USER}"
PASS_LINE=""
[[ -n "$SOCKS_PASS" ]] && PASS_LINE="  Password   : ${SOCKS_PASS}"

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;32m║         SOCKS5 PROXY — READY                         ║\033[0m"
echo -e "\033[1;32m╚══════════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "\033[1m  ── Connection settings (add to Telegram) ──\033[0m"
echo ""
echo "  Type       : SOCKS5"
echo "  Server     : ${HOST_IP}"
echo "  Port       : ${SOCKS_PORT}"
[[ -n "$AUTH_LINE" ]] && echo "$AUTH_LINE"
[[ -n "$PASS_LINE" ]] && echo "$PASS_LINE"
echo ""
echo -e "\033[1m  ── Telegram quick-link ──\033[0m"
echo ""
if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
    echo "  tg://socks?server=${HOST_IP}&port=${SOCKS_PORT}&user=${SOCKS_USER}&pass=${SOCKS_PASS}"
else
    echo "  tg://socks?server=${HOST_IP}&port=${SOCKS_PORT}"
fi
echo ""
echo -e "\033[1m  ── Telegram Desktop path ──\033[0m"
echo ""
echo "  Settings → Privacy & Security → Proxy → Add Proxy"
echo "    Type   : SOCKS5"
echo "    Server : ${HOST_IP}"
echo "    Port   : ${SOCKS_PORT}"
[[ -n "$SOCKS_USER" ]] && echo "    User   : ${SOCKS_USER}"
[[ -n "$SOCKS_PASS" ]] && echo "    Pass   : ${SOCKS_PASS}"
echo ""
echo -e "\033[1m  ── Container info ──\033[0m"
echo ""
echo "  Container  : ${CONTAINER_NAME}"
echo "  CPU cap    : ${CPU_LIMIT} vCPUs"
echo "  Memory cap : ${MEM_LIMIT}"
echo ""
echo -e "\033[1m  ── Commands ──\033[0m"
echo ""
echo "  Logs       : docker logs -f ${CONTAINER_NAME}"
echo "  Stop       : docker stop ${CONTAINER_NAME}"
echo "  Remove     : docker rm -f ${CONTAINER_NAME}"
echo "  Test       : curl -x socks5h://127.0.0.1:${SOCKS_PORT} https://ifconfig.me"
echo ""
echo -e "\033[1;32m══════════════════════════════════════════════════════\033[0m"
