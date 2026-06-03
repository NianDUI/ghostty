# Linux Deployment Guide (Go relay)

本文是 Go 版 relay（`relay-go/`，一比一复刻 Python `../relay/`）的生产部署指南，
以 Python 版 [`../relay/DEPLOY.md`](../relay/DEPLOY.md) 为蓝本。两者对外行为、
flag / 环境变量、健康检查端点完全一致，**唯一区别是**：Python 版跑
`python3 server.py`，Go 版跑一个编译好的自包含二进制 `ghostty-relay`（目标机
上无需任何运行时）。权威移植规格见 [`../relay/PORT-SPEC.md`](../relay/PORT-SPEC.md)。

## Command Overview

- `go -C contrib/session-sharing/relay-go build -o ghostty-relay .`
  - 编译出 `ghostty-relay` 二进制（本机架构）
- `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go -C contrib/session-sharing/relay-go build -o ghostty-relay .`
  - **交叉编译** linux/amd64 二进制，部署到典型 Linux 服务器前几乎必做
- `./ghostty-relay`
  - 以 env-based 配置启动 relay（直接跑二进制，无需 python3）
- `./ghostty-relay --host 0.0.0.0 --allow-public-bind`
  - 刻意绑非 loopback 接口，供 LAN / 公网访问
- `systemctl enable --now ghostty-relay`
  - 把 relay 装成 Linux 服务并启动
- `journalctl -u ghostty-relay -f`
  - 跟踪运行日志

## 交叉编译（Go 版相对 Python 版最容易踩的坑）

Python 版 rsync 的是一份 `.py` 文本，目标机的 CPU 架构无所谓。Go 版 ship 的是
**编译后的二进制**，必须与生产机 OS/arch 匹配，否则连 exec 都过不了
（`Exec format error`，systemd 表现为 `status=203/EXEC`）。

开发机通常是 macos/arm64，生产机一般是 linux/amd64，所以默认要交叉编译：

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    go -C contrib/session-sharing/relay-go build -o ghostty-relay .
```

ARM 服务器用 `GOARCH=arm64`。`./deploy.sh` 默认就替你做这步（target 可用
`DEPLOY_GOOS` / `DEPLOY_GOARCH` 覆盖）。只有当你已经为正确 target 产出了二进制
时，才用 `./deploy.sh --no-build` 跳过构建直接 rsync——发错架构的二进制会让
服务起不来且报错很迷惑。

## Development Startup

relay 主机上本地开发：

```bash
cd /path/to/ghostty/contrib/session-sharing/relay-go
go build -o ghostty-relay .
./ghostty-relay --port 18080
```

让 relay 对局域网内其他机器可见时，绑到本机 LAN 地址。私有网段（10/8、
172.16/12、192.168/16、169.254/16、IPv6 fe80::/10、fc00::/7）**不需要**
`--allow-public-bind`，因为它们在公网不可路由：

```bash
# 把 192.168.1.5 换成你机器的 LAN IP。
./ghostty-relay --host 192.168.1.5 --port 18080
```

LAN 客户端即可把桌面 / 浏览器 app 指向 `http://192.168.1.5:18080`（WebSocket
端点对应 `ws://`）。macOS app 已信任 RFC1918 / link-local / loopback 上的
http/ws，无需客户端额外 flag。

要监听所有接口（含公网，如果主机有的话），必须显式 opt-in：

```bash
./ghostty-relay --host 0.0.0.0 --port 18080 --allow-public-bind
```

## Topology

推荐布局：

1. `ghostty-relay` 二进制绑 `127.0.0.1:18080`
2. 前置 Nginx 或 Caddy
3. TLS 在反代终止
4. `systemd` 管理 relay 进程

## Production Startup

推荐生产启动顺序：

1. 把 env example 拷到 `/etc/ghostty-relay.env`
2. 填好 user token allowlist
3. relay 保持绑 `127.0.0.1:18080`
4. 前置 Nginx 或 Caddy 提供 `https://` 与 `wss://`
5. 启动 `systemd` unit

