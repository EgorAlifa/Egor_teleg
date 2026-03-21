# Telegram Proxy — MTProto (high-load) + SOCKS5 (Docker)

Two proxy modes — pick the one that fits your use case:

| Mode | Script | Best for |
|------|--------|----------|
| **MTProto** (recommended) | `deploy-mtproto.sh` | Large number of users, public proxy, high concurrency |
| **SOCKS5** | `deploy.sh` | Personal use, small groups, clients that don't support MTProto |

Both scripts auto-detect open firewall ports and cap resource use at **≤ 50 % CPU / RAM**.

---

## Files

| File | Purpose |
|------|---------|
| `deploy-mtproto.sh` | **High-load MTProto proxy** using mtg v2 (recommended) |
| `deploy.sh` | SOCKS5 proxy using Dante |
| `Dockerfile` | Dante image (used by `deploy.sh`) |
| `dante.conf` | Dante configuration |
| `entrypoint.sh` | VPN-interface detection for SOCKS5 container |

---

## MTProto — quick start (recommended for many users)

```bash
git clone <repo-url> && cd <repo-dir>
chmod +x deploy-mtproto.sh

# Deploy — auto-selects a free open port, generates secret
./deploy-mtproto.sh
```

After deploy the script prints:

```
SECRET : ee4a1b2c3d...           ← the "key" — share this with users
LINK   : https://t.me/proxy?server=185.113.223.34&port=8080&secret=ee...
```

Options:
```bash
./deploy-mtproto.sh --port 8080 --domain www.cloudflare.com
./deploy-mtproto.sh --secret ee<existing-secret>   # reuse saved secret
```

---

## SOCKS5 — quick start (personal / small groups)

```bash
chmod +x deploy.sh entrypoint.sh

./deploy.sh                                    # defaults: port 1080
./deploy.sh --port 1080 --user alice --pass s3cr3t
```

### Connecting Telegram to SOCKS5

```
Settings → Privacy & Security → Proxy → Add Proxy
  Type : SOCKS5
  Host : 185.113.223.34
  Port : 1080
  User / Pass : only if you set --user / --pass
```

---

## Useful commands

```bash
# MTProto
docker logs -f mtproto-proxy
curl -s http://127.0.0.1:8081/stats | python3 -m json.tool   # live stats
docker stats mtproto-proxy
docker rm -f mtproto-proxy

# SOCKS5
docker logs -f socks5-proxy
curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
docker rm -f socks5-proxy
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