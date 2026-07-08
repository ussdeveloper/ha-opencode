# syntax=docker/dockerfile:1
# ──────────────────────────────────────────────────────────────
# ha-opencode – Home Assistant add-on
# Web terminal + full dev tools + OpenCode AI
# Supports: amd64, aarch64, armv7, armhf
# ──────────────────────────────────────────────────────────────
FROM alpine:3.20

ARG TARGETARCH
ARG TARGETVARIANT

# ── System packages ──────────────────────────────────────────
RUN apk add --no-cache \
    bash bash-completion \
    git git-lfs \
    curl wget \
    jq yq \
    vim neovim \
    tmux \
    openssh-client \
    python3 py3-pip \
    nodejs npm \
    docker-cli docker-compose \
    htop btop \
    ncdu ripgrep fd tree \
    unzip zip \
    ca-certificates openssl \
    libwebsockets json-c \
    build-base musl-dev \
    && rm -rf /var/cache/apk/*

# ── Python tools ─────────────────────────────────────────────
RUN pip3 install --no-cache-dir --break-system-packages \
    homeassistant-cli \
    pyyaml \
    requests

# ── ttyd – web terminal (multi-arch binary from releases) ────
RUN set -eux; \
    TTYD_VERSION="1.7.7"; \
    case "${TARGETARCH}" in \
        amd64)  TTYD_ARCH="x86_64" ;; \
        arm64)  TTYD_ARCH="aarch64" ;; \
        arm) \
            case "${TARGETVARIANT:-v7}" in \
                v6) TTYD_ARCH="armhf" ;; \
                *)  TTYD_ARCH="arm" ;; \
            esac \
            ;; \
        *) echo "ERROR: unsupported arch ${TARGETARCH}"; exit 1 ;; \
    esac; \
    echo "→ Downloading ttyd ${TTYD_VERSION} for ${TTYD_ARCH}"; \
    wget -q "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
         -O /usr/local/bin/ttyd; \
    chmod +x /usr/local/bin/ttyd; \
    ttyd --version

# ── OpenCode AI ──────────────────────────────────────────────
RUN npm install -g opencode-ai \
    && npm cache clean --force

# ── Directories ──────────────────────────────────────────────
RUN mkdir -p /workspace /data /config /share /backup /ssl /media /addons \
    && chmod 777 /data

# ── Shell environment ────────────────────────────────────────
RUN echo 'alias ll="ls -la --color=auto"'   >> /etc/bash/bashrc && \
    echo 'alias la="ls -A --color=auto"'     >> /etc/bash/bashrc && \
    echo 'alias ha-conf="cd /config"'        >> /etc/bash/bashrc && \
    echo 'alias ha-logs="ls /config/*.log"'  >> /etc/bash/bashrc && \
    echo 'alias oc="opencode"'               >> /etc/bash/bashrc && \
    echo 'alias oca="opencode-attach"'       >> /etc/bash/bashrc && \
    echo 'alias oc-log="tail -f /data/opencode.log"' >> /etc/bash/bashrc && \
    echo 'export OPENCODE_WORKSPACE=/config' >> /etc/bash/bashrc && \
    echo 'export PS1='\''\n\[\033[1;36m\]ha-opencode\[\033[0m\] \[\033[1;33m\]\w\[\033[0m\]\n\[\033[1;32m\]$\[\033[0m\] '\' >> /etc/bash/bashrc; \
    echo 'cd /config' >> /etc/bash/bashrc

# ── Entrypoint ───────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

# ── Helper scripts ───────────────────────────────────────────
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh 2>/dev/null; \
    chmod +x /usr/local/bin/* 2>/dev/null; \
    true

# ── Health check ─────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:7681/ >/dev/null 2>&1 || exit 1

EXPOSE 7681
WORKDIR /config
ENTRYPOINT ["/run.sh"]
