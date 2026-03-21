# SOCKS5 Proxy for Telegram (Docker / Dante)

A lightweight SOCKS5 proxy that routes traffic through your existing commercial
VPN. Designed to be deployed alongside other running containers without
interference, and capped at **≤ 50 % of host CPU and RAM**.

---

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the Dante SOCKS5 image on Debian slim |
| `dante.conf` | Dante configuration (tuned for Telegram long-lived connections) |
| `entrypoint.sh` | Detects VPN interface at runtime, patches config, starts daemon |
| `deploy.sh` | One-shot deployment script with auto resource limiting |

---

## Quick start

```bash
# 1. Clone / copy files to the server
git clone <repo-url> && cd <repo-dir>

# 2. Make deploy script executable
chmod +x deploy.sh entrypoint.sh

# 3. Deploy (defaults: port 1080, 50 % CPU/RAM)
./deploy.sh

# 4. Optional — custom port or credentials
./deploy.sh --port 1080 --user myuser --pass s3cr3t
```

The script will:
1. Auto-detect your CPU count and total RAM, limit the container to **50 %** of each
2. Build the `socks5-dante` Docker image
3. Start container `socks5-proxy` with `--network host` so it can see your VPN interface (`tun0`, `ppp0`, `wg0`, …)
4. Print the proxy endpoint and a quick test command

---

## Connecting Telegram

In **Telegram Desktop** (or mobile):

```
Settings → Privacy & Security → Proxy → Add Proxy
  Type : SOCKS5
  Host : 185.113.223.34   ← your server IP
  Port : 1080             ← or whichever --port you chose
  User : (leave blank unless you set --user)
  Pass : (leave blank unless you set --pass)
```

---

## Useful commands

```bash
# View live logs
docker logs -f socks5-proxy

# Check resource usage
docker stats socks5-proxy

# Stop / remove
docker stop socks5-proxy
docker rm socks5-proxy

# Quick connectivity test from the server itself
curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
```

---

## Resource limits

| Resource | Limit |
|----------|-------|
| CPU | 50 % of total vCPUs (auto-detected) |
| RAM | 50 % of total RAM (auto-detected) |
| Swap | Disabled for the container |

Override with `--cpu 0.5 --mem 256m` if needed.

---

## Security notes

- The container runs with `--cap-drop ALL` and `--read-only` root filesystem.
- No new privileges can be gained inside the container.
- Restrict access at the firewall level — allow port 1080 only from trusted IPs
  if you don't set a password.
- Logs are written to an in-memory tmpfs and don't persist after container restart.