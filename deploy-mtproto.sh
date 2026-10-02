#!/usr/bin/env bash
# =============================================================================
# deploy-mtproto.sh — Telegram MTProto proxy via mtproto.zig (native install)
#
# WHY mtproto.zig instead of mtg?
#   Since April 2026 Russia's TSPU does MITM TCP injection breaking all
#   standard MTProto proxies. mtproto.zig v0.23+ defeats this via:
#     • Fake TLS 1.3 handshake disguised as traffic to a real Russian site
#     • TCPMSS=536 fragmentation so DPI never sees a full signature
#     • nfqws fake-packet desync injected on every packet
#   mtg v2 has none of these — it is dead in Russia.
#
# Usage:
#   ./deploy-mtproto.sh [OPTIONS]
#
# Options:
#   --port    <port>    Listen port        (default: 443)
#   --domain  <domain>  Fake-TLS SNI       (default: sravni.ru; fallback: itmo.ru)
#                       Must do TLS 1.3 + X25519MLKEM768 on every IP (checked
#                       with check-domain.sh) — since June 2026 the TSPU blocks
#                       iOS clients + their whole NAT when the domain lacks PQ
#   --skip-domain-check Deploy without the PQ domain check
#   --syn-limit         Kernel per-IP SYN limiter with TCP RST (54/min, burst 1)
#                       against the June-2026 TSPU parallel-connect block.
#                       Can throttle many users behind one carrier NAT IP.
#   --secret  <secret>  Reuse a secret: 32 hex, or the full ee... secret from
#                       an old link (default: generate new)
#   --no-dpi            Skip TCPMSS/nfqws  (not recommended for Russia)
#   --max-conn <n>      Max client connections (default: auto, ~1/4 of RAM)
#   --shared-vm         Low CPU/IO priority + RAM cap for the proxy, so it
#                       never starves other services on the same VM
#   --help              Show this help
#
# Installs mtbuddy to /usr/local/bin and the proxy to /opt/mtproto-proxy.
# Creates a systemd service: mtproto-proxy.service
# =============================================================================
set -euo pipefail

PROXY_PORT=443
FAKE_DOMAIN="sravni.ru"
DOMAIN_CHECK="true"
SYN_LIMIT="false"
SECRET_ARG=""
DPI_FLAG=""
FAKE_TLS_ONLY="true"
MAX_CONN=""
SHARED_VM="false"
CONFIG_FILE="/opt/mtproto-proxy/config.toml"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PROXY_PORT="$2";   shift 2 ;;
        --domain)  FAKE_DOMAIN="$2";  shift 2 ;;
        --skip-domain-check) DOMAIN_CHECK="false"; shift ;;
        --syn-limit) SYN_LIMIT="true"; shift ;;
        --secret)  SECRET_ARG="$2";   shift 2 ;;
        --no-dpi)  DPI_FLAG="--no-dpi"; shift ;;
        --allow-dd) FAKE_TLS_ONLY="false"; shift ;;
        --max-conn)  MAX_CONN="$2"; shift 2
                     [[ "$MAX_CONN" =~ ^[0-9]+$ ]] || { echo "--max-conn needs a number"; exit 1; } ;;
        --shared-vm) SHARED_VM="true"; shift ;;
        --help)    sed -n '/^# Usage:/,/^# =====/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo ./deploy-mtproto.sh"
command -v curl >/dev/null 2>&1 || die "curl is required."

# Accept the bare 32-hex user secret or a full ee/dd secret copied from a link.
if [[ -n "$SECRET_ARG" ]]; then
    [[ "$SECRET_ARG" =~ ^(ee|dd)([0-9a-fA-F]{32}) ]] && SECRET_ARG="${BASH_REMATCH[2]}"
    [[ "$SECRET_ARG" =~ ^[0-9a-fA-F]{32}$ ]] || die "--secret must be 32 hex chars or an ee.../dd... link secret."
fi

# =============================================================================
# CHECK Fake-TLS domain: TLS 1.3 + X25519MLKEM768 on every IP (June-2026 TSPU)
# =============================================================================
if [[ "$DOMAIN_CHECK" == "true" ]]; then
    CHECKER="$(dirname "$(readlink -f "$0")")/check-domain.sh"
    [[ -f "$CHECKER" ]] || die "check-domain.sh not found next to this script (or pass --skip-domain-check)."
    info "Checking Fake-TLS domain '${FAKE_DOMAIN}' for post-quantum TLS ..."
    bash "$CHECKER" "$FAKE_DOMAIN" || die "Domain '${FAKE_DOMAIN}' fails the PQ check — TSPU would block iOS clients. Pick another (./check-domain.sh lists candidates) or pass --skip-domain-check."
    ok "Domain '${FAKE_DOMAIN}' does TLS 1.3 + X25519MLKEM768."
fi

