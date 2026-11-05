#!/bin/bash
# 健康检查: 经 sing-box mixed 代理访问 trace
# EGRESS=v4 / v6(软) 只要能出网即健康; 只有 v6only 才强制要求出口是 IPv6
AUTH=""
[ -n "$SOCK_USER" ] && [ -n "$SOCK_PWD" ] && AUTH="--proxy-user $SOCK_USER:$SOCK_PWD"
PORT="${PROXY_PORT:-1080}"
TRACE=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:"$PORT" $AUTH \
  https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
echo "$TRACE" | grep -Eq "warp=(on|plus)" || { echo "trace: warp 未连通"; exit 1; }
IP=$(echo "$TRACE" | grep -E '^ip=' | cut -d= -f2)

case "${EGRESS:-v6}" in
  v6only)
    echo "$IP" | grep -q ':' && { echo "出口 IP: $IP (IPv6)"; exit 0; }
    echo "v6only 模式但出口不是 IPv6: ${IP:-空}"
    exit 1
    ;;
  v4|4|ipv4)
    echo "出口 IP: ${IP:-未知}"; exit 0
    ;;
  *)
    echo "$IP" | grep -q ':' && { echo "出口 IP: $IP (IPv6)"; exit 0; }
    echo "出口 IP: ${IP:-未知} (IPv4, 软降级可用)"
    exit 0
    ;;
esac