直接启动示例：

```bash
cd /opt/ghostty-session-sharing/contrib/session-sharing/relay-go
export GHOSTTY_RELAY_HOST=127.0.0.1
export GHOSTTY_RELAY_PORT=18080
export GHOSTTY_RELAY_USER_TOKENS_FILE=/etc/ghostty-relay.tokens
export GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
export GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
./ghostty-relay
```

`systemd` 托管启动：

```bash
sudo cp contrib/session-sharing/relay-go/deploy/ghostty-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ghostty-relay
```

## Environment

拷贝示例文件：

```bash
cp contrib/session-sharing/relay-go/deploy/ghostty-relay.env.example /etc/ghostty-relay.env
```

按需调整。环境变量名、默认值与 Python 版完全一致，权威来源是
[`config.go`](config.go) 的 `buildConfig`。

如果你确实想绑公网 / LAN 接口而非 localhost，额外设：

```bash
GHOSTTY_RELAY_ALLOW_PUBLIC_BIND=1
```

通过下列任一方式配置合法 user token：

```bash
GHOSTTY_RELAY_USER_TOKENS=token-a,token-b
```

或：

```bash
GHOSTTY_RELAY_USER_TOKENS_FILE=/etc/ghostty-relay.tokens
```

两者都不配时，relay 保持兼容行为，接受任意非空 user token。真实服务器应配置
allowlist。

浏览器/客户端在 `/ws/client` 上使用长效 user token 默认禁用，推荐用签发的
`client_token`。只有确需时才放开：

```bash
GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS=1
```

基础 per-IP 限流：

```bash
GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
```

当前作用于：

- `/api/register`
- `/api/sessions`
- `/ws/agent`
- `/ws/client`

### Reverse-Proxy Client IP Trust

relay 前置 Nginx / Caddy 后，relay 看到的每个请求都来自反代地址。不额外配置的
话，per-IP 限流会把整个真实客户端 fleet 当成一个桶（keyed on 反代 IP）——生产
里等于关掉了限流。

把 `GHOSTTY_RELAY_TRUSTED_PROXIES` 设成反代地址（或覆盖它的 CIDR）。只有 socket
peer 在此列表里的请求才信任其 `X-Forwarded-For`；其余继续用 socket peer IP，
所以不可信来源无法伪造 IP。

```bash
# Loopback 上的 Nginx/Caddy：
GHOSTTY_RELAY_TRUSTED_PROXIES=127.0.0.1

# 多个可信反代 / CIDR 用逗号分隔：
# GHOSTTY_RELAY_TRUSTED_PROXIES=10.0.0.0/24,2001:db8::/32
```

`nginx.conf.example` 和 `Caddyfile.example` 都已转发 `X-Forwarded-For`。没设
`GHOSTTY_RELAY_TRUSTED_PROXIES` 时该 header 被忽略，限流只看到反代 IP。

## systemd

安装 unit：

```bash
sudo cp contrib/session-sharing/relay-go/deploy/ghostty-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ghostty-relay
```

unit 的 `ExecStart` 指向部署后的 `ghostty-relay` 二进制（不是 `python3
server.py`），其余（`EnvironmentFile`、`PrivateTmp=true`、`Restart=on-failure`
等）与 Python 版对齐。

查看状态：

```bash
systemctl status ghostty-relay
journalctl -u ghostty-relay -f
```

> `/etc/ghostty-relay.env` **不会**被 deploy.sh 覆盖。`env.example` 改了要 ssh
> 上去 `sudoedit` 手动合并；代码默认值兜底，忘合并不会崩。

## 从 Python 版切换 / 回滚

如果生产机已经在跑 Python 版（unit 的 `ExecStart` 指向 `python3 server.py`），
注意 **`deploy.sh` 只 rsync 二进制 + `systemctl restart`，不会改 unit 的
`ExecStart`**——光跑 `deploy.sh`，restart 后起来的还是 python。完整切换分两步：

