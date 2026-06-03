# Session Sharing Relay (Go)

这是 `../relay/`（Python `server.py`，纯 stdlib）的 **一比一 Go 复刻**，
使用 Go + [`gorilla/websocket`](https://github.com/gorilla/websocket)。两者
对外行为完全一致：相同的 REST / WebSocket 协议、相同的 CLI flag 与环境变量、
相同的健康检查端点。唯一的区别是启动方式从 `python3 server.py ...` 变成直接
运行编译产物 `./ghostty-relay ...`。

权威规格见 [`../relay/PORT-SPEC.md`](../relay/PORT-SPEC.md)（移植规格，逐项
对照 Python 源行为）。协议契约（含文件上传）见
[`/docs/plan/web-upload.md`](/docs/plan/web-upload.md)。

## Build

```bash
# 在 contrib/session-sharing/relay-go/ 下，产物名固定为 ghostty-relay：
go -C contrib/session-sharing/relay-go build -o ghostty-relay .
```

需要 Go 1.26+（见 `go.mod`）。这是一个自包含的静态二进制，目标机器上无需安装
任何运行时（不需要 python3）。

**交叉编译（部署到 Linux 服务器时几乎必做）**：本机通常是 macOS/arm64，而生产
机一般是 linux/amd64。二进制架构不匹配会直接 `Exec format error` 起不来：

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    go -C contrib/session-sharing/relay-go build -o ghostty-relay .
```

`./deploy.sh` 默认会替你做这一步（target 可用 `DEPLOY_GOOS` / `DEPLOY_GOARCH`
覆盖）。

## Run

直接运行二进制，flag 与 Python 版同名同义：

```bash
# 本地开发，默认绑 127.0.0.1：
./ghostty-relay --port 18080
```

浏览器客户端需要的 WASM 终端解析器照旧用 zig 构建：

```bash
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

若 `zig-out/bin/ghostty-vt.wasm` 存在，relay 会在 `/ghostty-vt.wasm` 提供它。

让局域网内其他机器可访问时，绑到本机 LAN 地址。私有网段（10/8、172.16/12、
192.168/16、169.254/16、IPv6 fe80::/10、fc00::/7）**不需要**
`--allow-public-bind`：

```bash
./ghostty-relay --host 192.168.1.5 --port 18080
```

只有要监听公网可路由地址（如 `0.0.0.0`）时才必须显式 opt-in：

```bash
./ghostty-relay --host 0.0.0.0 --port 18080 --allow-public-bind
```

> 生产环境的正确做法是前置 nginx / Caddy 终止 TLS，relay 留在
> `127.0.0.1`，**不要**用 `--allow-public-bind` 直接对公网。

## 配置（Flag / 环境变量）

所有 CLI flag 与环境变量、默认值都**与 Python 版完全一致**，权威来源是本目录
的 [`config.go`](config.go)（`buildConfig`）。环境变量清单与 Python 版
[`../relay/README.md`](../relay/README.md#environment-variables) 同表，这里不
再重抄；上传相关与运维细节见 [`deploy/ghostty-relay.env.example`](deploy/ghostty-relay.env.example)。

要点（与 Python 版相同）：

- 用户 token allowlist：`GHOSTTY_RELAY_USER_TOKENS` 或
  `GHOSTTY_RELAY_USER_TOKENS_FILE`。两者都不配时保持兼容行为，接受任意非空
  user token —— 生产务必配置 allowlist。
- 浏览器/客户端用长效 user token 走 `/ws/client` 默认禁用，推荐走签发的
  `client_token`；如确需放开：`GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS=1`。
- 反代后开 `GHOSTTY_RELAY_TRUSTED_PROXIES=127.0.0.1`，否则 per-IP 限流会把整个
  反代后的客户端收敛成一个桶。

## 健康检查

生产建议跑独立 admin listener，让运维端点不暴露在公网攻击面：

```bash
GHOSTTY_RELAY_ADMIN_HOST=127.0.0.1
GHOSTTY_RELAY_ADMIN_PORT=18081
```

admin 端口非 0 时，公开 listener 对 `/healthz`、`/readyz`、`/metrics` 返回
`404`，只有 admin listener 提供：

```bash
curl http://127.0.0.1:18081/healthz   # {"ok": true}
curl http://127.0.0.1:18081/readyz    # 进程就绪状态 + 当前 session 数
curl http://127.0.0.1:18081/metrics   # Prometheus 风格 plaintext 指标
```

`GHOSTTY_RELAY_ADMIN_PORT=0`（默认）时这些端点留在主 listener，便于开发；公开
部署应始终用专用 admin listener，并在反代再 block 一道（示例 nginx 已做）。

## 部署

Linux 服务器部署流程见 [DEPLOY.md](DEPLOY.md)，包括交叉编译、systemd、反代
（含 nginx body size 坑）、PrivateTmp 上传暂存、升级顺序、TLS 布局选择
（letsencrypt vs 自签 + 信任锚）。一键部署脚本：

```bash
cp deploy.env.example deploy.env   # 填 DEPLOY_HOST / DEPLOY_PATH
$EDITOR deploy.env
./deploy.sh                        # 交叉编译 + rsync 二进制 + systemctl restart
```

> ⚠️ `deploy.sh` **不会改 systemd unit 的 `ExecStart`**。首次部署、或从已在跑的
> Python 版切换时，需手动把 unit 的 `ExecStart` 指向 Go 二进制（并备份以便回滚）——
> 见 [DEPLOY.md](DEPLOY.md) 「从 Python 版切换 / 回滚」。日常只是更新 Go 二进制时，
> `deploy.sh` 一键即可。

## 与 Python 版的关系

- 行为一比一对齐，权威规格 [`../relay/PORT-SPEC.md`](../relay/PORT-SPEC.md)。
- 同样的 REST（`/api/register`、`/api/sessions`、`/api/upload/*`）、WebSocket
  （`/ws/agent`、`/ws/client`）、静态资源（含 `/ghostty-vt.wasm`）、健康检查
  端点。
- 限流、body / frame size 上限、max sessions、max clients/session、token 过期
  检查、慢消费者保护等约束行为一致。
- 协议帧、上传契约见 Python 版 README 的 REST / WebSocket / Frames 章节，此处
  不重复。