# =============================================================================
# INSTALL build dependencies (gcc, nfqueue libs needed for nfqws)
# =============================================================================
info "Installing build dependencies ..."
apt-get install -y --no-install-recommends \
    gcc zlib1g-dev libnetfilter-queue-dev libmnl-dev libnfnetlink-dev libcap-dev \
    >/dev/null 2>&1 && ok "Build dependencies installed." || \
    warn "apt-get failed — assuming dependencies already present."

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
# mtbuddy spawns children with empty environment — symlinks fix path lookups.
# =============================================================================
export PATH="$PATH:/usr/sbin:/sbin"

# Symlinks so mtbuddy (empty-env child) finds tools at its hardcoded paths
ln -sf /usr/sbin/iptables   /usr/bin/iptables   2>/dev/null || true
ln -sf /usr/sbin/ip6tables  /usr/bin/ip6tables  2>/dev/null || true
ln -sf /usr/bin/bash        /usr/local/bin/bash 2>/dev/null || true
ln -sf /usr/bin/env         /usr/local/bin/env  2>/dev/null || true

# gcc cc1 lives in /usr/libexec on Ubuntu 24.04 but gcc looks in /usr/lib
if [[ -d /usr/libexec/gcc && ! -e /usr/lib/gcc ]]; then
    ln -sf /usr/libexec/gcc /usr/lib/gcc
fi

if ! getent group mtproto >/dev/null 2>&1; then
    groupadd -f mtproto
    ok "Created group 'mtproto'."
fi
if ! getent passwd mtproto >/dev/null 2>&1; then
    useradd -r -g mtproto -s /sbin/nologin -M mtproto
    ok "Created user 'mtproto'."
fi

# Pre-build nfqws manually (mtbuddy's make uses 'cc' which can't find cc1)
if [[ ! -x /opt/zapret/nfq/nfqws ]]; then
    info "Pre-building nfqws with gcc ..."
    BUILD_DIR=$(mktemp -d)
    git clone --depth=1 https://github.com/bol-van/zapret "$BUILD_DIR/zapret" -q
    gcc -s -std=gnu99 -Os -o "$BUILD_DIR/zapret/nfq/nfqws" \
        "$BUILD_DIR/zapret/nfq/"*.c "$BUILD_DIR/zapret/nfq/crypto/"*.c \
        -lz -lnetfilter_queue -lnfnetlink -lmnl
    mkdir -p /opt/zapret/nfq
    cp -r "$BUILD_DIR/zapret/"* /opt/zapret/
    chmod +x /opt/zapret/nfq/nfqws
    rm -rf "$BUILD_DIR"
    ok "nfqws built and placed at /opt/zapret/nfq/nfqws"
fi

# =============================================================================
# PRE-FIX nginx default config (Ubuntu default listens on [::]:80 which
# fails on servers without IPv6 support, breaking mtbuddy's nginx masking)
# =============================================================================
for f in /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default; do
    [[ -f "$f" ]] && sed -i '/\[::\]/d' "$f"
done

# =============================================================================
# PICK nginx masking port — avoid 8443 if Xray already owns it
# =============================================================================
MASK_PORT=8443
if ss -tlnp | grep -q ':8443 '; then
    MASK_PORT=18443
    info "Port 8443 in use (Xray), using ${MASK_PORT} for nginx masking."
fi

# =============================================================================
# INSTALL / RECONFIGURE proxy
# =============================================================================
# Auto-size max connections: 1024 per 256MB, budgeted on 1/4 of RAM so the
# proxy leaves room for the OS and any other services on the VM.
if [[ -z "$MAX_CONN" ]]; then
    TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    MAX_CONN=$(( TOTAL_MEM_MB / 4 * 1024 / 256 ))
    [[ $MAX_CONN -lt 256  ]] && MAX_CONN=256
    [[ $MAX_CONN -gt 65535 ]] && MAX_CONN=65535
fi
info "Max connections: ${MAX_CONN}"

INSTALL_ARGS="--port ${PROXY_PORT} --domain ${FAKE_DOMAIN} --yes --max-connections ${MAX_CONN}"
[[ -n "$SECRET_ARG"  ]] && INSTALL_ARGS+=" --secret ${SECRET_ARG}"
[[ -n "$DPI_FLAG"    ]] && INSTALL_ARGS+=" ${DPI_FLAG}"

info "Installing mtproto.zig proxy (port=${PROXY_PORT}, domain=${FAKE_DOMAIN}) ..."
# shellcheck disable=SC2086
mtbuddy install $INSTALL_ARGS

