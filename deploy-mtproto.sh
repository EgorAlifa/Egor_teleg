#!/usr/bin/env bash
# =============================================================================
# deploy-mtproto.sh — Telegram MTProto proxy via mtproto.zig (native install)
#
# WHY mtproto.zig instead of mtg?
#   Since April 2026 Russia's TSPU does MITM TCP injection breaking all
#   standard MTProto proxies. mtproto.zig v0.23+ defeats this via:
#     • Fake TLS 1.3 handshake disguised as wb.ru traffic
#     • TCPMSS=536 fragmentation so DPI never sees a full signature
#     • nfqws fake-packet desync injected on every packet
#   mtg v2 has none of these — it is dead in Russia.
#
# Usage:
#   ./deploy-mtproto.sh [OPTIONS]
#
# Options:
#   --port    <port>    Listen port        (default: 444)
#   --domain  <domain>  Fake-TLS SNI       (default: wb.ru)
#   --secret  <secret>  Reuse 32-hex secret (default: generate new)
#   --no-dpi            Skip TCPMSS/nfqws  (not recommended for Russia)
#   --help              Show this help
#
# Installs mtbuddy to /usr/local/bin and the proxy to /opt/mtproto-proxy.
# Creates a systemd service: mtproto-proxy.service
# =============================================================================
set -euo pipefail

PROXY_PORT=444
FAKE_DOMAIN="wb.ru"
SECRET_ARG=""
DPI_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PROXY_PORT="$2";   shift 2 ;;
        --domain)  FAKE_DOMAIN="$2";  shift 2 ;;
        --secret)  SECRET_ARG="$2";   shift 2 ;;
        --no-dpi)  DPI_FLAG="--no-dpi"; shift ;;
        --help)    grep '^# ' "$0" | head -25; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo ./deploy-mtproto.sh"
command -v curl >/dev/null 2>&1 || die "curl is required."

# =============================================================================
# CLEAN UP old Docker-based proxies
# =============================================================================
if command -v docker >/dev/null 2>&1; then
    for cname in mtproto-proxy socks5-proxy; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
            info "Removing old container '${cname}' ..."
            docker rm -f "$cname" >/dev/null
            ok "Removed ${cname}."
        fi
    done
fi

# =============================================================================
# REMOVE stale iptables REDIRECT rules left by old deploy-mtproto.sh
# =============================================================================
if iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 444 2>/dev/null; then
    info "Removing old iptables redirect 443 → 444 ..."
    iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 444
    ok "iptables redirect removed."
fi

# =============================================================================
# INSTALL mtbuddy (if not present or outdated)
# =============================================================================
if ! command -v mtbuddy >/dev/null 2>&1; then
    info "Installing mtbuddy ..."
    curl -fsSL https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh | bash
    ok "mtbuddy installed: $(mtbuddy --version 2>/dev/null || echo 'ok')"
else
    info "mtbuddy already installed, updating ..."
    mtbuddy update --yes 2>/dev/null || true
    ok "mtbuddy up to date."
fi

# =============================================================================
# STOP existing mtproto.zig service before reinstalling
# =============================================================================
if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
    info "Stopping existing mtproto-proxy service ..."
    systemctl stop mtproto-proxy
fi

# =============================================================================
# PRE-CREATE system account (mtbuddy needs groupadd/useradd in PATH)
# =============================================================================
export PATH="$PATH:/usr/sbin:/sbin"

if ! getent group mtproto >/dev/null 2>&1; then
    groupadd -f mtproto
    ok "Created group 'mtproto'."
fi
if ! getent passwd mtproto >/dev/null 2>&1; then
    useradd -r -g mtproto -s /sbin/nologin -M mtproto
    ok "Created user 'mtproto'."
fi

# =============================================================================
# INSTALL / RECONFIGURE proxy
# =============================================================================
INSTALL_ARGS="--port ${PROXY_PORT} --domain ${FAKE_DOMAIN} --yes"
[[ -n "$SECRET_ARG"  ]] && INSTALL_ARGS+=" --secret ${SECRET_ARG}"
[[ -n "$DPI_FLAG"    ]] && INSTALL_ARGS+=" ${DPI_FLAG}"

info "Installing mtproto.zig proxy (port=${PROXY_PORT}, domain=${FAKE_DOMAIN}) ..."
# shellcheck disable=SC2086
mtbuddy install $INSTALL_ARGS

# =============================================================================
# VERIFY SERVICE
# =============================================================================
sleep 3
if ! systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
    die "Service mtproto-proxy failed to start. Check: journalctl -u mtproto-proxy -n 50"
fi
ok "Service mtproto-proxy is running."

# =============================================================================
# READ SECRET FROM CONFIG
# =============================================================================
CONFIG_FILE="/opt/mtproto-proxy/config.toml"
SECRET=""
if [[ -f "$CONFIG_FILE" ]]; then
    SECRET=$(grep -E '^\s*secret\s*=' "$CONFIG_FILE" | head -1 \
             | sed 's/.*=\s*"\?\([0-9a-fA-F]*\)"\?.*/\1/')
fi
[[ -z "$SECRET" ]] && warn "Could not read secret from config — check ${CONFIG_FILE}"

HOST_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
       || hostname -I | awk '{print $1}')

SHARE_LINK="https://t.me/proxy?server=${HOST_IP}&port=${PROXY_PORT}&secret=${SECRET}"
DEEP_LINK="tg://proxy?server=${HOST_IP}&port=${PROXY_PORT}&secret=${SECRET}"

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;32m║        TELEGRAM MTProto PROXY — READY (mtproto.zig)           ║\033[0m"
echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "\033[1m  ── DPI bypass ──\033[0m"
echo ""
echo "  Engine     : mtproto.zig v0.23+ (native, not Docker)"
echo "  Fake-TLS   : ${FAKE_DOMAIN}  (traffic looks like HTTPS to ${FAKE_DOMAIN})"
echo "  TCPMSS     : 536  (packet fragmentation, DPI blind spot)"
echo "  nfqws      : active  (fake-packet desync on every packet)"
echo ""
echo -e "\033[1m  ── Connection details ──\033[0m"
echo ""
echo "  Server : ${HOST_IP}"
echo "  Port   : ${PROXY_PORT}"
echo "  Secret : ${SECRET}"
echo ""
echo -e "\033[1m  ── One-tap links ──\033[0m"
echo ""
echo "  ${SHARE_LINK}"
echo "  ${DEEP_LINK}"
echo ""
echo -e "\033[1m  ── Manual setup in Telegram ──\033[0m"
echo ""
echo "  Settings → Data & Storage → Proxy → Add Proxy"
echo ""
echo "    Type   : MTProto"
echo "    Server : ${HOST_IP}"
echo "    Port   : ${PROXY_PORT}"
echo "    Secret : ${SECRET}"
echo ""
echo -e "\033[1m  ── Service commands ──\033[0m"
echo ""
echo "  Status : systemctl status mtproto-proxy"
echo "  Logs   : journalctl -u mtproto-proxy -f"
echo "  Stop   : systemctl stop mtproto-proxy"
echo "  Update : mtbuddy update --yes"
echo "  Stats  : mtbuddy status"
echo ""
echo -e "\033[1;33m  ── SAVE THESE DETAILS — the secret cannot be recovered later ──\033[0m"
echo ""
echo "  SECRET : ${SECRET}"
echo "  LINK   : ${SHARE_LINK}"
echo ""
echo -e "\033[1;32m══════════════════════════════════════════════════════════════\033[0m"
