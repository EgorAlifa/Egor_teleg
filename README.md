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
| `check-domain.sh` | Checks candidate Fake-TLS domains for TLS 1.3 + X25519MLKEM768 (June-2026 TSPU marker) |
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
./deploy-mtproto.sh --domain itmo.ru                 # fallback Fake-TLS domain
./deploy-mtproto.sh --syn-limit                     # RST over-limit SYNs (June-2026 TSPU block)
./deploy-mtproto.sh --secret ee<existing-secret>   # reuse saved secret
./deploy-mtproto.sh --max-conn 512                 # override auto-sized connection limit
./deploy-mtproto.sh --shared-vm                    # VM shared with other services
```

### Choosing the Fake-TLS domain

Since June 2026 the TSPU blocks iOS clients (and everyone behind their carrier NAT)
when the Fake-TLS domain does not negotiate post-quantum TLS (X25519MLKEM768).
The default `sravni.ru` and the fallback `itmo.ru` pass on every IP (checked
October 2026). The deploy refuses a domain that fails `check-domain.sh`:

```bash
sudo ./check-domain.sh                  # check the built-in candidate list
sudo ./check-domain.sh example.ru       # check your own candidate
```

Also check a candidate with `@Sni_checker_bot` in Telegram: it flags domains that are
too popular (e.g. `ozon.ru`). Treat its "PQ OK" on a TLSv1.2 answer as a failure.
Changing the domain invalidates all share links.

### When a borrowed domain is blocked: `--own-domain`

Some ISPs (confirmed in October 2026 on a Moscow ISP, while Rostelecom still let
it through) check whether the SNI belongs to the server's IP. The client's
first ~1.4 KB arrives, then every later packet of the flow is dropped, so the
handshake never finishes (`handshake_timeout` grows, `users{…}` does not).
Port, TCPMSS and a tiny TCP window (`--wsize`) did not help; a name that really
resolves to the proxy did:

```bash
sudo ./deploy-mtproto.sh --own-domain --le-email you@example.com
# or with your own domain (A record -> this server):
sudo ./deploy-mtproto.sh --own-domain proxy.example.ru --le-email you@example.com
```

Without a name it uses `<ip-with-dashes>.sslip.io` (free wildcard DNS). The
masking nginx gets a Let's Encrypt certificate (port 80 must be free once for the
HTTP challenge; certbot renews it) and must negotiate X25519MLKEM768 — that needs
OpenSSL 3.5+ (Ubuntu 26.04 has it). A `*.sslip.io` name is easy for a censor to
block as a whole, so your own domain is the sturdier choice. Links change.

Probers without a secret see the masking nginx. Replace mtbuddy's
"Down for maintenance" placeholder with the cover page from this repo
(mtbuddy leaves operator content alone):

```bash
sudo cp masking/index.html /var/www/masking/index.html
```

How to tell this case apart, while the user retries:

```bash
sudo journalctl -u mtproto-proxy -f -o cat | grep --line-buffered "conn stats"
sudo tcpdump -nn -i any 'host <user-ip> and port 443 and tcp[tcpflags] & tcp-fin == 0'
```

Note: iPhones and Macs never send TCP segments smaller than 216 bytes, so the
TCPMSS clamp (88) does not fragment their ClientHello finely.

### Running on a small shared VM (e.g. 1 vCPU / 1 GB)

`--shared-vm` adds systemd drop-ins (`/etc/systemd/system/mtproto-proxy.service.d/shared-vm.conf`)
so the proxy never starves other services on the same machine:

| Setting | Value |
|---------|-------|
| `CPUWeight` / `IOWeight` | 50 (half the default priority) |
| `MemoryMax` | 1/4 of RAM (min 128 MB) |
| `OOMScoreAdjust` | 500 (proxy is killed before other services) |

The auto-sized connection limit is also budgeted on 1/4 of RAM (min 256).
To undo: `rm -r /etc/systemd/system/mtproto-proxy.service.d && systemctl daemon-reload && systemctl restart mtproto-proxy`.

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