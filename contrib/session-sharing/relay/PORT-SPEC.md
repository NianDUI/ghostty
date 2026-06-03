# Relay 功能逻辑规格（Python → Go 一比一复刻基准）

本文档逐项拆解 `server.py`（2994 行，纯标准库 asyncio）的全部行为，作为 Go
重写的**唯一权威规格**。目标是行为等价：相同输入 → 相同 HTTP 状态码 / 响应
体 / WebSocket 帧 / 关闭码 / 指标计数 / 日志事件。每一节都标注了不可省略的边
界条件与并发约束。

> 约定：下文「锁」指全局 `state.lock`（asyncio.Lock，单一互斥）。Go 端用一把
> `sync.Mutex` 即可等价，但**绝不能在持锁期间做 socket IO**——Python 代码刻意
> 把所有 `ws_send_*` / `send_response` 放在锁外，这是正确性约束不是风格选择。

---

## 1. 总体架构

- 单进程，事件驱动。Python 用 asyncio 单线程 event loop；Go 用 goroutine +
  一把全局锁即可，语义等价（Python 的「持锁不 await IO」对应 Go 的「持锁不做
  阻塞 IO」）。
- 手写 HTTP/1.1 + 手写 WebSocket（RFC6455 子集），**不依赖任何框架**。Go 端
  建议用 `net/http` + `nhooyr.io/websocket`（或 `gorilla/websocket`），但必须
  复刻下文的帧/握手/关闭码行为，不能直接用库默认。
- 两个监听器：
  - **public listener**：`config.host:config.port`，承载全部业务路由。
  - **admin listener**（可选，`admin_port > 0` 才启）：`admin_host:admin_port`，
    **只**服务 `/healthz` `/readyz` `/metrics`，其它一律 404。
- 后台协程：`cleanup_loop`（每 5s 跑一次 GC）。
- 信号：`SIGINT`/`SIGTERM` → 置 `shutting_down=True` → 优雅关闭两个 listener。

---

## 2. 配置（CLI flag + 环境变量 + 默认值）

每个配置项都是「CLI flag 默认值 = 对应 env 的值，env 缺省再用硬编码默认」。
CLI flag 名是 env 去掉 `GHOSTTY_RELAY_` 前缀、小写、下划线转连字符。

| 字段 | CLI flag | env | 类型 | 默认值 |
|---|---|---|---|---|
| host | `--host` | `GHOSTTY_RELAY_HOST` | str | `127.0.0.1` |
| port | `--port` | `GHOSTTY_RELAY_PORT` | int | `18080` |
| offline_ttl | `--offline-ttl` | `GHOSTTY_RELAY_OFFLINE_TTL` | float秒 | `300.0` |
| token_ttl | `--token-ttl` | `GHOSTTY_RELAY_TOKEN_TTL` | float秒 | `300.0` |
| max_body_bytes | `--max-body-bytes` | `GHOSTTY_RELAY_MAX_BODY_BYTES` | int | `64*1024` |
| max_sessions | `--max-sessions` | `GHOSTTY_RELAY_MAX_SESSIONS` | int | `4096` |
| max_clients_per_session | `--max-clients-per-session` | `GHOSTTY_RELAY_MAX_CLIENTS_PER_SESSION` | int | `8` |
| max_frame_bytes | `--max-frame-bytes` | `GHOSTTY_RELAY_MAX_FRAME_BYTES` | int | `256*1024` |
| rate_limit_requests | `--rate-limit-requests` | `GHOSTTY_RELAY_RATE_LIMIT_REQUESTS` | int | `120` |
| rate_limit_window_seconds | `--rate-limit-window-seconds` | `GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS` | float | `60.0` |
| allow_user_token_client_access | `--allow-user-token-client-access` | `GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS` | bool | `false` |
| allow_public_bind | `--allow-public-bind` | `GHOSTTY_RELAY_ALLOW_PUBLIC_BIND` | bool | `false` |
| trusted_proxies | `--trusted-proxies` | `GHOSTTY_RELAY_TRUSTED_PROXIES` | csv | `""` |
| token_expiry_check_seconds | `--token-expiry-check-seconds` | `GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS` | float | `30.0` |
| ping_interval_seconds | `--ping-interval-seconds` | `GHOSTTY_RELAY_PING_INTERVAL_SECONDS` | float | `30.0` |
| ping_timeout_seconds | `--ping-timeout-seconds` | `GHOSTTY_RELAY_PING_TIMEOUT_SECONDS` | float | `60.0` |
| client_send_buffer_bytes | `--client-send-buffer-bytes` | `GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES` | int | `1024*1024` |
| admin_host | `--admin-host` | `GHOSTTY_RELAY_ADMIN_HOST` | str | `127.0.0.1` |
| admin_port | `--admin-port` | `GHOSTTY_RELAY_ADMIN_PORT` | int | `0`（0=禁用独立 admin） |
| static_root | `--static-root` | `GHOSTTY_RELAY_STATIC_ROOT` | path | `<server.py 的父目录的父目录>/web` |
| upload_max_bytes | `--upload-max-bytes` | `GHOSTTY_RELAY_UPLOAD_MAX_BYTES` | int | `100*1024*1024` (100 MiB) |
| upload_session_max_bytes | `--upload-session-max-bytes` | `GHOSTTY_RELAY_UPLOAD_SESSION_MAX_BYTES` | int | `2*1024*1024*1024` (2 GiB) |
| upload_max_pending | `--upload-max-pending` | `GHOSTTY_RELAY_UPLOAD_MAX_PENDING` | int | `4` |
| upload_global_max_pending | `--upload-global-max-pending` | `GHOSTTY_RELAY_UPLOAD_GLOBAL_MAX_PENDING` | int | `128` |
| upload_ttl | `--upload-ttl` | `GHOSTTY_RELAY_UPLOAD_TTL` | float秒 | `600.0` |
| upload_dir | `--upload-dir` | `GHOSTTY_RELAY_UPLOAD_DIR` | path | `/tmp/ghostty-uploads` |

`agent_disconnect_grace_seconds` 在 dataclass 里硬编码默认 `8.0`，**没有** CLI/env
暴露（复刻时保留为常量 8.0，0 表示禁用宽限）。

只读 env（无 CLI flag）：
- `GHOSTTY_RELAY_SESSION_BACKLOG_BYTES`（默认 `64*1024`）→ `SESSION_BACKLOG_LIMIT`
- `GHOSTTY_RELAY_SESSION_BACKLOG_FRAMES`（默认 `256`）→ `SESSION_BACKLOG_FRAME_LIMIT`
- `GHOSTTY_RELAY_USER_TOKENS`（逗号分隔的内联 token 列表）
- `GHOSTTY_RELAY_USER_TOKENS_FILE`（每行一个 token 的文件；`#` 开头与空行跳过）
- `GHOSTTY_RELAY_APK_PATH`（覆盖 APK 路径）
- `GHOSTTY_RELAY_WEB_BUNDLE_PATH`（覆盖 web bundle zip 路径）
- `GHOSTTY_RELAY_MIN_APK_VERSION_CODE`（默认 0=不强制；非法值记日志后归 0，负值夹到 0）