```bash
# 1. 先传二进制（Python 仍在跑，零影响）
./deploy.sh --skip-restart

# 2. 在服务器上：备份旧 unit → 改 ExecStart 指向 Go 二进制 → reload + restart
ssh root@<host> '
  U=/etc/systemd/system/ghostty-relay.service
  cp -n "$U" "$U.bak-python"                      # 备份，回滚要用
  sed -i "s|^ExecStart=.*|ExecStart=/opt/ghostty-session-sharing/contrib/session-sharing/relay-go/ghostty-relay|" "$U"
  systemctl daemon-reload
  systemctl restart ghostty-relay
  systemctl is-active ghostty-relay
  curl -s http://127.0.0.1:18081/readyz'
```

`/etc/ghostty-relay.env` 不用动——Go 版复用同一份（flag/env 名与 Python 完全
一致）。restart 会清空 in-memory session，但 agent 走 4408 / 网络错误 reconnect
自愈，几秒内全部回流（实测 3 个 session 秒级回流）。只改 `ExecStart` 一行、其余
（`User` / `EnvironmentFile` / `ProtectSystem` / `PrivateTmp`）保持原样，最小改动
最兼容。

**回滚到 Python**（出问题时把 `ExecStart` 改回去即可）：

```bash
ssh root@<host> '
  U=/etc/systemd/system/ghostty-relay.service
  cp "$U.bak-python" "$U"
  systemctl daemon-reload && systemctl restart ghostty-relay
  curl -s http://127.0.0.1:18081/readyz'
```

## Health Checks

生产环境跑专用 admin listener，让运维端点不在公开攻击面：

```bash
GHOSTTY_RELAY_ADMIN_HOST=127.0.0.1
GHOSTTY_RELAY_ADMIN_PORT=18081
```

admin 端口非 0 时，公开 listener 对 `/healthz`、`/readyz`、`/metrics` 返回
`404`，只有 admin listener 提供它们。

本地检查（admin listener）：

```bash
curl http://127.0.0.1:18081/healthz
curl http://127.0.0.1:18081/readyz
curl http://127.0.0.1:18081/metrics
```

部署完远程健康检查走 admin loopback：

```bash
ssh root@<host> 'curl -s http://127.0.0.1:18081/{readyz,metrics}'
```

预期：

- `/healthz` 返回 `{ "ok": true }`
- `/readyz` 返回进程就绪状态与当前 session 数
- `/metrics` 返回 Prometheus 风格 plaintext 指标

为向后兼容，把 `GHOSTTY_RELAY_ADMIN_PORT=0` 会把 admin 端点留在主 listener——
开发方便，但公开部署应始终用专用 admin listener，并在反代再 block 一道
`/healthz`、`/readyz`、`/metrics`（示例 Nginx 已做）。

## Long-Lived WebSocket Lifecycle

relay 在三类生产级场景关闭长连接。所有阈值可配，下面是默认值：

```bash
# 连接中途 token 过期。relay 每 N 秒重查 session.expires_at；过期则用 WS code
# 4401 关闭，客户端据此刷新并重连。
GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS=30

# 心跳。服务端每隔 interval 发 ping；timeout 内没收到 pong 就用 WS code 4408
# 关闭。捕获静默 NAT 断连与 idle 中间盒。
GHOSTTY_RELAY_PING_INTERVAL_SECONDS=30
GHOSTTY_RELAY_PING_TIMEOUT_SECONDS=60

# 慢消费者保护。每个 client 有按连接的发送缓冲字节上限。超限即丢弃该 client
# （close code 4408 "slow_consumer"），避免它拖垮对其他 client 的 fan-out。由
# `ghostty_relay_slow_consumer_drop_total` 指标跟踪。
GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES=1048576
```

## File Upload 暂存与 PrivateTmp

文件上传（web client → relay → Mac agent）相关项见
[`deploy/ghostty-relay.env.example`](deploy/ghostty-relay.env.example) 与
[`/docs/plan/web-upload.md`](/docs/plan/web-upload.md)。

