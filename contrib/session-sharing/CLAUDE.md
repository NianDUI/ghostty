# Session Sharing — Web + Relay 部署补遗

`relay/` 和 `ghostty-web-client/` 部署到同一台生产服务器。运维流程见
[`relay/README.md`](relay/README.md) 和 [`relay/DEPLOY.md`](relay/DEPLOY.md)；
协议契约见 [`/docs/plan/web-upload.md`](/docs/plan/web-upload.md)。这里只
记从两份 README 推不出来的实战要点。

## `deploy.env` 是 gitignored，禁止 commit

`relay/` 和 `ghostty-web-client/` 各一份 sibling `deploy.env`，含
`DEPLOY_HOST` / `DEPLOY_PATH`。未配置 `deploy.sh` 直接 fail-closed。

## Web 部署 (`ghostty-web-client/deploy.sh`)

- 默认会重 `npm run build`；已有 `dist/` 想直接发用 `--skip-build`。
- `rsync` **必带 `--delete`** —— vite 输出 hash 文件名，否则远端旧
  bundle 累积越来越大（当前模板里已带）。
- Relay 直接 serve `dist/`（`GHOSTTY_RELAY_STATIC_ROOT`），部署完
  **无需** 重启 relay。
- `index.html` 不带 hash，CDN / 浏览器易缓存 → `Cmd+Shift+R` 强刷或
  CDN 给 `index.html` 加 `Cache-Control: no-cache`。

## Relay 部署 (`relay/deploy.sh`)

- 默认只推 `server.py` + `systemctl restart`；推全目录用 `--all`。
- restart < 1 秒；已有 session 走 4408 / 网络错误 reconnect 自愈，
  几秒内全部回流。
- `/etc/ghostty-relay.env` **不会**被 deploy.sh 覆盖。`env.example`
  改了要 `ssh + sudoedit` 手动合并；代码默认值兜底，忘合并不会崩。
- 健康检查走 admin loopback（`127.0.0.1:18081`）：
  ```bash
  ssh root@<host> 'curl -s http://127.0.0.1:18081/{readyz,metrics}'
  ```
- Metrics 命名遵循 `ghostty_relay_<category>_<verb>_total`，新加
  endpoint 跟这个 pattern。
- `GHOSTTY_RELAY_UPLOAD_DIR=/tmp/ghostty-uploads` 在 systemd
  `PrivateTmp=true` 下实际隔离到 `/tmp/systemd-private-<uuid>/...`，
  service 重启即清。**不要**改成持久卷。

## 反代必坑：Nginx 默认 body size 1 MiB

`/api/upload/` location 必须 `client_max_body_size ≥ 上传上限`
+ `proxy_read_timeout`/`proxy_send_timeout ≥ 600s`。模板
`relay/deploy/nginx.conf.example` 已写好。Caddy 不限 body size，无需配。

## 反模式

- ❌ `--allow-public-bind` 让 relay 直接绑 `0.0.0.0`。正确：前置
  nginx/Caddy + relay 留 `127.0.0.1`。
- ❌ `git add -A` / `git add .`。`deploy.env` 是 gitignored 但
  `deploy.env.example` tracked，批量 stage 容易误带临时调试 / Token。
  一律 `git add <具体文件>`。
- ❌ 直接编辑 `/etc/ghostty-relay.env` 不同步 `env.example` — drift
  后下次看模板以为是真状态。

## 升级顺序：**agent → relay → web**

- 老 agent 不识别 `upload_ready` 控制帧 → fall through 到
  `forwardToTerminal`（裸 JSON 漏进 PTY，难看）。**先升级 agent**。
- 老 relay 收新 PATCH → 405，web client fall back 到 PUT 单 shot。
- 老 web client 不知道 `/api/upload/*` → 终端流照常工作，没上传按钮即可。

## macOS auto-resume

强退 / 重新构建替换后，上次处于 `.sharing` 的 surface 启动后自动重开
共享（**新** session token / 新 URL，不复用旧的）。

- 持久化：`~/Library/Application Support/com.mitchellh.ghostty/sharing-resume.json`
  存 `Set<UUID>`（surface id）。`SessionSharingController.setState` 单
  钩点：`.sharing` 时 add，`.idle / .error` 时 remove；过渡态
  （connecting / reconnecting / stopping）**不动** breadcrumb，所以
  reconnecting 中崩溃也能恢复。
- 恢复入口：`AppDelegate.applicationDidFinishLaunching` 末尾 dispatch
  async 扫描 → 命中 UUID 调 `surfaceView.resumeSessionSharingIfPossible()`
  → 内部读 `sharing.conf` + Keychain 拿 relay/token → 直接
  `startSharing`，**不弹** sheet。失败 / surface 不在的 UUID 通过
  `store.replace(resumed)` 清掉，下次启动不再尝试。
- 注意：`sharing-resume.json`（surface 维度）和 `sharing.conf`
  （relay/token/upload 偏好）是两份独立文件，**不要**混在一起改。
  resume 依赖 `sharing.conf` 有 token —— Keychain miss + 文件 token
  也空 → resume 返回 false，UUID 被清。
- ❌ 不要把"旧 session_id / agent_token"塞进 breadcrumb 来复用。
  relay 侧 TTL 一过 4408 / 4401，再 fallback 反而比直接新开复杂；
  当前 fork 已确认接受"重启即换 URL"语义。