env_bool 的 true 集合：`{"1","true","yes","on"}`（小写 trim 后比较）。

**绑定保护**：启动时若 `host_requires_public_bind_ack(host)` 为真且未给
`--allow-public-bind`，直接 `parser.error` 退出。规则见 §17。

---

## 3. 常量（直接复刻）

```
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"   # WebSocket accept 计算
DEFAULT_UPLOAD_INIT_BODY_BYTES   = 4096            # （定义了但当前未强制使用）
DEFAULT_UPLOAD_CHUNK_BYTES       = 1*1024*1024     # 落盘时的流式读块大小
DEFAULT_UPLOAD_PATCH_CHUNK_BYTES = 5*1024*1024     # 返回给客户端的推荐 chunk_size
DEFAULT_UPLOAD_PATCH_MAX_BYTES   = 16*1024*1024    # 单个 PATCH body 硬上限
_UPLOAD_FORBIDDEN_NAME_CHARS = {"/","\\","\x00","\r","\n"}
_UPLOAD_NAME_MAX_LENGTH = 200                        # 文件名字节数上限
_NAME_UPDATE_MAX_LENGTH = 256                        # name_update 帧 name 长度上限
_ESSENTIAL_BACKLOG_TYPES = {"hello","appearance"}
APK_DOWNLOAD_FILENAME = "ghostty-sharing.apk"
APK_GRANT_TTL_SECONDS = 60.0
```

Token 生成（全部用 URL-safe、密码学安全随机；Go 用 `crypto/rand` + base64url）：
- `agent_token` / `client_token` / `pull_token`：`secrets.token_urlsafe(24)`（24 字节熵）
- `upload_id` / apk grant：`secrets.token_urlsafe(16)`

时间戳格式：`time.strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(t))`（UTC，秒精度，无小数）。

---

## 4. 数据结构

### RelayConfig
不可变配置（见 §2）。

### RateLimitBucket
`{ window_started_at: float, count: int }`（固定窗口计数器）。

### Session
```
session_id: str
name: str
user_token: str
agent_token: str
client_token: str
expires_at: float            # epoch 秒
online: bool = false
last_seen_at: float          # 默认 now
agent_writer: conn|nil       # 当前 agent 的 WS 连接；nil=agent 离线
clients: map[conn]ClientChannel
backlog: [](opcode, bytes)   # 重放缓冲
backlog_size: int            # backlog 里 0x1/0x2 payload 的累计字节
pending_uploads: map[upload_id]PendingUpload
uploaded_bytes_total: int    # 生命周期累计上传字节（配额用，永不递减）
pending_ready_notifications: []upload_id   # agent 离线期间完成的上传，待重放通知
disconnect_grace_task: task|nil            # agent 掉线宽限计时器
```

### ClientChannel（每客户端发送缓冲，带字节上限）
```
writer: conn
queue: 异步队列（元素是 (opcode,payload) 或 None 哨兵）
queued_bytes: int
max_bytes: int           # = client_send_buffer_bytes
dropped: bool
```
`try_enqueue(opcode, payload)` 逻辑：
1. 若 `dropped` → 返回 false。
2. 若 `max_bytes > 0` 且 `queued_bytes + len(payload) > max_bytes` → 置
   `dropped=true`，往队列塞一个 `None` 哨兵，返回 false（**慢消费者**）。
3. 否则 `queued_bytes += len(payload)`，入队 `(opcode,payload)`，返回 true。

Go 端用带缓冲 channel + 一个原子/受保护的 `queuedBytes` 计数；`None` 哨兵用关
闭 channel 或发送特殊值表达。

### PendingUpload
```
upload_id, session_id, name: str
size: int                 # init 声明的总字节
sha256: str|nil           # init 声明的期望摘要（小写 hex，可选）
pull_token: str
path: filepath            # = upload_dir / "<upload_id>.bin"
created_at, expires_at: float
received: int = 0         # 已落盘字节
sha256_observed: str|nil  # 实际算出的摘要
delivered: bool = false   # agent 已 pull（清理前置位）
uploading: bool = false   # PUT/PATCH 进行中
_hasher                   # 滚动 sha256，跨 PATCH chunk 累积
```

---

## 5. 全局状态 RelayState

- `config`, `offline_ttl`（= config.offline_ttl 的副本）
- `sessions: map[session_id]Session`
- `rate_limits: map[ip]RateLimitBucket`
- `lock`（全局互斥）
- `started_at`（启动 epoch）
- `shutting_down: bool`
- `metrics: map[str]int`（计数器，见 §20）
- `apk_download_grants: map[grant_token]expires_at_epoch`

方法：
- `is_valid_user_token(token)`：若 `allowed_user_tokens` 为空 → **恒 true**
  （accept-any 模式）；否则 `token in allowed`。
- `increment_metric(name, amount=1)`：`metrics[name] += amount`（缺失键当 0）。
- `metrics_text()`：见 §20。
- `should_rate_limit(key, now)`：见 §15。
- `cleanup_loop()`：见 §19。

---

## 6. HTTP 解析与响应原语

### 请求头解析 `read_http_head`
- `readuntil("\r\n\r\n")` 读到头结束。
- 首行 `METHOD TARGET VERSION`，按空格 split 成 3 段。
- 其余行 `key: value`，**key 小写化**存入 map（重复键后者覆盖）。
- body 留在流上由调用方决定怎么读。

### body 读取 `read_http_body`
- 读 `Content-Length`（缺省 0）。
- 若 `length > max_body_bytes` → 抛错（上层转 400）。
- `readexactly(length)`。

### `send_response(writer, status, body, content_type="application/json; charset=utf-8", extra_headers=None)`
- status reason 映射表（必须一致）：200 OK / 201 Created / 400 Bad Request /
  401 Unauthorized / 403 Forbidden / 404 Not Found / 405 Method Not Allowed /
  409 Conflict / 410 Gone / 413 Payload Too Large / 422 Unprocessable Entity /
  429 Too Many Requests / 500 Internal Server Error / 503 Service Unavailable；
  未列出的状态 reason 用 `"OK"`。
- 固定头：`Content-Type`、`Content-Length`、`Connection: close`。
- merge `extra_headers`（覆盖）。
- 再把 CORS ctx 里的头用 **setdefault**（不覆盖 handler 已设的）注入。
- 写完 **关闭连接**（`Connection: close` 语义；每个 HTTP 请求一条连接一次响应）。
- 写入遇 BrokenPipe/ConnectionReset 静默吞掉。

> Go 用 `net/http` 时，`Connection: close` 与「每请求新连接」由 http server 处理，
> 但 WebSocket 升级路径必须 hijack 裸 conn 自己处理。建议：HTTP 业务路由用
> `net/http`，WS 与 upload streaming 路径 hijack。响应体 JSON 用
> `json.Marshal` 且 `ensure_ascii=False` 等价（Go 默认输出 UTF-8，但要注意
> Go 默认会 HTML-escape `<>&`，需 `Encoder.SetEscapeHTML(false)` 才与 Python 一致）。

