#!/bin/bash
# warp-sb-docker entrypoint (sing-box 用户态 WireGuard, 零特权)
# 流程: 注册(持久化) -> 生成 sing-box 配置 -> 握手+检查(9 端点轮换) -> 守护循环
set -u

DATA=/data
CONF=/etc/sing-box/config.json
PROXY_PORT="${PROXY_PORT:-1080}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
EXPECT="${EXPECT:-}"
WARP_SERVER="${WARP_SERVER:-engage.cloudflareclient.com}"
WARP_PORT="${WARP_PORT:-2408}"
WARP_API="${WARP_API:-https://api.cloudflareclient.com/v0a2025/reg}"

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

log() { echo "[entrypoint] $(date '+%H:%M:%S') $*"; }

CURL_AUTH=""
[ -n "$SOCK_USER" ] && [ -n "$SOCK_PWD" ] && CURL_AUTH="--proxy-user $SOCK_USER:$SOCK_PWD"

# ---------- 1. 注册 (持久化到 /data/account.json, 二次启动复用) ----------
mkdir -p "$DATA"
if [ ! -f "$DATA/account.json" ]; then
    log "未注册, 直调 WARP API 注册 ..."
    TOS="$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
    SECRET_KEY=$(openssl genpkey -algorithm X25519) || { log "openssl 失败"; exit 1; }
    PUB=$(printf '%s\n' "$SECRET_KEY" | openssl pkey -pubout -outform DER | tail -c 32 | base64 -w0)
    RESP=$(curl -fsSL --max-time 30 -X POST "$WARP_API" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg tos "$TOS" --arg key "$PUB" '{tos:$tos,key:$key,referrer:""}')") || {
        log "注册 API 请求失败"; exit 1; }
    PRIV=$(printf '%s\n' "$SECRET_KEY" | openssl pkey -outform DER | tail -c 32 | base64 -w0)
    jq -n --arg priv "$PRIV" --argjson resp "$RESP" '{private_key:$priv, response:$resp}' > "$DATA/account.json" \
        || { log "账号解析失败"; exit 1; }
    log "注册成功, 已持久化 $DATA/account.json"
fi

PRIV=$(jq -r '.private_key // empty' "$DATA/account.json")
RESP=$(jq '.response' "$DATA/account.json")
CLIENT_ID=$(jq -r '.config.client_id // empty' <<<"$RESP")
PEER_PUB=$(jq -r '.config.peers[0].public_key // empty' <<<"$RESP")
V4=$(jq -r '.config.interface.addresses.v4 // empty' <<<"$RESP")
V6=$(jq -r '.config.interface.addresses.v6 // empty' <<<"$RESP")
if [ -z "$CLIENT_ID" ] || [ -z "$PEER_PUB" ] || [ -z "$PRIV" ] || [ -z "$V4" ]; then
    log "账号数据不完整, 删除 $DATA/account.json 后重启可重新注册"; exit 1
fi
# client_id(base64) -> 3 字节 reserved 数组 (WARP 私有协议字段, sing-box 正确实现的关键)
RESERVED=$(printf '%s' "$CLIENT_ID" | base64 -d 2>/dev/null | od -An -v -t u1 | jq -s .)
log "账号已加载: v4=$V4 reserved=$RESERVED"

