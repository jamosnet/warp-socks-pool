#!/bin/bash
# warp-wg-docker entrypoint (内核 WireGuard 极简版)
# 流程: 注册(持久化) -> wg-quick up -> 握手+可用性检查(端点轮换) -> gost -> 守护循环
set -u

IFACE=wgcf
CONF=/etc/wireguard/wgcf.conf
PROXY_PORT="${PROXY_PORT:-1080}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
EXPECT="${EXPECT:-}"

log() { echo "[entrypoint] $(date '+%H:%M:%S') $*"; }

# 端点池: IP × 端口 交叉矩阵, 端口优先 (同一 IP 有 2408/500/1701/4500 多个端口)
# 顺序: 先所有 IP 的 2408, 再所有 IP 的 500, 依次类推
WARP_IPS=(
  "engage.cloudflareclient.com"
  "162.159.192.1"
  "162.159.193.1"
  "162.159.195.1"
  "162.159.198.1"
  "188.114.96.1"
  "188.114.97.1"
  "188.114.99.1"
)
# 端口: 官方 4 个 (2408/500/1701/4500) + 实测可用的社区端口 (8443/903, 2026-10-28 在 162.159.195.1 实证)
# 注意: 443 是 MASQUE 专用, WG 在 443 无应答, 不入池
WARP_PORTS=( 2408 500 1701 4500 8443 903 )
ENDPOINTS=()
for p in "${WARP_PORTS[@]}"; do
    for ip in "${WARP_IPS[@]}"; do
        ENDPOINTS+=( "$ip:$p" )
    done
done
ep_idx=0

# ---------- 1. 注册 (wgcf-account.toml 持久化, 二次启动跳过) ----------
cd /etc/wireguard
if [ ! -f wgcf-account.toml ]; then
    log "未注册, 执行 wgcf register ..."
    wgcf register --accept-tos && log "注册成功"
fi
if [ ! -f "$CONF" ]; then
    wgcf generate
    mv wgcf-profile.conf "$CONF"
    log "配置已生成: $CONF"
fi

# 容器 IPv6 被禁用时剔除 v6 配置
# 警告: wgcf 的 AllowedIPs = 0.0.0.0/0, ::/0 是一行写 v4+v6, 整行删除会把 v4
# 一起删光 -> allowed ips (none) -> 无路由无握手(transfer 恒 0/0), 隧道永远
# 建立失败。2026-10-28 US VPS 实测教训。正确做法: 整行替换为仅 v4。
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
    log "检测到 IPv6 已禁用, 剔除 v6 配置"
    # wgcf 的 AllowedIPs = 0.0.0.0/0, ::/0 是一行写 v4+v6，整行删会把 v4 一起删光
    # → allowed ips (none)、握手包根本不发（transfer 恒 0/0）。必须整行替换为仅 v4。
    sed -i -e '/^Address = .*:/d' -e 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0|' "$CONF"
fi

# 私有网段排除: 否则 0.0.0.0/0 接管后 docker 网桥/局域网回程也进隧道,
# 宿主/局域网设备无法访问 gost (官方客户端自带此排除, 内核 WG 要手动加)
# 注意: PostUp 必须在 [Interface] 段内 (MTU 行后), 放到 [Peer] 段 wg 不认
sed -i '/^PostUp/d; /^PreDown/d' "$CONF"
if ! grep -q "^PostUp" "$CONF"; then
    sed -i '/^PostUp/d; /^PreDown/d' "$CONF"
    sed -i '/^MTU/a PostUp = ip rule add to 10.0.0.0/8 table main pref 32700\
PostUp = ip rule add to 172.16.0.0/12 table main pref 32701\
PostUp = ip rule add to 192.168.0.0/16 table main pref 32702\
PostUp = ip rule add to 169.254.0.0/16 table main pref 32703\
PreDown = ip rule del to 10.0.0.0/8 table main pref 32700 2>/dev/null; ip rule del to 172.16.0.0/12 table main pref 32701 2>/dev/null; ip rule del to 192.168.0.0/16 table main pref 32702 2>/dev/null; ip rule del to 169.254.0.0/16 table main pref 32703 2>/dev/null' "$CONF"
    log "已注入私有网段排除规则 ([Interface] 段)"