### 辅助
- `json_bytes(v)` = `json.dumps(v, ensure_ascii=False).encode()`。
- `bearer_token(headers)`：取 `authorization`，大小写不敏感匹配前缀 `bearer `，
  返回其后的原文（不 trim）；无则 nil。
- 查询串：`urllib.parse.parse_qs`，值是列表（取 `[0]`）。

---

## 7. WebSocket 协议（RFC6455 子集）

### 握手 `websocket_handshake`
- 取 `sec-websocket-key`（缺失抛错）。
- `accept = base64(sha1(key + WS_GUID))`。
- 回 `101 Switching Protocols` + `Upgrade: websocket` + `Connection: Upgrade`
  + `Sec-WebSocket-Accept: <accept>`。
- **不校验** `Sec-WebSocket-Version`、不协商子协议、不校验 Origin。

### 读帧 `ws_read_frame(max_frame_bytes)`
- 读 2 字节头：`opcode = b0 & 0x0F`；`masked = b1 & 0x80`；`len = b1 & 0x7F`。
- len==126 → 再读 2 字节大端；len==127 → 再读 8 字节大端。
- 若 `len > max_frame_bytes` → 抛 `ValueError("frame too large")`（上层断开循环）。
- masked 则读 4 字节 mask key，payload 逐字节 `^ mask[i%4]`。
- **不处理分片**（FIN 位被忽略；假定每帧完整）。返回 `(opcode, payload)`。

### 写帧 `ws_send_frame(opcode, payload)`
- `b0 = 0x80 | (opcode & 0x0F)`（FIN=1）。
- 长度 <126 直接；<2^16 用 126+2字节大端；否则 127+8字节大端。
- **服务端发送不加 mask**。
- 文本帧 opcode `0x1`，二进制 `0x2`，close `0x8`，ping `0x9`，pong `0xA`。

### 关闭
- `ws_close(writer)`：发空 close 帧（0x8 空 payload），关 socket。
- `ws_close_with_code(writer, code, reason="")`：close payload = `大端2字节code +
  reason.utf8`。用到的应用关闭码：
  - **4401** `token_expired`（token 过期 watch）/ 各处过期
  - **4408** `ping_timeout`（心跳超时）与 `slow_consumer`（慢消费者丢弃）
- close 帧发送失败一律静默。

---

## 8. 心跳与 token 过期（每个 WS 连接两个后台任务）

### `watch_token_expiry(session, writer, interval)`
- `interval<=0` 直接返回（禁用）。
- 循环：sleep(interval) → 若 `session.expires_at <= now` → `ws_close_with_code(4401,
  "token_expired")` 并退出。

### `watch_heartbeat(writer, last_pong_at, interval, timeout)`
- `interval<=0 或 timeout<=0` 直接返回。
- 循环：sleep(interval) → 若 `now - last_pong_at > timeout` →
  `ws_close_with_code(4408,"ping_timeout")` 退出；否则发 ping 帧（0x9 空 payload）。
  发送异常即退出。
- `last_pong_at` 是个可变盒子 `{"value": ts}`，由读循环在收到 pong（0xA）时更新。

注意：agent 与 client 的读循环里，收到 **0x9（ping）自动回 0xA（pong）**，收到
**0xA（pong）更新 last_pong_at**。

---

## 9. 路由分发 `handle_connection`

入口顺序（**严格按此顺序**，很多分支靠先后次序短路）：

1. 取 peername host。
2. `read_http_head`：`IncompleteReadError` → 静默关连接返回；其它异常 → 记
   `bad_request` 日志 + 400。
3. 解析 target → `path` + `query`（parse_qs）。取 `upgrade` 头小写。
4. `client_ip = resolve_client_ip(peer_host, headers, trusted_proxies)`（§16）。
5. `admin_listener_enabled = admin_port > 0`。
6. **CORS**：`build_cors_headers(origin)`（§18）。若命中则存入 ctx。
7. **OPTIONS 预检**：
   - 无 CORS → `403 ""`（text/plain）。
   - 有 CORS → `204 ""` + `Access-Control-Allow-Methods: GET, POST, PUT, PATCH,
     HEAD, OPTIONS` + `Access-Control-Allow-Headers: <请求的 ACRH 或
     "Authorization, Content-Type">` + `Access-Control-Max-Age: 86400`。
8. **streaming body 判定**：`method in {PUT,PATCH} 且 path 以 /api/upload/ 开头`
   → 不预读 body（交给上传 handler 自己读流）。否则 `read_http_body`（超限或异常
   → `bad_request` 日志 + 400）。
9. **admin 分支**（当前连接来自 admin listener）：只认 `/healthz` `/readyz`
   `/metrics`，其它 404。响应内容见 §11/§20。
10. **public 上的 admin 路径屏蔽**：若 `path ∈ {/healthz,/readyz,/metrics}` 且
    `admin_listener_enabled` → 404（独立 admin 开启后，public 不再暴露）。
11. 否则在 public 上直接服务 `/healthz` `/readyz` `/metrics`（admin_port=0 时）。
12. **限流**：构造 `rate_limited_paths` 集合（见下）。若 `path ∈ 集合` 或
    `is_upload_resource`（`/api/upload/` 开头但不是 `/api/upload/init`）→ 持锁调
    `should_rate_limit(client_ip)`，命中则 `429` + `Retry-After` + 记日志 +
    `rate_limited_total++`，返回。
13. **WS 升级**：`upgrade=="websocket"` 且 path `/ws/agent` → `handle_ws_agent`；
    `/ws/client` → `handle_ws_client`。
14. **REST 路由**（精确匹配）：
    - `/api/register` → `handle_register`
    - `/api/sessions` → `handle_sessions`
    - `/api/app/android` → `handle_apk_download`
    - `/api/app/android/grant` → `handle_apk_grant`
    - `/api/app/version` → `handle_apk_version`
    - `/api/web/manifest.json` → `handle_web_manifest`
    - `/api/web/bundle` → `handle_web_bundle`
    - `/api/upload/init` → `handle_upload_init`
    - 其它 `/api/upload/...`（upload_resource）→ §13.6 子路由
15. **兜底**：`serve_static`（§14）。

`rate_limited_paths` 集合：`/api/register`, `/api/sessions`, `/ws/agent`,
`/ws/client`, `/api/upload/init`, `/api/app/android`, `/api/app/android/grant`,
`/api/app/version`, `/api/web/manifest.json`, `/api/web/bundle`。

---

## 10. REST：注册与会话列表

### `POST /api/register`
- 非 POST → 405。`register_requests_total++`。
- body JSON 取 `session_id`/`name`/`token`（均强转 str），解析失败 → 400 invalid json。
- 校验：`session_id` 非空且 ≤128；`name` ≤256；`token` 非空且 ≤1024。不满足 →
  `register_rejected_total++` + 400 invalid payload。
- `is_valid_user_token` 失败 → `register_rejected_total++` + `auth_rejected_total++`
  + 日志 `register_rejected(reason=invalid_user_token)` + 401。
