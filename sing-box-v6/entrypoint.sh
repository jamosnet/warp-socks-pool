#!/bin/bash
# warp-sb-docker entrypoint (sing-box 用户态 WireGuard, 零特权)
# 流程: 注册(持久化) -> 生成 sing-box 配置 -> 握手+检查(48 端点轮换) -> 守护循环
# v2: 出口地址族可选。EGRESS=v6 时走 WARP 给本机设备分配的 /128 IPv6 出网,
#     不再与成千上万的 WARP 用户挤同一个共享 IPv4 出口 NAT。
set -u

DATA=/data
CONF=/etc/sing-box/config.json
PROXY_PORT="${PROXY_PORT:-1080}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
EXPECT="${EXPECT:-}"
WARP_SERVER="${WARP_SERVER:-engage.cloudflareclient.com}"
WARP_PORT="${WARP_PORT:-2408}"
WARP_API="${WARP_API:-https://api.cloudflareclient.com/v0a2025/reg}"

# ---- 出口地址族 ----
# v6     : 优先 IPv6 出口(默认)。拿不到 v6 会自动退回 v4 继续服务, 只是配额又变回共享的
# v6only : 强制 IPv6 出口。拿不到就宁可不可用, 绝不偷偷走 v4(排查/压测用)
# v4     : 强制 IPv4 出口(原始行为)
EGRESS="${EGRESS:-v6}"
# 目标域名解析位置: local=容器 DNS(默认, 最省事)  remote=WARP 隧道内 DoH(主机 DNS 不返回 AAAA 时用)
DNS_MODE="${DNS_MODE:-local}"
# v6 模式下先用多少个端点去找 IPv6 出口, 用完仍没有就软降级为 v4
V6_TRIES="${V6_TRIES:-3}"
# 已确认拿不到 IPv6(软降级后置 1), 之后不再折腾
ACCEPT_V4=0

set_egress() {
    case "$1" in
        v6|6|ipv6) EGRESS="v6"; IP_STRATEGY="prefer_ipv6" ;;
        v6only)    EGRESS="v6only"; IP_STRATEGY="prefer_ipv6" ;;
        v4|4|ipv4) EGRESS="v4"; IP_STRATEGY="prefer_ipv4" ;;
        *) echo "[entrypoint] EGRESS 只支持 v6 / v6only / v4, 收到: $1"; exit 1 ;;
    esac
    case "$DNS_MODE" in
        local)  DOMAIN_RESOLVER="dns-local" ;;
        remote) DOMAIN_RESOLVER="dns-remote" ;;
        *) echo "[entrypoint] DNS_MODE 只支持 local / remote, 收到: $DNS_MODE"; exit 1 ;;
    esac
}
set_egress "$EGRESS"

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
if [ "$EGRESS" != "v4" ] && [ -z "$V6" ]; then
    if [ "$EGRESS" = "v6only" ]; then
        log "严重: 该账号没有分配 IPv6 地址, v6only 模式无法满足。删掉 $DATA/account.json 重新注册"
        exit 1
    fi
    log "警告: 该账号没有分配 IPv6 地址, 本次直接使用 IPv4 出口(容器照常可用)"
    EGRESS="v4"; IP_STRATEGY="prefer_ipv4"; ACCEPT_V4=1
fi
# client_id(base64) -> 3 字节 reserved 数组 (WARP 私有协议字段, sing-box 正确实现的关键)
RESERVED=$(printf '%s' "$CLIENT_ID" | base64 -d 2>/dev/null | od -An -v -t u1 | jq -s .)
log "账号已加载: v4=$V4 v6=$V6 reserved=$RESERVED"

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
        --arg strategy "$IP_STRATEGY" \
        --arg resolver "$DOMAIN_RESOLVER" \
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
        strategy: $strategy
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
          {ip_cidr: ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","0.0.0.0/8","127.0.0.0/8","224.0.0.0/4","240.0.0.0/4",
                     "::1/128","fe80::/10","fc00::/7"],
           action: "route", outbound: "direct"}
        ],
        final: "WARP",
        auto_detect_interface: true,
        default_domain_resolver: {server: $resolver}
      }
    }' > "$CONF"
    sing-box check -c "$CONF" || return 1
    return 0
}

