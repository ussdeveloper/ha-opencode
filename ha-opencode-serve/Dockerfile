# syntax=docker/dockerfile:1
# ha-opencode-serve – OpenCode 2 web UI for Home Assistant
# OpenCode 2 publishes musl binaries for amd64 and aarch64 only.
FROM ghcr.io/home-assistant/base:latest

ARG TARGETARCH
ARG BUILD_ARCH
ARG OPENCODE_VERSION=2.2.6

RUN apk add --no-cache \
        bash bash-completion \
        git git-lfs \
        curl wget ca-certificates \
        jq yq \
        vim \
        openssh-client \
        python3 sqlite \
        nodejs \
        docker-cli docker-cli-compose \
        ripgrep fd tree \
        unzip zip \
        openssl \
        util-linux \
    && rm -rf /var/cache/apk/*

RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
        case "${BUILD_ARCH:-}" in \
            amd64) arch="amd64" ;; \
            aarch64|arm64) arch="arm64" ;; \
            *) echo "Unsupported architecture TARGETARCH=${TARGETARCH:-} BUILD_ARCH=${BUILD_ARCH:-}"; exit 1 ;; \
        esac; \
    fi; \
    case "$arch" in \
        amd64) asset="opencode-linux-x64-musl.tar.gz" ;; \
        arm64) asset="opencode-linux-arm64-musl.tar.gz" ;; \
        *) echo "OpenCode ${OPENCODE_VERSION} has no musl build for ${arch}"; exit 1 ;; \
    esac; \
    wget -q "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${asset}" -O /tmp/opencode.tgz; \
    mkdir -p /tmp/opencode; \
    tar -xzf /tmp/opencode.tgz -C /tmp/opencode; \
    bin="$(find /tmp/opencode -type f -name 'opencode' | head -n 1)"; \
    test -n "$bin"; \
    install -m 755 "$bin" /usr/local/bin/opencode; \
    rm -rf /tmp/opencode /tmp/opencode.tgz; \
    opencode --version

RUN mkdir -p /data /config /share /backup /ssl /media /addons \
    && chmod 777 /data

COPY ingress-proxy.py /usr/local/bin/ingress-proxy.py
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/ingress-proxy.py /usr/local/bin/*.sh \
    && for f in /usr/local/bin/*.sh; do ln -sf "$f" "/usr/local/bin/$(basename "$f" .sh)"; done \
    && printf '%s\n' \
        'alias ll="ls -la --color=auto"' \
        'alias ha-conf="cd /config"' \
        'alias host="host-shell"' \
        'alias ssh-host="ssh-host"' \
        'export LANG=C.UTF-8' \
        'export LC_ALL=C.UTF-8' \
        >> /etc/bash/bashrc

COPY run.sh /run.sh
RUN chmod +x /run.sh

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    OPENCODE_UPSTREAM_PORT=4097 \
    INGRESS_PORT=4096

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python3 -c "import socket,sys; s=socket.create_connection(('127.0.0.1',4096),4); s.sendall(b'GET / HTTP/1.0\r\n\r\n'); sys.exit(0 if s.recv(5)==b'HTTP/' else 1)"

EXPOSE 4096
WORKDIR /config
ENTRYPOINT ["/run.sh"]