- 持锁：
  - 取 existing。若 existing 为 nil 且 `len(sessions) >= max_sessions` →
    `register_rejected_total++` + 503 "session capacity reached"。
  - **existing 非 nil（重注册/重连）**：原地更新——`user_token=token`；
    **轮换** `agent_token`、`client_token`（新随机）；`expires_at=now+token_ttl`；
    `last_seen_at=now`；`online=false`；**仅当传入 name 非空才覆盖 name**（保留
    自动同步模式下累计的 name 与 backlog）。`register_reused_total++`。
    *不* 校验 user_token 是否与原值一致（session_id 是客户端 UUID）。
  - **新建**：构造 Session，tokens 全新随机，`expires_at=now+token_ttl`，
    `online=false`，`last_seen_at=now`，存入 map。
- 日志 `register(session_id, name_length, online=false, reused=bool)`。
- 200 响应：`{session_id, agent_token, client_token, expires_at:<RFC3339Z>}`。

### `GET /api/sessions`
- 非 GET → 405。
- `bearer_token` 缺失 → `auth_rejected_total++` + 401 missing bearer token。
- `is_valid_user_token` 失败 → `auth_rejected_total++` + 401 invalid user token。
- 持锁筛选：`user_token == token` 且 `expires_at > now` 的会话，输出数组，每项：
  `{id, name, online, last_seen_at:<RFC3339Z>, client_token}`。
- 200。

---

## 11. 健康/就绪/指标

- `GET /healthz` → `200 {"ok": true}`。
- `GET /readyz` → 持锁 `200 {"ok": !shutting_down, "sessions": <count>,
  "uptime_seconds": int(now-started_at)}`。
- `GET /metrics` → 持锁 `200 <prometheus text>`，content-type
  `text/plain; version=0.0.4; charset=utf-8`（§20）。

这三个在 admin listener 上始终可用；在 public listener 上仅当 `admin_port==0`
时可用（否则 404）。

---

## 12. APK / Web bundle / 版本 / manifest

路径解析：
- APK：`GHOSTTY_RELAY_APK_PATH` 覆盖，否则 `static_root.parent/apk/app-release.apk`。
- web bundle：`GHOSTTY_RELAY_WEB_BUNDLE_PATH` 覆盖，否则
  `static_root.parent/web-bundle/dist.zip`。

### `POST /api/app/android/grant`
- 非 POST → 405。Bearer 校验（缺失/无效 → `auth_rejected_total++` +
  `apk_download_grant_rejected_total++` + 401）。
- 生成 grant=`token_urlsafe(16)`，持锁存
  `apk_download_grants[grant]=now+60s`。`apk_download_grant_total++`。
- 200 `{token:<grant>, expires_in:60}`。

### `GET /api/app/android`（APK 下载）
- 非 GET → 405。
- 鉴权二选一：
  - `?dl=<grant>` 或 `?grant=<grant>`：持锁查 grants，未过期 → 通过（**不消费**，
    60s TTL 是唯一闸门，浏览器重试同 URL 仍可用）；已过期则从 map 删；任一不通过
    → `apk_download_rejected_total++` + 401 "invalid or expired grant"。
  - 否则 Bearer user token（缺失/无效 → `auth_rejected_total++` +
    `apk_download_rejected_total++` + 401）。
- 文件不存在 → `apk_download_rejected_total++` + 日志 + 503 apk_not_available。
- 读取全部字节，`apk_download_total++`，200，content-type
  `application/vnd.android.package-archive`，头 `Content-Disposition: attachment;
  filename="ghostty-sharing.apk"` + `Cache-Control: no-store`。

### `GET /api/app/version`（公开，无需 Bearer）
- 非 GET → 405。`min_code = _min_apk_version_code()`。
- 读 `<apk_path>.parent/version.json`。文件缺失/损坏 → 200
  `{versionCode:0, versionName:"unknown", available:false, minVersionCode:min_code}`。
- 正常 → 200 `{versionCode:int|0, versionName:str|"unknown", builtAt:str|"",
  available:true, minVersionCode:min_code}`（字段类型强制，防御性 coerce）。

### `GET /api/web/manifest.json`（公开，无需 Bearer）
- 非 GET → 405。读 `static_root/manifest.json`。
- 缺失/损坏 → 200 `{webVersion:"unknown", available:false}`。
- 正常 → 200 `{webVersion, sha256, sizeBytes:int|0, builtAt, bundleUrl,
  requiredApkVersionCode:int|0, available:true}`。

### `GET /api/web/bundle`（Bearer-only）
- 非 GET → 405。Bearer 校验（缺失/无效 → `auth_rejected_total++` +
  `web_bundle_rejected_total++` + 401）。
- 文件缺失 → `web_bundle_rejected_total++` + 日志 + 503 bundle_not_available。
- 读全部，`web_bundle_total++`，200 `application/zip` +
  `Content-Disposition: attachment; filename="ghostty-web.zip"` +
  `Cache-Control: no-store`。

> `web_bundle_rejected_total` / `web_bundle_total` 不在初始 metrics dict 里，
> 靠 `increment_metric` 的「缺失键当 0」动态创建。复刻时 metrics map 要支持动态键。

---

## 13. 文件上传子系统（核心，状态机最复杂）

整体流程：浏览器 `init` → 拿到 upload_id → `PUT`（单发）或 `PATCH`（分片，
tus 1.0 子集）落盘到 relay 临时文件 → 完成时校验 sha256 → 向 agent 发
`upload_ready` 控制帧 → agent `GET .../pull` 用 pull_token 取走文件 → 删除。

### 13.1 文件名清洗 `_sanitize_upload_name`
- 必须是 str；trim；非空且 **UTF-8 字节数 ≤200**。
- 含 `_UPLOAD_FORBIDDEN_NAME_CHARS`（`/ \ \0 \r \n`）任一 → 拒绝。
- 含任何码点 `<0x20`（控制字符）→ 拒绝。
- 等于 `"."` 或 `".."` → 拒绝。
- 通过则**原样保留**（CJK/重音等非 ASCII 保真；agent 端会再做严格清洗）。

### 13.2 `POST /api/upload/init`
- 非 POST → 405。`upload_init_total++`。
- Bearer 缺失 → `upload_init_rejected_total++` + `auth_rejected_total++` + 401。
- body JSON 解析失败 → `upload_init_rejected_total++` + 400 invalid json。
- 取 `session_id`(str)、`size`(int)、`sha256`(可选)、`name`(经清洗)。
  - session_id 非 str 或 name 清洗失败 → reject + 400 invalid payload。
  - size 非 int 或 ≤0 → reject + 400 invalid_size。
  - size > upload_max_bytes → reject + 413 size_exceeds_limit。
  - sha256 若提供：必须 64 位且全 hex（小写化后判断），否则 reject + 400
    invalid_sha256；通过则存小写。