# ---------- 2. 配置生成 ----------
gen_config() {
    local ep="$1" host="${1%:*}" port="${1##*:}"
    jq -n \
        --arg host "$host" \
        --argjson port "$port" \
        --argjson net_port "$PROXY_PORT" \
        --arg user "$SOCK_USER" \
        --arg pwd "$SOCK_PWD" \
        --arg priv "$PRIV" \
        --arg peer "$PEER_PUB" \
        --arg v4 "$V4" \
        --arg v6 "$V6" \
        --argjson reserved "$RESERVED" \
    '{
      log: {level: "info", timestamp: true},
      dns: {
        servers: [
          {type: "https", tag: "dns-remote", server: "1.1.1.1", server_port: 443, path: "/dns-query", detour: "WARP"},
          {type: "local", tag: "dns-local"}
        ],
        rules: [{action: "evaluate", server: "dns-local"}],
        final: "dns-remote",
        strategy: "prefer_ipv4"
      },
      inbounds: [(
        {type: "mixed", tag: "mixed-in", listen: "::", listen_port: $net_port}
        + (if $user != "" and $pwd != "" then {users: [{username: $user, password: $pwd}]} else {} end)
      )],
      outbounds: [{tag: "direct", type: "direct"}],
      endpoints: [{
        type: "wireguard", tag: "WARP", mtu: 1408,
        address: [($v4 + "/32"), ($v6 + "/128")],
        private_key: $priv,
        peers: [{
          address: $host,
          port: $port,
          public_key: $peer,
          allowed_ips: ["0.0.0.0/0", "::/0"],
          persistent_keepalive_interval: 25,
          reserved: $reserved
        }]
      }],
      route: {
        rules: [
          {action: "sniff"},
          {protocol: "dns", action: "hijack-dns"},
          {ip_is_private: true, action: "route", outbound: "direct"},
          {ip_cidr: ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","0.0.0.0/8","127.0.0.0/8","224.0.0.0/4","240.0.0.0/4"],
           action: "route", outbound: "direct"}
        ],
        final: "WARP",
        auto_detect_interface: true,
        default_domain_resolver: {server: "dns-local"}
      }
    }' > "$CONF"
    sing-box check -c "$CONF" || return 1
    return 0
}

# ---------- 3. 检查 ----------
check_ok() {
    local trace
    trace=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:"$PROXY_PORT" $CURL_AUTH \
      https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
    echo "$trace" | grep -q "warp=on" || return 1
    [ -n "$EXPECT" ] && ! echo "$trace" | grep -q "loc=${EXPECT}" && return 1
    return 0
}

SB_PID=""
start_sb() {
    [ -n "$SB_PID" ] && kill "$SB_PID" 2>/dev/null
    sleep 1
    gen_config "$1" || { log "配置生成失败: $1"; return 1; }
    sing-box run -c "$CONF" > /var/log/singbox.log 2>&1 &
    SB_PID=$!
    log "sing-box 已启动 (pid=$SB_PID, 端点=$1)"
}

# ---------- 4. 建立: 端点轮换 ----------
establish() {
    local try
    for try in $(seq 1 12); do
        start_sb "${ENDPOINTS[$ep_idx]}" || { sleep 3; continue; }
        sleep 8
        if check_ok; then
            log "隧道可用 (第 $try 轮): $(curl -s --max-time 8 --socks5-hostname 127.0.0.1:$PROXY_PORT $CURL_AUTH https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E 'ip=|colo=' | tr '\n' ' ')"
            return 0
        fi
        log "第 $try 轮不可用, 轮换端点"
        kill "$SB_PID" 2>/dev/null
        ep_idx=$(( (ep_idx + 1) % ${#ENDPOINTS[@]} ))
        sleep 3
    done
    return 1
}

# ---------- 5. 主流程 ----------
log "===== sing-box 版启动 (零特权), 代理端口 $PROXY_PORT ====="
if establish; then
    log "===== 进入守护循环 (每 ${CHECK_INTERVAL}s 检查) ====="
    fails=0
    while true; do
        sleep "$CHECK_INTERVAL"
        if check_ok; then fails=0; continue; fi
        fails=$((fails + 1))
        log "检查失败 ($fails/3)"
        if [ "$fails" -ge 3 ]; then
            log "连续 3 次失败, 轮换端点重建"
            kill "$SB_PID" 2>/dev/null
            ep_idx=$(( (ep_idx + 1) % ${#ENDPOINTS[@]} ))
            establish || log "警告: 重建失败, 继续周期重试"
            fails=0
        fi
    done
else
    log "严重: 首次建立失败, 5 分钟后重试"
    while true; do
        sleep 300
        establish && break
    done
    log "===== 建立成功, 进入守护循环 ====="
    fails=0
    while true; do
        sleep "$CHECK_INTERVAL"
        if check_ok; then fails=0; continue; fi
        fails=$((fails + 1))
        log "检查失败 ($fails/3)"
        if [ "$fails" -ge 3 ]; then
            log "连续 3 次失败, 轮换端点重建"
            kill "$SB_PID" 2>/dev/null
            ep_idx=$(( (ep_idx + 1) % ${#ENDPOINTS[@]} ))
            establish || log "警告: 重建失败, 继续周期重试"
            fails=0
        fi
    done
fi
