#!/bin/sh
# Entrypoint for the Dante SOCKS5 proxy container.
# Detects the VPN interface and patches the config at runtime.

set -e

log() { echo "[entrypoint] $*"; }

# ── Port ─────────────────────────────────────────────────────────────────────
SOCKS_PORT="${SOCKS_PORT:-1080}"
sed -i "s/port = 1080/port = ${SOCKS_PORT}/" /etc/danted.conf

# ── Optional username/password auth ──────────────────────────────────────────
if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    log "Creating proxy user: $SOCKS_USER"
    # Add system user (no home, no shell) — Dante authenticates via PAM/passwd
    adduser -D -H -s /sbin/nologin "$SOCKS_USER" 2>/dev/null || true
    echo "${SOCKS_USER}:${SOCKS_PASS}" | chpasswd
    # Switch config to username auth
    sed -i 's/socksmethod: none/socksmethod: username/' /etc/danted.conf
    log "Username auth enabled."
fi

# ── VPN interface detection ───────────────────────────────────────────────────
# Prefer tun/ppp/wg (VPN interfaces); fall back to eth0
VPN_IFACE=$(ip -o link show \
    | awk -F': ' '{print $2}' \
    | grep -E '^(tun|ppp|wg|vpn)' \
    | head -n1)

if [ -z "$VPN_IFACE" ]; then
    log "WARNING: No VPN interface found, falling back to eth0"
    VPN_IFACE="eth0"
else
    log "VPN interface detected: $VPN_IFACE"
fi

sed -i "s/^external:.*/external: $VPN_IFACE/" /etc/danted.conf

log "Starting Dante SOCKS5 proxy on 0.0.0.0:${SOCKS_PORT} via ${VPN_IFACE}"
log "Telegram clients: configure SOCKS5 -> host_ip:${SOCKS_PORT}"

exec danted -f /etc/danted.conf