- 持锁：
  - session 不存在或 `user_token != token` → reject + 404 session_not_found。
  - `expires_at <= now` → reject + `expired_session_rejected_total++` + 401
    expired session。
  - `active_pending`（该 session 内 `!delivered` 的上传数）≥ upload_max_pending
    → reject + 429 too_many_pending。
  - `global_pending`（全局所有 session 的 `!delivered` 上传数）≥
    upload_global_max_pending → reject + 429 global_pending_full。
  - `uploaded_bytes_total + size > upload_session_max_bytes` → reject + 413
    size_exceeds_session_limit。
  - 生成 upload_id=`token_urlsafe(16)`、pull_token=`token_urlsafe(24)`，构造
    PendingUpload（path=`upload_dir/<id>.bin`，expires_at=now+upload_ttl），存入
    session.pending_uploads。
- 日志 `upload_init`。200
  `{upload_id, upload_url:"/api/upload/<id>", expires_at:int(秒),
  chunk_size:5MiB, patch_max_bytes:16MiB}`。

### 13.3 `PUT /api/upload/<id>`（单发，流式落盘）
- `upload_put_total++`。Bearer 缺失 → reject + auth_rejected + 401。
- 解析 `Content-Length` → declared；非法 → reject + 400 invalid_content_length。
- 持锁查找 upload（遍历所有 session 的 pending_uploads 找 upload_id）：
  - 找不到 → reject + 404 not_found。
  - `owning_session.user_token != token` → reject + auth_rejected + 401。
  - `uploading 或 received>0 或 delivered` → reject + 409 already_uploaded。
  - `declared != upload.size` → reject + 409 size_mismatch。
  - `size > upload_max_bytes` → reject + 413 size_exceeds_limit。
  - 置 `uploading=true`（**锁内**，防并发第二个 PUT）。
- 锁外流式读：循环 `readexactly(min(remaining, 1MiB))` → 写文件 + 更新 hasher +
  `received += n`，每块后 `await sleep(0)` 让出。
  - 读/写异常（IncompleteRead/ConnReset/OSError）→ `upload_put_rejected_total++`
    + 持锁 `_remove_upload(reason=put_aborted)` + 日志 + 400 incomplete_body。
- 调 `_finalize_completed_upload`（§13.7）。返回 hash_mismatch → reject + 422。
- 日志 `upload_put`。200 `{upload_id, received, sha256:<observed>}`。

### 13.4 `PATCH /api/upload/<id>`（tus 1.0 子集，分片）
- `upload_put_total++`（与 PUT 共享计数族）。Bearer 缺失 → reject + auth + 401。
- **严格要求** `Content-Type: application/offset+octet-stream`（取 `;` 前、小写
  trim 比较），否则 reject + 415 invalid_content_type。
- `Content-Length` → declared：非法 → 400 invalid_content_length；≤0 → 400
  empty_chunk；> 16MiB(patch_max) → 413 chunk_too_large。
- `Upload-Offset` → client_offset：非法 → 400 invalid_upload_offset。
- 持锁查找 upload：
  - 找不到 → 404 not_found。
  - user_token 不符 → auth + 401。
  - `delivered` → 409 already_delivered。
  - `uploading` → 409 concurrent_patch。
  - `client_offset != received` → 409 offset_mismatch（**带头 `Upload-Offset:
    <received>`** 让客户端重定位）。
  - `received + declared > size` → 413 overshoot。
  - 置 `uploading=true`。
- 锁外流式：`mode = received==0 ? 写新建 : 追加`，循环读 1MiB 块写盘 +
  hasher.update + `received += n` + `sleep(0)`。
  - 异常 → `upload_put_rejected_total++` + 持锁 `uploading=false`（**保留** upload
    以便续传，不删文件不回退 received）+ 日志 upload_patch_aborted + 400
    incomplete_chunk。
- `new_offset = received`：
  - **中间块** `new_offset < size`：持锁 `uploading=false`；返回 **204** 空体 +
    `Upload-Offset:<new_offset>` + `Cache-Control: no-store`。
  - **末块** `new_offset == size`：调 `_finalize_completed_upload`。hash_mismatch
    → reject + 422。否则日志 upload_patch_complete + 200
    `{upload_id, received, sha256}` + 头 `Upload-Offset:<new_offset>`。

### 13.5 `HEAD /api/upload/<id>`（tus 续传探测）
- Bearer 缺失 → auth + 401。持锁查 upload：找不到 → 404；user_token 不符 →
  auth + 401；取 `offset=received`、`total=size`。
- 200 空体，content-type `application/octet-stream`，头 `Upload-Offset:<offset>`
  + `Upload-Length:<total>` + `Cache-Control: no-store`。

### 13.6 upload_resource 子路由（在 handle_connection 内）
`rest = path[len("/api/upload/"):]`：
- `rest` 以 `/pull` 结尾：`upload_id = rest[:-5]`，空 → 404；否则
  `handle_upload_pull`。
- 否则 `upload_id = rest`：含 `/` 或为空 → 404 not_found。
  - PUT → handle_upload_put；PATCH → handle_upload_patch；HEAD →
    handle_upload_head；其它 → 405。

### 13.7 完成收尾 `_finalize_completed_upload`
- `digest = hasher.hexdigest()`；`sha256_observed = digest`。
- 若 init 声明了 sha256 且 `digest != sha256` → 持锁 `_remove_upload(
  reason=hash_mismatch)`，返回 `"hash_mismatch"`。
- 否则持锁：`uploaded_bytes_total += size`；`upload_bytes_total += size`（指标）；
  `uploading=false`。
- **锁外** `_push_upload_ready_unlocked`（向 agent 发 upload_ready；失败则入队
  待重放）。返回 nil。

### 13.8 `GET /api/upload/<id>/pull`（agent 取文件）
- 非 GET → 405。`upload_pull_total++`。
- pull_token 来源：`?token=` 优先，否则 Bearer。缺失 → `upload_pull_rejected_total++`
  + 403 invalid_token。
- 持锁查 upload：
  - 找不到 → reject + 404 not_found。
  - `delivered` → reject + 410 gone。
  - **`secrets.compare_digest(pull_token, upload.pull_token)` 不匹配**（常数时间
    比较）→ reject + 403 invalid_token。
  - `received != size` → reject + 409 not_complete。
  - 置 `delivered=true`（**流式发送前**置位，防并发双发）。
- 锁外读文件：读失败（OSError）→ reject + 日志 + 持锁 `_remove_upload(
  reason=read_failed)` + 500 read_failed。
- 200 发送文件字节，content-type `application/octet-stream`，头
  `X-Ghostty-Upload-Name: <urlencode(name)>`（quote safe=""）+
  `X-Ghostty-Upload-SHA256: <sha256_observed 或 "">`。
- **finally**（无论发送成功与否）：持锁 `_remove_upload(reason=pulled)`——即使
  send 中途断开也要删临时文件（否则 token 已消费却留孤儿文件到 TTL）。
- 日志 `upload_pull`。

### 13.9 `upload_ready` 帧与重放
- `_upload_ready_frame(upload)` = 文本 JSON：
  `{type:"upload_ready", upload_id, name, size, sha256, pull_token,
  pull_url:"/api/upload/<id>/pull"}`（**含 pull_token**，agent 用它来 pull）。