# ---------- 3. 检查 ----------
# trace 里的 ip= 就是 Cloudflare 看到的源地址, 也就是真实出网地址, 无需再打第三方回显
check_ok() {
    local trace ip
    trace=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:"$PROXY_PORT" $CURL_AUTH \
      https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
    echo "$trace" | grep -q "warp=on" || return 1
    [ -n "$EXPECT" ] && ! echo "$trace" | grep -q "loc=${EXPECT}" && return 1

    ip=$(echo "$trace" | grep -E '^ip=' | cut -d= -f2)
    if [ -z "$ip" ]; then
        log "trace 未返回 ip= 字段"
        return 1
    fi
    EGRESS_IP="$ip"
    case "$EGRESS" in
        v4)
            # 强制 v4 模式: 只要能出网就收, 族不再挑剔
            return 0
            ;;
        v6only)
            echo "$ip" | grep -q ':' || { log "出口是 IPv4 ($ip), v6only 模式拒绝"; return 1; }
            return 0
            ;;
        *)
            # v6 模式: 先全力找 v6; 确认找不到后(ACCEPT_V4=1)退回 v4 继续服务, 不影响可用性
            if echo "$ip" | grep -q ':'; then
                return 0
            fi
            if [ "$ACCEPT_V4" = "1" ]; then
                [ "${WARNED_V4:-0}" = "1" ] || {
                    log "警告: 出口为 IPv4 ($ip)。容器照常可用, 但配额又回到共享 NAT"
                    WARNED_V4=1
                }
                return 0
            fi
            log "出口仍是 IPv4 ($ip), 继续寻找 IPv6 出口"
            return 1
            ;;
    esac
}

SB_PID=""
start_sb() {
    [ -n "$SB_PID" ] && kill "$SB_PID" 2>/dev/null
    sleep 1
    gen_config "$1" || { log "配置生成失败: $1"; return 1; }
    sing-box run -c "$CONF" > /var/log/singbox.log 2>&1 &
    SB_PID=$!
    log "sing-box 已启动 (pid=$SB_PID, 端点=$1, 出口=$EGRESS, DNS=$DNS_MODE)"
}

# ---------- 4. 建立: 端点轮换 ----------
establish() {
    local pass try limit
    for pass in 1 2; do
        # v6 模式先只用前 V6_TRIES 个端点找 v6, 避免长时间无服务
        limit=12
        [ "$EGRESS" = "v6" ] && [ "$ACCEPT_V4" = "0" ] && limit="$V6_TRIES"
        for try in $(seq 1 "$limit"); do
            start_sb "${ENDPOINTS[$ep_idx]}" || { sleep 3; continue; }
            sleep 8
            if check_ok; then
                log "隧道可用 (第 $try 轮): 端点=${ENDPOINTS[$ep_idx]} 出口IP=${EGRESS_IP} ($EGRESS)"
                return 0
            fi
            log "第 $try 轮不可用, 轮换端点"
            kill "$SB_PID" 2>/dev/null
            ep_idx=$(( (ep_idx + 1) % ${#ENDPOINTS[@]} ))
            sleep 3
        done
        # 软降级: 试过 V6_TRIES 个端点仍只有 v4, 就接受 v4 把服务先跑起来
        if [ "$EGRESS" = "v6" ] && [ "$ACCEPT_V4" = "0" ]; then
            ACCEPT_V4=1
            log "已试 $V6_TRIES 个端点仍无 IPv6 出口, 软降级为 IPv4 继续服务(要严格拒绝 v4 请用 EGRESS=v6only)"
            continue
        fi
        return 1
    done
    return 1
}

guard_loop() {
    local fails=0
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
}

# ---------- 5. 主流程 ----------
log "===== sing-box 版启动 (零特权), 代理端口 $PROXY_PORT, 出口模式=$EGRESS, DNS=$DNS_MODE ====="
if establish; then
    log "===== 进入守护循环 (每 ${CHECK_INTERVAL}s 检查, 出口=$EGRESS_IP) ====="
    guard_loop
else
    log "严重: 隧道建立失败(只有 EGRESS=v6only 才会因拿不到 v6 失败), 5 分钟后重试"
    while true; do
        sleep 300
        establish && break
    done
    log "===== 建立成功, 进入守护循环 ====="
    guard_loop
fi
