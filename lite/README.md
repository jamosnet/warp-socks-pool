# lite — 内核 WireGuard 极简 WARP 代理（~127MB）

用 `wgcf` 注册 WARP 账号、**Linux 内核自带 WireGuard** 建隧道、`gost` 暴露
SOCKS5/HTTP 代理的极简容器。适合低配机器和大流量长跑场景。
一句话：加密的重活交给内核干，容器里只留一个 gost。

![架构图](../docs/images/arch-lite.svg)

## 特性

- 镜像 ~127MB：隧道由内核 `wireguard` 模块完成（内核 ≥ 5.6 自带），
  无用户态隧道程序，无需 `/dev/net/tun`
- 内核态加密：压测 CPU 占用约为 sing-box 版的 40%、官方客户端的 30%
- 48 端点轮换：8 IP × 6 端口（2408/500/1701/4500/8443/903），
  端口优先排序，自动对抗握手丢包
- 注册持久化：账号文件落卷，重启/重建不换身份
- 断线恢复，且以实测为准：每 15s 从容器内发一次真实 trace 请求体检（流量
  真实穿过隧道），连续 3 次失败才判定断线 → 换端点重建；重建过程边修边验，
  握手 + trace 都通过才算修好，不通就继续轮换。不是自己给自己看病——
  每次结论都来自真实的端到端探测
- `EXPECT` 出口地区校验（可选），不符视为故障触发轮换

## 限制

- 仅 WireGuard 协议（不支持 MASQUE）
- 必须 `privileged: true`（`wg-quick` 需写 `net.ipv4.conf.all.src_valid_mark`，
  该 sysctl 只认初始命名空间权限，`CAP_NET_ADMIN` 不够）
- 重建隧道期间有几秒到一两分钟的代理间隙
- 会改容器内路由表 / ip rule，不适合与其他全接管路由的容器共享 netns

## Step by Step

### 1. 构建镜像

```bash
git clone <本仓库> && cd warp-socks-pool/lite

# --build-arg HTTPS_PROXY 是【可选】的：仅构建镜像时用来从 GitHub 下载
# wgcf 和 gost 两个文件。能直连 GitHub 就直接 docker compose build，什么都不
# 用加。它只在构建期生效，容器运行期的流量与它毫无关系，不要误会成
# "所有流量都要走代理"。
docker compose build --build-arg HTTPS_PROXY=socks5h://192.168.8.124:10808
```

### 2. 启动

```bash
docker compose up -d
```

compose 默认映射宿主 1082 → 容器 1080，账号持久化在 `./data`。

### 3. 验证

```bash
curl --socks5-hostname 127.0.0.1:1082 https://cloudflare.com/cdn-cgi/trace
```

输出含 `warp=on` 即成功（`loc=` 为出口地区，`ip=` 为 WARP 出口 IP）。

### 4.（可选）docker run 部署

```bash
# 最简：全默认参数
docker run -itd --name warp1082 \
  --privileged \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -p 1082:1080 \
  -v /tmp/warp-wg-data:/etc/wireguard \
  warp-wg-lite:latest

# 自定义：每 10s 检查 + 出口必须为 US
docker run -itd --name warp-us \
  --privileged \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -p 1083:1080 \
  -e CHECK_INTERVAL=10 \
  -e EXPECT=US \
  -v /tmp/warp-us-data:/etc/wireguard \
  warp-wg-lite:latest
```

多实例规律：gost 恒定监听容器内 `PROXY_PORT`（默认 1080），换宿主端口改
`-p`，多实例用不同数据卷。

## 参数

### 运行时环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PROXY_PORT` | `1080` | gost 容器内监听端口（SOCKS5 + HTTP 同端口） |
| `CHECK_INTERVAL` | `15` | 守护循环检查间隔（秒） |
| `EXPECT` | 空 | 出口地区校验（如 `US`），不符视为故障触发轮换 |

### 构建期 build-arg

| 变量 | 默认 | 说明 |
|---|---|---|
| `WGCF_VERSION` | `2.3.1` | wgcf 版本 |
| `GOST_VERSION` | `2.12.0` | gost 版本（v2 最新为 2.12.0） |
| `HTTPS_PROXY` / `HTTP_PROXY` | 空 | 可选。仅构建镜像时下载 wgcf/gost 用，不填则直连下载；不影响运行期流量 |

### 持久化卷

| 路径 | 内容 |
|---|---|
| `/etc/wireguard/wgcf-account.toml` | WARP 账号（删除即重新注册） |
| `/etc/wireguard/wgcf.conf` | WG 配置（含注入的端点与私有网段排除规则） |

## 运维

```bash
docker logs -f warp1082 | grep entrypoint        # 建立/轮换过程
docker exec warp1082 wg show wgcf                # 握手时间与流量
docker exec warp1082 wg-quick down wgcf && docker restart warp1082   # 手动重建
docker rm -f warp1082 && rm -rf ./data && docker compose up -d       # 重新注册
# 改脚本后必须 rebuild（脚本烤在镜像里），build 完建议比对容器内文件 md5
docker compose build && docker compose up -d --force-recreate
```

## 压测数据

见根目录 [benchmark](../README.md#压测对比)：CPU 7.4%、内存 24.2 MiB，
为全部方案中资源效率最高者（sing-box 版的 40%，官方客户端的 30%）。

## FAQ

- **断线恢复是"自己给自己看病"吗？** 不是。它的每次判断都来自一次真实请求：
  每 15s 从容器里 curl 一次 Cloudflare trace（流量真实穿过隧道），连续 3 次
  失败才动手重建；重建时要握手 + trace 都通过才算修好，否则继续换端点，
  直到实测通过为止。
- **宿主 localhost 通、局域网 IP 不通？** 旧数据卷缺少私有网段排除规则。
  确认 `wgcf.conf` 的 `[Interface]` 段内有 4 条 `PostUp = ip rule add to ...`。
- **首次建立一直在轮换？** 正常：大陆网络对 WG 新会话握手有随机丢弃，
  48 端点池会自动找到可用组合（实测 1-4 轮内成功）。
- **`sysctl: permission denied`？** 没用 `--privileged`。
- **443 端口为什么不在池里？** WG 在 UDP 443 无应答（实测），443 是
  MASQUE 专用端口。