fi
# ---------- 2. 可用性检查 ----------
check_ok() {
    local trace
    trace=$(curl -s --max-time 8 https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
    echo "$trace" | grep -q "warp=on" || return 1
    if [ -n "$EXPECT" ]; then
        echo "$trace" | grep -q "loc=${EXPECT}" || return 1
    fi
    return 0
}

# ---------- 3. 隧道管理 ----------
tunnel_up() {
    ip link show "$IFACE" >/dev/null 2>&1 && return 0
    wg-quick up "$IFACE" >/dev/null 2>&1
}

tunnel_down() {
    wg-quick down "$IFACE" >/dev/null 2>&1 || ip link del "$IFACE" 2>/dev/null || true
}

# 轮换端点 (作用于 conf, 保证 down/up 后仍生效)
rotate_endpoint() {
    ep_idx=$(( (ep_idx + 1) % ${#ENDPOINTS[@]} ))
    local ep="${ENDPOINTS[$ep_idx]}"
    log "轮换端点 -> $ep"
    sed -i "s|^Endpoint = .*|Endpoint = $ep|" "$CONF"
}

# 等待握手 (最多 ~90s)
wait_handshake() {
    local hs now i
    for i in $(seq 1 30); do
        hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
        now=$(date +%s)
        if [ -n "$hs" ] && [ "$hs" != "0" ] && [ $((now - hs)) -lt 60 ]; then
            return 0
        fi
        sleep 3
    done
    return 1
}

# 连通循环: 起隧道 -> 握手 -> 检查; 不通则轮换端点重来
establish() {
    local try
    for try in $(seq 1 12); do
        tunnel_up || { log "wg-quick up 失败"; tunnel_down; sleep 3; continue; }
        if wait_handshake && check_ok; then
            log "隧道可用 (第 $try 轮): $(curl -s --max-time 8 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E 'ip=|colo=' | tr '\n' ' ')"
            return 0
        fi
        log "第 $try 轮不可用 (握手或 warp 检查失败), 重试"
        tunnel_down
        rotate_endpoint
        sleep 3
    done
    return 1
}

# ---------- 4. 启动 gost (后台) ----------
gost -L ":${PROXY_PORT}" &
log "gost 已启动: socks5/http :${PROXY_PORT}"

# ---------- 5. 主流程 ----------
log "===== 首次建立隧道 ====="
if establish; then
    log "===== 进入守护循环 (每 ${CHECK_INTERVAL}s 检查) ====="
    fails=0
    while true; do
        sleep "$CHECK_INTERVAL"
        if check_ok; then
            fails=0
            continue
        fi
        fails=$((fails + 1))
        log "检查失败 ($fails/3)"
        if [ "$fails" -ge 3 ]; then
            log "连续 3 次失败, 重建隧道"
            tunnel_down
            rotate_endpoint
            establish || log "警告: 重建失败, 继续周期重试"
            fails=0
        fi
    done
else
    log "严重: 首次建立失败, 5 分钟后重试整个流程"
    while true; do
        sleep 300
        establish && { log "===== 建立成功, 进入守护循环 ====="; fails=0; \
            while true; do
                sleep "$CHECK_INTERVAL"
                if check_ok; then fails=0; continue; fi
                fails=$((fails + 1))
                log "检查失败 ($fails/3)"
                if [ "$fails" -ge 3 ]; then
                    log "连续 3 次失败, 重建隧道"
                    tunnel_down; rotate_endpoint
                    establish || log "警告: 重建失败, 继续周期重试"
                    fails=0
                fi
            done; }
    done
fi
