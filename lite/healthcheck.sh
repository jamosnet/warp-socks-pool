#!/bin/bash
# 健康检查: 容器出站流量走 WARP 隧道, trace 里 warp=on 即健康
TRACE=$(curl -s --max-time 8 https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
echo "$TRACE" | grep -Eq "warp=(on|plus)" && exit 0
exit 1
