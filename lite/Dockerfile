# warp-wg-docker — 内核 WireGuard 极简版
# 不用官方 warp-svc (92M): wgcf 注册 + 内核 WireGuard (工具才几 MB) + gost
# 代价: WireGuard-only, 断线重连靠 entrypoint 守护循环 (端点轮换)
FROM debian:bookworm-slim

ARG WGCF_VERSION=2.3.1
ARG GOST_VERSION=2.12.0
ARG HTTPS_PROXY
ARG HTTP_PROXY

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates iproute2 wireguard-tools openresolv procps iptables && \
    curl -fL --connect-timeout 20 --retry 3 -o /usr/bin/wgcf \
      "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_$(dpkg --print-architecture)" && \
    chmod +x /usr/bin/wgcf && \
    curl -fL --connect-timeout 20 --retry 3 -o /tmp/gost.tgz \
      "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_$(dpkg --print-architecture).tar.gz" && \
    tar -xzf /tmp/gost.tgz -C /usr/bin/ gost && \
    chmod +x /usr/bin/gost && rm -f /tmp/gost.tgz && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# wgcf 账号/配置持久化目录
RUN mkdir -p /etc/wireguard

ENV PROXY_PORT=1080
ENV CHECK_INTERVAL=15
ENV EXPECT=

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD /healthcheck.sh

EXPOSE 1080
ENTRYPOINT ["/entrypoint.sh"]