- `_push_upload_ready_unlocked(session, upload)`：若 `agent_writer==nil` →
  `_queue_pending_notification` 入队 + 返回 false；否则发文本帧（0x1），成功
  true，异常则入队 + false。**必须锁外调用**。
- `_queue_pending_notification`：upload_id 不在
  `pending_ready_notifications` 才 append（去重）。
- `_drain_pending_upload_ready(session)`：持锁快照
  `pending_ready_notifications` 并清空，过滤出仍存在且 `!delivered` 且
  `received==size` 的 upload；**锁外**逐个 `_push_upload_ready_unlocked`。在
  agent WS 握手后、读循环前调用一次。

### 13.10 `_remove_upload(session, upload, reason)`
- 从 `pending_uploads` 删 upload_id；删磁盘文件（不存在则跳过，OSError 记
  `upload_cleanup_failed` 日志但不抛）。**不**递减 `uploaded_bytes_total`。

---

## 14. 静态文件服务 `serve_static`

`resolve_static_path(static_root, target_path)`：
- 特例 `/ghostty-vt.wasm`：先看 `<repo>/zig-out/bin/ghostty-vt.wasm`
  （`server.py` 上溯 3 层父目录），存在则返回它。
- `path = target_path=="/" ? "/index.html" : target_path`。
- `resolved = (static_root / path.lstrip("/")).resolve()`。
- **路径穿越防护**：`static_root` 必须是 `resolved` 的祖先，**或** resolved 恰为
  `static_root/index.html`；否则返回 None（→ 404）。
- 文件不存在/非普通文件 → None。

content-type 后缀映射：`.html→text/html; charset=utf-8`，`.js→application/
javascript; charset=utf-8`，`.css→text/css; charset=utf-8`，`.json→application/
json; charset=utf-8`，`.wasm→application/wasm`，其它 `application/octet-stream`。
找不到 → `404 "not found"`（text/plain）。

---

## 15. 限流 `should_rate_limit(key, now)`（固定窗口/IP）

- `rate_limit_requests <= 0` → 永不限流，返回 `(false, 0)`。
- 取 `bucket = rate_limits[key]`：
  - bucket 不存在，或 `now - window_started_at >= window_seconds`（窗口过期）→
    新建 `{window_started_at:now, count:1}`，返回 `(false,0)`。
  - `count >= rate_limit_requests` → 计算 `retry_after = max(1, int(window -
    (now-window_started_at)))`，返回 `(true, retry_after)`。
  - 否则 `count++`，返回 `(false,0)`。
- 命中限流的响应：429 `{"error":"rate limited"}` + 头 `Retry-After:<n>` + 日志
  `rate_limited` + `rate_limited_total++`。
- key = `client_ip`（§16 解析后的真实 IP）。

---

## 16. 真实 IP 解析 `resolve_client_ip(peer_host, headers, trusted_proxies)`

- `peer_host` 为空 → `"unknown"`。
- `trusted_proxies` 为空 → 直接返回 peer_host（**绝不信 XFF**）。
- peer_host 非法 IP → 返回 peer_host。
- peer_ip 不在任一 trusted 网段 → 返回 peer_host。
- 取 `X-Forwarded-For`，空 → peer_host；取第一跳（首个逗号前）trim，空 →
  peer_host；第一跳非法 IP → peer_host；否则返回第一跳。

`parse_trusted_proxies(csv)`：逗号分隔，每项 trim，空跳过，
`ip_network(item, strict=False)` 解析（支持 CIDR），非法项记
`trusted_proxy_invalid` 日志并跳过。Go 用 `net.ParseCIDR` / `netip.ParsePrefix`。

---

## 17. 公网绑定保护 `host_requires_public_bind_ack(host)`

返回 true（需要 `--allow-public-bind`）的条件：
- host normalize（trim+小写）。
- `"localhost"` → false（信任）。
- 解析为 IP 失败（无法判断的主机名）→ **true**（保守当公网）。
- `is_unspecified`（`0.0.0.0` / `::`）→ true（绑所有网卡）。
- `is_loopback`（127/8、::1）→ false。
- `is_private`（RFC1918/CGNAT 等）或 `is_link_local`（169.254/16、fe80::/10）
  → false（LAN 部署，故意）。
- 其它 → true（公网）。

Go 用 `net/netip` 的 `IsLoopback`/`IsPrivate`/`IsLinkLocalUnicast`/
`IsUnspecified`（注意 Go 标准库 `IsPrivate` 不含 CGNAT 100.64/10，需自行补判以
完全等价；以及 IPv6 ULA `fc00::/7` Python 归 `is_private`，Go 需手动判定）。

---

## 18. CORS（仅 Capacitor 原生 WebView）

允许的 Origin 白名单 `CAPACITOR_CORS_ORIGINS`：
`https://localhost`、`http://localhost`、`capacitor://localhost`、
`ionic://localhost`。

- `build_cors_headers(origin)`：origin 在白名单 → 返回
  `{Access-Control-Allow-Origin:<origin>, Access-Control-Allow-Credentials:true,
  Vary:Origin}`；否则空。
- 命中时存入请求级 ctx，`send_response` 用 setdefault 注入（不覆盖 handler 自
  设值）。Go 用 per-request 传递（context 或参数），不能用全局变量。
- OPTIONS 预检见 §9.7。

---

## 19. 后台清理 `cleanup_loop`（每 5 秒，全程持锁）

每轮 `now=time.time()`，`cutoff=now-offline_ttl`，
`rate_limit_cutoff=now-window_seconds`，持锁执行：
1. **过期上传**：遍历所有 session 的 pending_uploads，`expires_at < now` 的 →
   `upload_expired_total++` + `_remove_upload(reason=ttl_expired)` + 日志
   `upload_expired`。（先删上传，再删 session，确保临时文件不漏。）
2. **过期 session**：`!online 且 last_seen_at < cutoff` 的 session_id →
   从 map pop，并对其剩余 pending_uploads 逐个 `_remove_upload(
   reason=session_expired)` + 日志 `session_expired`。
3. **过期 apk grant**：`deadline < now` 的从 grants map 删。
4. **过期限流桶**：`window_started_at < rate_limit_cutoff` 的从 rate_limits 删。

---

## 20. 指标 `/metrics`（Prometheus 文本）

输出顺序：先 6 个 gauge，再按 **key 字典序** 输出所有计数器。每个指标前一行
`# TYPE ghostty_relay_<name> <gauge|counter>`。结尾补一个 `\n`。

Gauge（实时计算）：
- `ghostty_relay_sessions`（session 总数）
- `ghostty_relay_sessions_online`（online=true 数）
- `ghostty_relay_sessions_offline`（总数 - online）
- `ghostty_relay_active_agents`（agent_writer != nil 数）
- `ghostty_relay_active_clients`（所有 session 的 clients 数之和）
- `ghostty_relay_uptime_seconds`（int(now-started_at)）

