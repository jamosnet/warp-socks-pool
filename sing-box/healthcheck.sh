#!/bin/bash
# 健康检查: 经 sing-box mixed 代理访问 trace, warp=on 即健康
AUTH=""
[ -n "$SOCK_USER" ] && [ -n "$SOCK_PWD" ] && AUTH="--proxy-user $SOCK_USER:$SOCK_PWD"
TRACE=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:"${PROXY_PORT:-1080}" $AUTH \
  https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
echo "$TRACE" | grep -Eq "warp=(on|plus)" && exit 0
exit 1
