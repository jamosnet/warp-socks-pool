# warp-sb-docker — sing-box 用户态 WireGuard 版 (零特权)
# 架构参考 Mon-ius/Docker-Warp-Socks v8: API 直连注册 + sing-box wireguard endpoint
# 增强: 注册持久化 / 9 端点轮换 / EXPECT 地区校验 / 可选代理认证
FROM debian:bookworm-slim

ARG SINGBOX_VERSION=1.14.2
ARG HTTPS_PROXY
ARG HTTP_PROXY

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates openssl jq && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fL --connect-timeout 20 --retry 3 -o /tmp/sb.tgz \
      "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz" && \
    tar -xzf /tmp/sb.tgz -C /tmp && \
    mv "/tmp/sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box" /usr/bin/sing-box && \
    chmod +x /usr/bin/sing-box && \
    rm -rf /tmp/sb.tgz /tmp/sing-box-* && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /data /etc/sing-box && \
    sing-box version

ENV PROXY_PORT=1080
ENV CHECK_INTERVAL=15
ENV EXPECT=
ENV SOCK_USER=
ENV SOCK_PWD=
ENV WARP_SERVER=engage.cloudflareclient.com
ENV WARP_PORT=2408

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD /healthcheck.sh

EXPOSE 1080
ENTRYPOINT ["/entrypoint.sh"]