Counter（初始化为 0 的固定集合，前缀 `ghostty_relay_`）：
```
register_requests_total, register_rejected_total, register_reused_total,
agent_grace_started_total, agent_grace_canceled_total, agent_grace_expired_total,
agent_connect_total, agent_disconnect_total,
client_connect_total, client_disconnect_total,
auth_rejected_total, expired_session_rejected_total, rate_limited_total,
slow_consumer_drop_total,
upload_init_total, upload_init_rejected_total,
upload_put_total, upload_put_rejected_total,
upload_pull_total, upload_pull_rejected_total,
upload_expired_total, upload_bytes_total,
apk_download_total, apk_download_rejected_total,
apk_download_grant_total, apk_download_grant_rejected_total
```
另有运行时**动态创建**的计数器（不在初始 dict）：`name_update_total`、
`web_bundle_total`、`web_bundle_rejected_total`。复刻时 metrics 容器必须允许动态
新增键，且 `/metrics` 排序输出能自然包含它们。

---

## 21. WebSocket 业务：Agent 与 Client 生命周期

### 21.1 Agent 连接 `handle_ws_agent`
1. 取 `?id=` 与 Bearer token。任一缺失 → `auth_rejected_total++` + 401（注意：
   此时还没握手，走 HTTP 响应）。
2. 持锁：session 不存在或 `agent_token != token` → auth + 401 invalid agent
   token；`expires_at <= now` → auth + `expired_session_rejected_total++` + 401
   expired agent token；否则置 `online=true`、`last_seen_at=now`、
   `agent_writer=writer`；取出待取消的 `disconnect_grace_task` 并置 nil。
3. **锁外**取消 grace task（若有且未完成）：cancel + await + `agent_grace_canceled_total++`
   + 日志（保证宽限期内重连的 client 不被断开）。
4. `websocket_handshake`。`agent_connect_total++` + 日志 agent_connected。
5. `_drain_pending_upload_ready`（补发离线期间完成的 upload_ready）。
6. 启动两个后台任务：watch_token_expiry、watch_heartbeat（last_pong_at 初始 now）。
7. 跑 `ws_agent_loop`；finally 取消并 await 两个后台任务。

### 21.2 Agent 读循环 `ws_agent_loop`
- 循环 `ws_read_frame`：异常（IncompleteRead/ConnReset/ValueError）→ break。
- 每帧更新 `session.last_seen_at`。
- `0x8`（close）→ break。`0x9`（ping）→ 回 `0xA` pong（带原 payload）。
- `0xA`（pong）→ 更新 last_pong_at。
- `0x1`/`0x2`：
  - 若 `0x1` 且 `_handle_name_update` 返回 true → **吞掉**（不转发不入 backlog）。
  - 否则 `forward_to_clients(session, opcode, payload)`。
- **finally（agent 断开收尾）**：
  - 持锁：`online=false`、`agent_writer=nil`、`last_seen_at=now`，取
    `client_count`。`agent_disconnect_total++` + 日志 agent_disconnected。
  - 若 `client_count>0 且 grace_seconds>0`：持锁新建
    `disconnect_grace_task = _expire_agent_grace(...)`（先存旧值），锁外取消旧
    task（防御性幂等），`agent_grace_started_total++` + 日志 agent_grace_started。
  - 否则（无 client 或宽限禁用）：持锁取出并清空 clients，锁外逐个 `ws_close`。
  - 最后 `ws_close(writer)`（关 agent 自己）。

### 21.3 宽限过期 `_expire_agent_grace`
- sleep(grace_seconds)；被 cancel → 直接返回（agent 已重连）。
- 持锁：若 `agent_writer != nil`（竞态：重连已落地）→ 清 grace_task 置 nil 返回；
  否则取出并清空 clients、grace_task 置 nil。`agent_grace_expired_total++` + 日志。
- 锁外逐个 `ws_close(client)`（让 client 走正常重连/重列流程）。

### 21.4 `name_update` 控制帧 `_handle_name_update`
- 解析文本 JSON：非 JSON 或非 dict 或 `type != "name_update"` → 返回 false
  （走正常转发路径）。
- `name` 非 str 或 长度 >256 → 返回 **true**（吞掉这个畸形帧，不改 name）。
- `name` 与现值不同 → 更新 `session.name`（CPython str 赋值原子；Go 用锁或
  原子保护读写，因为 `/api/sessions` 会并发读）+ `name_update_total++` + 日志
  `name_update(session_id, name_length)`（**不记 name 内容**，隐私）。返回 true。

### 21.5 Client 连接 `handle_ws_client`
1. `?id=`、token = `?token=` 优先否则 Bearer。任一缺失 → auth + 401。
2. 持锁：
   - session 不存在 → 404 session not found。
   - `expires_at <= now` → auth + `expired_session_rejected_total++` + 401。
   - `using_user_token = (token == user_token)`。
   - 若用 user_token 且 `!allow_user_token_client_access` → auth + 401 user
     token client access disabled。
   - 若用 user_token 且 `!is_valid_user_token` → auth + 401。
   - 若 `token ∉ {client_token, user_token}` → auth + 401 invalid client token。
   - 若 `len(clients) >= max_clients_per_session` → 503 client capacity reached。
   - 新建 ClientChannel(writer, client_send_buffer_bytes)，存
     `clients[writer]=channel`，`last_seen_at=now`。
3. `websocket_handshake`。`client_connect_total++` + 日志。
4. 启动 `client_sender(channel)`（发送循环）。
5. `replay_backlog(session, channel)`（重放历史，§22）。
6. 若 `agent_writer != nil`，发文本帧 `{"type":"client_connected"}` 给 agent
   （让 agent 重发当前快照；老 agent 忽略，安全）。失败静默。
7. 启动 watch_token_expiry、watch_heartbeat。
8. 跑 `ws_client_loop`；finally 取消 + await 两个后台任务 **和** sender_task。

### 21.6 Client 读循环 `ws_client_loop`
- 循环 `ws_read_frame`：异常 → break。每帧更新 last_seen_at。
- `0x8` → break。`0x9` → 回 pong。`0xA` → 更新 last_pong_at。
- 取 `agent_writer`，nil → continue（丢弃，agent 不在）。
- `0x1` → 转文本给 agent；`0x2` → 转二进制给 agent。
- **finally**：从 `clients` 删 writer，`client_disconnect_total++` + 日志。
  若 **clients 空了且 agent_writer 在** → 发文本
  `{"type":"client_disconnect"}` 给 agent（桌面端据此恢复原终端尺寸）。失败静默。
  `ws_close(writer)`。

### 21.7 客户端发送器 `client_sender`
- 循环 `item = queue.get()`：
  - `item == None`（慢消费者哨兵）→ `slow_consumer_drop_total++` + 日志 +
    `ws_close_with_code(4408, "slow_consumer")` + 退出。
  - 否则 `(opcode, payload)`：opcode 0x1 → 发文本（`decode utf-8 replace`）；
    0x2 → 发二进制。发送异常 → 退出。finally `queued_bytes -= len(payload)`（不
    低于 0）。
- 被 cancel → 退出。

---

## 22. 转发与 backlog（重放缓冲，逻辑最微妙）

