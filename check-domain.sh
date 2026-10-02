#!/usr/bin/env bash
# =============================================================================
# check-domain.sh — is a domain safe to use as the Fake-TLS tls_domain?
#
# Since June 2026 the TSPU blocks MTProto proxies whose SNI domain does not do
# post-quantum TLS (X25519MLKEM768). This checks EVERY IP of each domain:
#   1. strict  : TLS 1.3 offering only X25519MLKEM768 — must succeed
#   2. browser : TLS 1.3 offering X25519MLKEM768 + X25519 (like Chrome/iOS)
#                — the server must pick X25519MLKEM768 in one round
# A domain is GOOD only if every IP passes both. TLS 1.2-only servers fail.
#
# Needs OpenSSL 3.5+. Ubuntu ships 3.0, so on first run OpenSSL 3.5 is built
# once into /opt/openssl-3.5 (~5-15 min on 1 vCPU). Nothing else is touched.
#
# Usage:
#   ./check-domain.sh                      # check the built-in candidate list
#   ./check-domain.sh drom.ru cian.ru      # check given domains
#   ./check-domain.sh example.ru=1.2.3.4   # check one specific IP
# =============================================================================
set -uo pipefail

OSSL_VER="3.5.4"
OSSL_DIR="/opt/openssl-3.5"
TIMEOUT=8

CANDIDATES=(
    dns-shop.ru citilink.ru chitai-gorod.ru lamoda.ru kassir.ru tutu.ru
    drom.ru auto.ru cian.ru domclick.ru banki.ru sravni.ru vc.ru
    kommersant.ru fontanka.ru e1.ru ngs.ru 74.ru hse.ru itmo.ru spbu.ru
    mipt.ru rutube.ru ozon.ru dzen.ru yandex.ru avito.ru sber.ru vk.com
)

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# --- find or build OpenSSL 3.5+ ---------------------------------------------
OPENSSL=""
for bin in "${OPENSSL_BIN:-}" "$OSSL_DIR/bin/openssl" "$(command -v openssl 2>/dev/null)"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    ver=$("$bin" version 2>/dev/null | awk '{print $2}')
    if [[ "$(printf '%s\n3.5.0\n' "$ver" | sort -V | head -1)" == "3.5.0" ]]; then
        OPENSSL="$bin"; break
    fi
done

if [[ -z "$OPENSSL" ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "OpenSSL 3.5+ not found. Run as root once to build it: sudo $0"
    info "OpenSSL 3.5+ not found — building ${OSSL_VER} into ${OSSL_DIR} (one time) ..."
    apt-get install -y --no-install-recommends gcc make perl curl ca-certificates >/dev/null 2>&1 || true
    BUILD=$(mktemp -d)
    curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OSSL_VER}/openssl-${OSSL_VER}.tar.gz" \
        | tar xz -C "$BUILD" || die "Download failed."
    (cd "$BUILD/openssl-${OSSL_VER}" \
        && ./Configure --prefix="$OSSL_DIR" --libdir=lib no-docs no-tests -Wl,-rpath,"$OSSL_DIR/lib" >/dev/null \
        && make -j"$(nproc)" >/dev/null 2>&1 \
        && make install_sw install_ssldirs >/dev/null 2>&1) || die "Build failed (see $BUILD)."
    rm -rf "$BUILD"
    OPENSSL="$OSSL_DIR/bin/openssl"
fi
info "Using $("$OPENSSL" version)"

# --- one TLS 1.3 handshake; prints "<group>|<cipher>" or "FAIL|<reason>" -----
probe() {   # probe <ip> <sni> [groups]
    local out group cipher
    out=$(timeout "$TIMEOUT" "$OPENSSL" s_client -connect "$1:443" -servername "$2" \
          -tls1_3 ${3:+-groups "$3"} </dev/null 2>&1)
    group=$(sed -n 's/.*Negotiated TLS1.3 group: *//p' <<<"$out" | head -1)
    # classical groups are reported as "Peer Temp Key: X25519, 253 bits"
    [[ -z "$group" || "$group" == "<NULL>" ]] && \
        group=$(sed -n 's/.*Peer Temp Key: *\([^,]*\).*/\1/p' <<<"$out" | head -1)
    cipher=$(sed -n 's/.*Cipher is \(.*\)/\1/p' <<<"$out" | head -1)
    if [[ -n "$group" && "$group" != "<NULL>" && -n "$cipher" && "$cipher" != "(NONE)" ]]; then
        echo "${group}|${cipher}"
    elif grep -q "alert" <<<"$out"; then
        echo "FAIL|$(grep -o 'alert [a-z ]*' <<<"$out" | head -1)"
    else
        echo "FAIL|no TLS 1.3 / timeout"
    fi
}

(( $# )) && DOMAINS=("$@") || DOMAINS=("${CANDIDATES[@]}")
GOOD=()

for entry in "${DOMAINS[@]}"; do
    domain="${entry%%=*}"
    if [[ "$entry" == *=* ]]; then
        ips="${entry#*=}"
    else
        ips=$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)
    fi
    echo ""
    echo -e "\033[1m${domain}\033[0m"
    if [[ -z "$ips" ]]; then echo "  -- DNS: no IPv4 address"; continue; fi

    all_ok=1
    for ip in $ips; do
        strict=$(probe "$ip" "$domain" "X25519MLKEM768")
        # '*' = send a key share for both groups up front, as browsers do
        browser=$(probe "$ip" "$domain" "*X25519MLKEM768:*X25519")
        if [[ "$strict" == X25519MLKEM768\|* && "$browser" == X25519MLKEM768\|* ]]; then
            echo -e "  \033[32mOK  \033[0m ${ip}  TLS1.3 ${browser%%|*} ${browser#*|}"
        else
            all_ok=0
            if [[ "$strict" == FAIL* ]]; then
                why="no PQ (${strict#FAIL|}); browser-like picks: ${browser%%|*}"
            else
                why="accepts PQ only if forced; browser-like picks: ${browser%%|*}"
            fi
            echo -e "  \033[31mBAD \033[0m ${ip}  ${why}"
        fi
    done
    (( all_ok )) && GOOD+=("$domain")
done

echo ""
echo "════════════════════════════════════════════════════════"
if (( ${#GOOD[@]} )); then
    echo -e "\033[1;32mSuitable (every IP does TLS 1.3 + X25519MLKEM768):\033[0m ${GOOD[*]}"
else
    echo -e "\033[1;31mNo suitable domain in this list.\033[0m"
fi