`GHOSTTY_RELAY_UPLOAD_DIR=/tmp/ghostty-uploads` 在 systemd `PrivateTmp=true`
下会被隔离到 `/tmp/systemd-private-<uuid>/...`，service 重启即清——这正是瞬态
暂存想要的。**不要**改成持久卷（除非系统 `/tmp` 是 RAM-backed 且你预期超大
上传）。

## Reverse Proxy

用提供的示例之一：

- `deploy/nginx.conf.example`
- `deploy/Caddyfile.example`

上游仍是 `127.0.0.1:18080`，与 Python 版反代配置一致。反代必须转发：

- `/api/register`
- `/api/sessions`
- `/api/upload/*`
- `/ws/agent`
- `/ws/client`
- 若由 relay 提供则还有静态浏览器资源

### Nginx body size 必坑

Nginx 默认 `client_max_body_size` 是 1 MiB，会卡住上传的 PUT（single-shot）与
PATCH（per-chunk）请求体。`/api/upload/` location 必须把
`client_max_body_size` 调到 ≥ 上传上限（`GHOSTTY_RELAY_UPLOAD_MAX_BYTES`），
并把 `proxy_read_timeout` / `proxy_send_timeout` 调到 ≥ 600s，否则高延迟链路
上的大 chunk 会被 Nginx 中途掐断。模板 `deploy/nginx.conf.example` 已写好。
Caddy 不限 body size，无需配。

### TLS: letsencrypt vs self-signed + trust anchor pin

`nginx.conf.example` 默认 ship **布局 (B) 自签 + 信任锚 pin**，因为这是上游
maintainer 的部署方式。部署前在两种布局里选一个：

- **布局 (A) — letsencrypt。** 主机有公网域名且 80 端口对公网可达（HTTP-01
  挑战能成功）时用。把 `server_name` 设成真实域名，`ssl_certificate*` 指向 live
  cert。典型云部署最常用。
- **布局 (B) — 自签 + 信任锚 pin。** HTTP-01 不可达时用。Android APK 已通过
  Network Security Config pin 了上游 maintainer 的自签 CA；桌面浏览器可把该 CA
  加为信任锚以跳过 "unknown issuer" 警告。证书有效期 10 年，SAN 必须同时列出
  域名和服务器 IP。完整决策依据、openssl 生成配方、各 OS 信任锚安装命令见
  `contrib/session-sharing/ghostty-web-client/CLAUDE.md`（"TLS" 节）。

默认 `nginx.conf.example` 监听 **28443**（与上游部署一致，用非标准 HTTPS 端口
绕过上游 SNI 检查器）。若你掌控网络且偏好 443，改掉两行 `listen`。

## 升级顺序：**agent → relay → web**

升级整套时按这个顺序，避免新旧协议帧错位：

- 老 agent 不识别 `upload_ready` 控制帧 → fall through 到 `forwardToTerminal`
  （裸 JSON 漏进 PTY，难看）。**先升级 agent。**
- 老 relay 收新 PATCH → 405，web client fall back 到 PUT 单 shot。
- 老 web client 不知道 `/api/upload/*` → 终端流照常工作，没上传按钮即可。

relay 自身 restart < 1 秒；已有 session 走 4408 / 网络错误 reconnect 自愈，
几秒内全部回流。

## Notes

- 能避免就别把 relay 进程直接暴露在公网。正确做法是前置 nginx/Caddy + relay 留
  `127.0.0.1`；**反模式**：用 `--allow-public-bind` 让 relay 直接绑 `0.0.0.0`。
- 当前生产化工作尚未在代码里强制 HTTPS/WSS；在反代层强制。
- Token 按设计不记日志；本地任何改动都请保持这一点。
- Metrics 命名遵循 `ghostty_relay_<category>_<verb>_total`，新加 endpoint 跟这个
  pattern。
- `deploy.env` 是 gitignored，禁止 commit；批量 stage 时用 `git add <具体文件>`，
  别 `git add -A` / `git add .`，以免误带临时调试 / token。同理别提交编译出的
  host-arch `ghostty-relay` 二进制（`.gitignore` 已忽略）。