# =============================================================================
# FORCE domain + fake_tls_only into config (mtbuddy preserves existing config)
# =============================================================================
if [[ -f "$CONFIG_FILE" ]]; then
    CURRENT_DOMAIN=$(grep -E '^\s*tls_domain\s*=' "$CONFIG_FILE" | head -1 \
                     | sed 's/.*=\s*"\?\([^"]*\)"\?.*/\1/' | tr -d '"')
    if [[ -n "$CURRENT_DOMAIN" && "$CURRENT_DOMAIN" != "$FAKE_DOMAIN" ]]; then
        info "Updating tls_domain: '${CURRENT_DOMAIN}' → '${FAKE_DOMAIN}' ..."
        sed -i "s/tls_domain = \"${CURRENT_DOMAIN}\"/tls_domain = \"${FAKE_DOMAIN}\"/" "$CONFIG_FILE"
        ok "tls_domain updated."
        CONFIG_CHANGED=1
    fi

    # Rotate secret (generate new unless --secret was explicitly passed)
    if [[ -n "$SECRET_ARG" ]]; then
        NEW_SECRET="$SECRET_ARG"
    else
        NEW_SECRET=$(openssl rand -hex 16)
    fi
    sed -i "s/user = \"[0-9a-fA-F]\{32\}\"/user = \"${NEW_SECRET}\"/" "$CONFIG_FILE"
    ok "Secret rotated: ${NEW_SECRET}"
    CONFIG_CHANGED=1

    # Ensure [censorship] section exists
    if ! grep -q '^\[censorship\]' "$CONFIG_FILE" 2>/dev/null; then
        echo -e "\n[censorship]" >> "$CONFIG_FILE"
    fi

    # Set fake_tls_only
    if grep -q '^\s*fake_tls_only\s*=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^\s*fake_tls_only\s*=.*/fake_tls_only = ${FAKE_TLS_ONLY}/" "$CONFIG_FILE"
    else
        sed -i '/^\[censorship\]/a fake_tls_only = '"${FAKE_TLS_ONLY}" "$CONFIG_FILE"
    fi
    ok "fake_tls_only = ${FAKE_TLS_ONLY}"

    if [[ "${CONFIG_CHANGED:-0}" -eq 1 ]]; then
        systemctl restart mtproto-proxy 2>/dev/null || true
    fi
fi

# Fix nginx masking port if Xray owns 8443
if [[ "$MASK_PORT" -ne 8443 ]]; then
    if grep -q '127\.0\.0\.1:8443' /etc/nginx/sites-available/mtproto-masking 2>/dev/null; then
        sed -i "s/127\.0\.0\.1:8443/127.0.0.1:${MASK_PORT}/g" /etc/nginx/sites-available/mtproto-masking
        sed -i "s/mask_port = 8443/mask_port = ${MASK_PORT}/" /opt/mtproto-proxy/config.toml 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        ok "nginx masking port changed to ${MASK_PORT}."
    fi
fi

# =============================================================================
# SYN LIMIT: RST over-limit SYNs so clients retry fast (June-2026 TSPU block)
# =============================================================================
if [[ "$SYN_LIMIT" == "true" ]]; then
    info "Enabling per-IP SYN limiter (REJECT, 54/minute, burst 1) ..."
    mtbuddy setup syn-limit --reject --rate 54/minute --burst 1 \
        && ok "SYN limiter enabled. Undo: mtbuddy setup syn-limit --remove" \
        || warn "mtbuddy setup syn-limit failed — continuing without it."
fi

# =============================================================================
# SHARED VM: lower proxy priority so co-located services keep working
# =============================================================================
if [[ "$SHARED_VM" == "true" ]]; then
    TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    PROXY_MEM_MAX=$(( TOTAL_MEM_MB / 4 ))
    [[ $PROXY_MEM_MAX -lt 128 ]] && PROXY_MEM_MAX=128
    for svc in mtproto-proxy nfqws-mtproto; do
        mkdir -p "/etc/systemd/system/${svc}.service.d"
        {
            echo "[Service]"
            echo "CPUWeight=50"
            echo "IOWeight=50"
            echo "OOMScoreAdjust=500"
            if [[ "$svc" == "mtproto-proxy" ]]; then echo "MemoryMax=${PROXY_MEM_MAX}M"; fi
        } > "/etc/systemd/system/${svc}.service.d/shared-vm.conf"
    done
    systemctl daemon-reload
    systemctl restart mtproto-proxy 2>/dev/null || true
    systemctl try-restart nfqws-mtproto 2>/dev/null || true
    ok "Shared-VM limits: CPUWeight=50, MemoryMax=${PROXY_MEM_MAX}M for mtproto-proxy."
fi

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
# mtbuddy keeps it as `user = "<32 hex>"` under [access.users]. A Fake-TLS link
# needs the full form: "ee" + that secret + hex(tls_domain).
# =============================================================================
SECRET=""
if [[ -f "$CONFIG_FILE" ]]; then
    USER_SECRET=$(awk '/^\[/ {in_users = ($0 ~ /^\[access\.users\]/); next}
                      in_users && match($0, /"[0-9a-fA-F]{32}"/) {print substr($0, RSTART+1, 32); exit}' "$CONFIG_FILE")
    LINK_DOMAIN=$(sed -n 's/^\s*tls_domain\s*=\s*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)
    LINK_DOMAIN="${LINK_DOMAIN:-$FAKE_DOMAIN}"
    if [[ -n "$USER_SECRET" ]]; then
        SECRET="ee${USER_SECRET}$(printf '%s' "$LINK_DOMAIN" | od -An -tx1 | tr -d ' \n')"
    fi
fi
[[ -z "$SECRET" ]] && warn "Could not read secret from config — run: mtbuddy links"

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
