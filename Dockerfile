FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        dante-server \
        iproute2 \
        net-tools \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY dante.conf /etc/danted.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Default SOCKS5 port
EXPOSE 1080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD nc -z 127.0.0.1 1080 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