### `forward_to_clients(session, opcode, payload)`
- 先 `append_backlog(opcode, payload)`。
- 仅 opcode ∈ {0x1, 0x2} 才转发：遍历 `clients.values()` 逐个 `try_enqueue`。

### `replay_backlog(session, channel)`
- 先记 `replay_backlog` 诊断日志（统计每帧 kind:len；文本帧尝试解析 type）。
- 遍历 backlog，opcode ∈ {0x1,0x2} 的逐个 `try_enqueue` 到新 channel。

### `append_backlog(opcode, payload)`（**关键去重/快照逻辑**）
1. 仅处理 opcode ∈ {0x1,0x2} 且 payload 非空，否则直接 return。
2. **essential metadata 去重**：`new_type = _essential_metadata_type(opcode,
   payload)`（即 hello/appearance）。若非 nil：遍历现有 backlog，**移除所有同
   type 的旧条目**（只保留即将追加的最新值），重算 backlog_size。
3. **screen 快照裁剪**：若 `opcode==0x1 且 _is_screen_snapshot(payload)`（文本
   JSON 且 `type=="screen"`）：丢弃快照之前的所有 backlog，**但保留** 仍是
   essential metadata（hello/appearance）的文本帧（它们带 cols/rows、配色，
   screen 帧不含）。重算 size。
4. 追加 `(opcode, bytes(payload))`，`backlog_size += len(payload)`。
5. **容量裁剪**：当 `backlog_size > SESSION_BACKLOG_LIMIT(64KiB)` **或**
   `len(backlog) > SESSION_BACKLOG_FRAME_LIMIT(256)` 时，从头 pop，pop 的若是
   0x1/0x2 则 `backlog_size -= len`，循环直到不超限。

辅助判定：
- `_is_screen_snapshot(payload)`：文本 JSON dict 且 `type=="screen"`。
- `_essential_metadata_type(opcode, payload)`：opcode 0x1 且文本 JSON dict 且
  `type ∈ {hello, appearance}` → 返回该 type，否则 nil。
- `_is_essential_metadata(payload)` = `_essential_metadata_type(0x1, payload) != nil`。

> 这是 fork 的核心优化（修过 HarmonyOS WebView 文字重叠 bug、首屏慢扫描）。
> Go 复刻**必须逐条保留**这些去重/裁剪规则，否则重连重放行为会回退。

---

## 23. 启动与关闭 `main`

1. argparse 解析（§2）。公网绑定校验失败 → error 退出。
2. 构造 RelayConfig（static_root、upload_dir 都 `.resolve()` 成绝对路径）。
3. `RelayState(config)`。
4. `asyncio.start_server` 起 public listener（`handle_connection(..., admin=False)`）。
5. `admin_port>0` 时再起 admin listener（`admin=True`）。
6. 注册 SIGINT/SIGTERM → `begin_shutdown`（幂等：置 shutting_down、记
   `shutdown_requested` 日志、set stop_event）。
7. 记 `relay_started` 日志（含全部 config 字段，auth_mode 为
   `token-allowlist`/`accept-any-token`）。
8. 起 `cleanup_loop` 后台任务。
9. await stop_event；finally 关闭两个 listener。记 `relay_stopped`。

---

## 24. 日志格式

`log_event(event, **fields)`：输出单行 JSON，第一字段
`ts:<%Y-%m-%dT%H:%M:%SZ UTC>`、`event:<name>`，其余 kv 合并，`ensure_ascii=False`，
flush。Go 用 `encoding/json` + `SetEscapeHTML(false)`，每行一个对象，写
stdout 并 flush。

完整事件名清单（便于对照测试）：
`trusted_proxy_invalid, min_apk_version_code_invalid, apk_version_corrupt,
web_manifest_corrupt, web_bundle_missing, apk_download_missing, name_update,
upload_init, upload_put, upload_put_aborted, upload_patch_aborted,
upload_patch_complete, upload_pull, upload_pull_failed, upload_cleanup_failed,
upload_expired, session_expired, register, register_rejected, rate_limited,
bad_request, agent_connected, agent_disconnected, agent_grace_started,
agent_grace_canceled, agent_grace_expired, client_connected,
client_disconnected, slow_consumer_drop, replay_backlog, shutdown_requested,
relay_started, relay_stopped`。

---

## 25. Go 复刻关键对应与陷阱清单

1. **锁内禁 IO**：所有 `ws_send_*` / `send_response` / 文件读写在 `Mutex.Unlock()`
   之后做。查找 upload（遍历 session）在锁内，落盘在锁外。
2. **JSON 不转义 HTML**：`json.Encoder.SetEscapeHTML(false)`，否则 name 里的
   `<>&` 会与 Python 输出不一致。
3. **常数时间比较**：pull_token 用 `crypto/subtle.ConstantTimeCompare`。
4. **token 生成**：`crypto/rand` 读 N 字节 → `base64.RawURLEncoding`。
   `token_urlsafe(n)` 是 n 字节熵 → 约 `ceil(n*4/3)` 字符；长度不必逐字符相同，
   但熵必须 ≥ 原值（24/16 字节）。
5. **WS 帧**：服务端发送不加掩码；读取要解掩码；不支持分片（与 Python 一致，
   但若用现成库注意库会自动处理分片/控制帧，需确认 ping/pong/close 行为与
   4401/4408 自定义关闭码可控）。
6. **慢消费者**：每 client 一个发送 goroutine + 有界缓冲；超 `max_bytes` 即标记
   dropped 并以 4408 slow_consumer 关闭，**不能阻塞**广播循环。
7. **backlog 去重/快照裁剪**：§22 逐条复刻，含 essential metadata 跨 screen
   保留。
8. **upload 续传**：PATCH 失败保留 received（可续传），PUT 失败删整个 upload。
9. **public/admin 双 listener** 与 admin 路径在 public 上的屏蔽。
10. **限流 key 用解析后的真实 IP**；trusted_proxies 为空时绝不信 XFF。
11. **CGNAT / IPv6 ULA** 在公网绑定判定里属于「私网」，Go 标准库需补判（§17）。
12. **metrics 动态键**：`name_update_total`、`web_bundle_total`、
    `web_bundle_rejected_total` 不在初始集合，输出按字典序。
13. **register 重连**：保留 name（除非传入非空）/backlog，轮换 token，刷新 TTL。
14. **upload_dir / static_root / apk / web-bundle 路径解析**（含 env 覆盖与
    `static_root.parent` 相对定位）。

---

## 26. 验证基线

复刻后用现有 Python 测试做对拍（同一份请求序列打到 Go 服务应得到等价结果）：
- `smoke_test.py`（REST + WS 端到端）
- `upload_smoke_test.py`（上传 init/put/patch/pull 全链路）
- `load_test.py`（并发压力 / 慢消费者 / 限流）

逐条核对：HTTP 状态码、JSON 错误字符串（如 `size_exceeds_limit`、
`offset_mismatch`、`hash_mismatch`）、WS 关闭码（4401/4408）、`/metrics` 计数器
增量、关键日志事件名。
