# Ghostty Web Client — Android 打包补遗

`vite + Capacitor 8` 工程,同时部署成浏览器版(`deploy.sh` 推 `dist/`)
和 Android APK(`build-and-deploy-apk.sh` 推 `apk/`)。父层运维约定见
[`../CLAUDE.md`](../CLAUDE.md)。这里只记 web-client 这一层不能从代码
直接读出来的硬约束。

## 环境硬约束

- **必须 JDK 17 或 21**(Capacitor 8 / AGP 8.x)。系统默认 JDK 26 会让
  `./gradlew` 失败,报错难懂。`build-and-deploy-apk.sh` 已自动 export
  JDK 21;手跑 gradle 必须先 `export JAVA_HOME=...`。
- Android SDK 默认在 `~/Library/Android/sdk`,Android Studio 装好后即就位。
- 见根 CLAUDE.md 同款坑:`HTTP_PROXY` 影响 gradle 远程依赖下载。

## WASM 必须手工拷,不要改 vite 配置

`ghostty-web` npm 包**不会**让 vite 自动打 `ghostty-vt.wasm`,因为它原本
期望 relay 在 `/ghostty-vt.wasm` 单独 serve(见 `relay/server.py`
`resolve_static_path` 的特判)。Capacitor APP 内没有 relay 兜底,加载会
404 → 终端起不来。

修复在 `package.json` 的 `android:copy-wasm`,`npm run android:build`
末尾会自动拷 `node_modules/ghostty-web/dist/ghostty-vt.wasm` →
`android/app/src/main/assets/public/`。

**反模式:** 把 wasm 放到 vite `public/`。会让 dist 里也带一份,跟
浏览器端 relay 上 zig 编出的 wasm 版本冲突,nginx 优先级一变就 mismatch。

## Release 签名 — keystore 不能丢

- `android/keystore/release.keystore` + `credentials.env` 是 gitignored
  的真实凭据,**不能 commit**。一律 `git add <具体文件>`,不要
  `git add -A`。
- alias `ghostty`,PKCS12,RSA-2048。**PKCS12 不支持单独 keypass**:
  `GHOSTTY_KEY_PASSWORD` 必须等于 `GHOSTTY_KEYSTORE_PASSWORD`,否则
  signing 报 wrong key password。生成 keystore 时如果分别设两个密码,
  keytool 会 warning 并忽略 keypass。
- 校验 APK 签名用 `apksigner verify --print-certs`,**不是** keytool —
  keytool 不识别 APK Signature Scheme v2,会报"不是已签名的 jar 文件",
  容易误以为没签。
- Android 不允许同 applicationId 用不同 signing key 升级。丢了 keystore
  ≡ 改 applicationId 发新 APP,或所有用户先卸载。每台要打 release 的
  机器都要有这套凭据;主开发机要离线备份。

## APK 分发架构

- 服务器路径约定:APK 是 web `dist/` 的 **sibling 目录**。
  - web: `<DEPLOY_PATH>/dist/`(`deploy.env` 的 `DEPLOY_PATH`)
  - apk: `<DEPLOY_PATH>/apk/app-release.apk`(`deploy.env` 的 `APK_REMOTE_DIR`)
- relay 端 endpoint:`GET /api/app/android`,默认路径
  `<static_root>.parent/apk/app-release.apk`,可被 `GHOSTTY_RELAY_APK_PATH`
  覆盖。源码:`relay/server.py:resolve_apk_path`。
- **两条鉴权路径,不可合并**:
  1. `Authorization: Bearer <user_token>` 直接下载 — 桌面浏览器 / curl 用
  2. `POST /api/app/android/grant` (Bearer) → 拿到 60秒 short token →
     `GET /api/app/android?dl=<short>` 浏览器原生 navigate — 移动浏览器用
  Why:华为/UC/in-app webview 拒绝 blob URL + `<a download>` 触发下载,
  唯一可靠方式是让浏览器原生跟随 `Content-Disposition`,所以必须给出
  一个不依赖 Authorization header 的 URL。short token 不绑定 user token,
  TTL 内可重复使用(浏览器 retry 友好),过期靠 `cleanup_loop` 每 5 秒清。
- 升级 APK **不需要重启 relay**(每次请求读盘)。
- **nginx basic auth 范围**:只挡 `location /`(web HTML 入口),
  `/api/` 和 `/ws/` 显式不挡(token 自带鉴权)。新加 location 时如果是
  公开 API 路径(token-based),**不要**继承 `/` 的 auth_basic;反之
  如果是私有 SPA 资源,需要显式 alongside `/`。曾被 fetch 卡 basic
  auth 弹窗坑过一次:症状是 APP 内 fetch 看起来"Failed to fetch",
  实则 URL 写错了路径误进 `/` location 弹 auth dialog WebView 处理不了。
- 升级顺序仍是父层 CLAUDE.md 规定的 **agent → relay → web**;APK 跟在
  web 之后,改 endpoint 协议时再考虑顺序。

## 文件名三处必须一致

APK 文件名硬编码在三个地方,改名要同步:

- `relay/server.py` 的 `APK_DOWNLOAD_FILENAME`
- `ghostty-web-client/src/main.js` 的 `anchor.download = "ghostty-sharing.apk"`
- 服务器磁盘上 `<APK_REMOTE_DIR>/app-release.apk`(由 `build-and-deploy-apk.sh` 决定)

注意服务器磁盘的文件叫 `app-release.apk`(gradle 出的默认名),
HTTP 下载呈现的文件名是 `ghostty-sharing.apk`(Content-Disposition 决定)。

## Capacitor 已知坑

1. `androidScheme: "https"` 让 APP 内 `location.origin === "https://localhost"`,
   `#backendBase` 默认 fallback 到这里 → **首次启动 APP 必须手填 relay URL**,
   之后 localStorage 记住。**有意保留**这个手填步骤(用户决定),不要再
   加 vite `define` / `server.url` 自动注入 — 之前尝试过,被回滚。
   配套坑:APP 内对 relay 的 fetch 永远是**跨 origin**(`https://localhost`
   → `https://<relay>`),Bearer 鉴权触发 CORS preflight。relay 端必须
   响应:见 `server.py` 的 `CAPACITOR_CORS_ORIGINS` + `_cors_headers_ctx`
   + handle_connection 顶部的 OPTIONS short-circuit。**新加客户端 fetch
   header 时**(非 `Authorization`/`Content-Type`),必须确认 preflight
   echo `Access-Control-Request-Headers` 已覆盖,或显式扩 Allow-Headers。

2. **APK 内"下载安装包"按钮**:走 grant 流程(`POST /api/app/android/grant`
   → `?dl=<short>` navigate),已真机验证。曾考虑直接用 blob URL +
   `<a download>`,但华为 / UC / in-app webview 拒绝触发下载,所以
   改成让浏览器原生跟随 `Content-Disposition`。短 token 60s TTL,可
   重复使用(浏览器 retry 友好),`cleanup_loop` 每 5 秒清过期。
3. 混合内容:APP 是 https,relay 必须 https。明文 http / 没被 NSC
   trust 的自签证书都会被 WebView 拒,wss 同样连不上。**当前**用自签
   证书 + NSC pin 解决,见下面 TLS 段。
4. 移动端 IME 路径(`src/main.js` 接近 2240 行的 `mobileInput` 段:
   `compositionstart/end` + Enter/Tab/Backspace 单独 handler + sticky
   Ctrl/Alt modifier)已完整,Capacitor WebView 复用浏览器移动端代码,
   **除非真机测出问题,别动这段**。

## TLS:全自签证书 + NSC pin(主方案,letsencrypt 已弃)

历史:首版双证书方案 — letsencrypt 给域名 + 自签给 IP 直连。后切**全
自签**,letsencrypt 弃用。理由:

- 部署所在的网络环境未做 ICP 备案,80 端口对外的 HTTP 访问被云接入层
  前置拦截(连接成功但 server 不回响应 / 直接返回 403),certbot
  HTTP-01 challenge 拿不到 200。
- HTTP-01 / TLS-ALPN-01 都依赖 80 / 443 端口对外可达,无解。
- DNS-01 是唯一可走路径,但需要 DNS provider API token + 长期维护,
  对一个内部 / 小团队工具不值得。
- 经验证:实际部署的中间层在非标 HTTPS 端口上**不做 SNI inspect**,
  自签证书域名访问正常工作(浏览器装 trust anchor 后无警告)。

当前架构:

- 服务器自签证书(nginx 配置里 `ssl_certificate` 指向那对 `.crt/.key`,
  路径写在 ops 记录里,**不在 git**),SAN 同时含 `DNS:<域名>` 和
  `IP:<服务器 IP>`,10 年有效期。用 openssl config 文件方式生成
  (老版 openssl 不支持 `-addext`)。
- nginx **单 server 块**(`server_name _; ... default_server`),
  域名 + IP 都命中同一份自签证书。letsencrypt 文件保留 + certbot cron
  注释(以后想切回备案路线随时可恢复),但 nginx 不再引用。
- APP 端:`res/raw/ghostty_ca.pem` 内置自签证书,
  `res/xml/network_security_config.xml` 对域名 + IP 两个 host 声明
  trust anchor。APP 域名访问 + IP 访问都通过 NSC pin 验证。
- 桌面浏览器:首访"未知颁发者"警告,点继续浏览器记住例外。开发者机器
  可装 trust anchor 跳过警告:
  - macOS:`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <path-to-ghostty_ca.pem>`
  - Linux:`cp ghostty_ca.pem /usr/local/share/ca-certificates/ && update-ca-certificates`(Debian/Ubuntu);RHEL 系用 `update-ca-trust`
- 续期:**10 年**到期前重生成 cert + 重打 APK + 推 nginx + 用户重装。
  日历记到期前几个月提醒即可。
- IP 变更:必须重生成证书(SAN 含 IP),否则 NSC pin 失效。**没有自动**
  兜底机制,服务器迁移要走完整流程。

**反模式 / 失效推论**:

- 写 `WebViewClient.onReceivedSslError()` 来"忽略证书":Google Play 拒,
  WiFi MITM 风险,**远比 trust anchor pin 不安全**。
- 重新启用 letsencrypt 又不做 ICP 备案:续期早晚再坏,等于把今天踩
  的坑重新踩一遍。要么走 DNS-01 持续维护 API token,要么留自签。
- 之前推测"中间层在非标 HTTPS 端口做 SNI inspect" — **错的**,经验证
  浏览器域名访问完全 OK。`curl LibreSSL` 偶发 SSL_ERROR_SYSCALL 是
  macOS 系统 curl 跟某层 TLS 实现的 niche 兼容性问题,不影响生产。

## ghostty-web render loop monkey-patch

`src/main.js` 的 `installOnDemandRender` 在 `terminal.open()` 后立刻
覆盖实例的 `startRenderLoop` + wrap `write/clear/reset/paste` + 订阅
`onScroll/onSelectionChange/onResize`,把上游无条件 60 Hz rAF 改成
"state 真变了才 schedule 一帧"的 on-demand 渲染。配套 `schedulePaint`
做 rAF dedupe,`disposeTerminal` 走 `cancelScheduledPaint`。

**Why**: ghostty-web v0.4.0 dist 的 `startRenderLoop` 没 dirty 检测、
没 already-running guard,即使 `cursorBlink: false` + 内容静止仍 60 Hz
烧主线程,移动端电量/发热明显。fork 上游维护成本高,monkey-patch 全
在我们仓库里 review/审计成本低,且 `onScroll`/`onSelectionChange` 是
公开 emitter API,稳定性 OK。

**升 ghostty-web 包时必查**(任一失败说明 patch 不再兼容,需重审):

```bash
# 1. 公开 emitter 仍齐全 (我们订阅的三个)
grep -E "onScroll|onSelectionChange|onResize" node_modules/ghostty-web/dist/index.d.ts

# 2. wrap 的方法仍是原型方法 (不是 arrow-bound 实例属性)
grep -E "^    (write|clear|reset|paste)\(" node_modules/ghostty-web/dist/index.d.ts
```

**反模式**: 看见 `installOnDemandRender` 多此一举就删掉。`processMouseMove`
改 hover 状态无公开 emitter,terminalMount 上的 capture-phase mouse/touch
listener 作为唯一兜底,**不要**为了 "lint clean" 把它们也删了。

## 低分辨率渲染设置(`#lowResRender` 3 档下拉)

settings 页 `<select>`,关联 `LOW_RES_RENDER_KEY`,4 档:`off` / `light`
(cap=2.0) / `balanced` (cap=1.5) / `strong` (cap=1.0)。选中非 `off`
时把 `terminal.renderer.devicePixelRatio` cap 到对应值(min(native,cap)),
canvas backing 像素总量随 cap²/native² 线性降。默认 `off` 保持原生 DPR
不影响桌面用户感知。

**localStorage legacy 迁移**: 这个 setting 早期是 checkbox, 存的是
"0"/"1"。新版仍用同一 key,`getInitialLowResLevel()` 把 "1" 映射成
"balanced",空/"0"/未知值 → `off`,保证升级用户的"开启"状态不被默认
吞掉。

**实现要点**:

- `ITerminalOptions` 不暴露 `devicePixelRatio`(dist Terminal 构造
  renderer 时只透传 fontSize/fontFamily/cursorStyle/cursorBlink/theme)。
  必须 instance-level patch:`terminal.renderer.devicePixelRatio = X` +
  `terminal.renderer.resize(cols, rows)`(触发 ctx.scale 重算 + canvas
  backing 重分配)。
- `installOnDemandRender` 末尾 `applyRendererDpr(true)` 在 dist 首帧
  render **之前**应用,避免一次性多余的 native-DPR backing 分配。
- 切换 setting 时除 `applyRendererDpr` 外**必须再跑** `applyDesktopWidthSize`:
  desktop-width 容器宽度依赖 `currentCellWidthPx` 推导, cap 后 canvas
  backing 大小变了, 但 cellW 是稳定的(metric.width × cols × DPR /
  DPR / cols) — 重跑确保布局缓存刷新。

**Latent bug 历史**: `currentCellWidthPx` 原本读 `window.devicePixelRatio`
推算 cellW, cap 上线后 `renderer.devicePixelRatio ≠ window.devicePixelRatio`
会让宽度算错(canvas.width/window.DPR/cols 得 ≈ 真实 cellW 的一半 →
desktop-width 容器被严重低估 → 右侧列被裁), 同 commit 已修成读
`terminal.renderer.devicePixelRatio`。**未来从 canvas.{width,height}
反推 CSS px 时一律读 renderer 的 DPR 字段, 不读 window**。

**dist 内部小坑**: `Terminal.resize`(行 2422) 在 `renderer.resize` 之后
又用 `metric × cols` 覆盖 `canvas.width` **不乘 DPR**, 但下一帧
`renderer.render`(行 1401) 检测尺寸不匹配会自动调 `renderer.resize` 修正
+ force redraw。结果是每次 grid resize 会多一次"错-self-heal"循环,
对 cap DPR 无影响(self-heal 用的也是实例 `devicePixelRatio` 字段)。
升包时注意确认这个自愈逻辑还在。

## Layer-isolation wrapper: `.terminal-canvas-host`

`ensureTerminal` 在 `terminalMount` 内部 append 一个 `<div
class="terminal-canvas-host">`,带 `will-change: transform` +
`transform: translateZ(0)`,然后把 dist `terminal.open(canvasHost)`
指向这个 wrapper(**不是** terminalMount 本身)。dist 的 canvas +
helper textarea 都创建在 wrapper 里。

**Why**:WebView GPU compositor 给 `transform`-promoted 元素分配独立
layer texture。terminalMount 自带 desktop-pan 的 `translate3d(...)` →
它有自己的 layer。如果 canvas 直接挂 terminalMount 下,canvas 像素
画进 terminalMount 的 layer texture。

HarmonyOS / ICL-AL20 WebView 实测:这个 layer texture **在 canvas
被 removeChild 后不会立刻 release**。disposeTerminal → ensureTerminal
新建的 canvas 插回 terminalMount → 走同一个 layer slot →
compositor 残留 pre-dispose canvas 的像素,新 canvas 的 fillRect
落地 ctx backing buffer 但 layer texture 滞后 → 用户看到"两个
terminal 叠在一起"。**只有 `location.reload()` 这种整页 navigation
触发 layer tree 整体重建**才能彻底清。

修复:把 canvas 隔到自己的 layer。`canvasHost` 因为 `will-change`
+ `translateZ(0)` 拿到独立 layer,canvas 像素画进 canvasHost 的
layer。disposeTerminal 的 `terminalMount.innerHTML = ""` 销毁
canvasHost → 它的 layer 直接 release → 下次 ensureTerminal 新建
canvasHost 拿到全新 layer texture,等同 reload 的关键步骤但用户
无感。

**不变量**:

- terminalMount 自身**不要**重建 —— 大量 listener
  (`touchstart/move/end/cancel/click/pointerup`)和 ResizeObserver
  都直接 attach 在 terminalMount 上;重建会丢这些,需要把它们全部
  搬进一个 `installMountListeners(mount)` 函数再重新挂,改动面太大,
  现在 wrapper 方案不需要动这些。
- canvasHost 必须**继承** terminalMount 的 width/height
  (`width:100%; height:100%`),否则 desktop-width 容器宽度 / 移动端
  viewport 适配会跟 canvas 不一致。
- 别给 canvasHost 加 `position:absolute` —— dist 的 helper textarea
  是 `position:absolute`,它会从 wrapper 找 positioned ancestor,
  目前找到 `.terminal-host`(index.html 设 `position:relative`),
  保持这个就好。
- canvas 自身**不要**额外 `will-change`/`transform`。再 promote
  一层 layer 是浪费(canvasHost 已经 promote 了),而且会跟 dist
  内部 canvas style 写法冲突。

**反模式**:

- ❌ 把 `terminal.open(canvasHost)` 换回 `terminal.open(terminalMount)`
  "省一个 div"。会直接复活"切后台再回来文字重叠"的 bug。
- ❌ 在 disposeTerminal 加 `canvasHost = null` 或专门变量管理。
  canvasHost 是 ensureTerminal 局部变量,wrapper 引用走
  `terminal.element`,terminal.dispose() 已经清干净,GC 处理释放。
  额外 module-level 引用会阻 GC。
- ❌ 给 canvasHost 加更多 promotion hint(`backface-visibility:hidden`
  / `perspective` 等)"保险一些"。promotion 本身是 boolean,够了就行,
  叠加只增 GPU 内存不增效果。

## Stale canvas backing: forceAll 路径

`schedulePaint(force=true)` / `scheduleFullPaint()` 在三个特殊点使用,
对抗 "canvas DOM 完好但 GPU texture 内容是 stale/garbage" 这条
dist 自愈不覆盖的盲区。

dist 内部 dirty-row 优化默认只画 `wasmTerm.isRowDirty(y)` 返回 true
的行,其他行保留 canvas 上现有像素。这在「上一帧画的内容 = 当前 GPU
backing 内容」时正确, 但在以下场景**不正确**:

1. **Android WebView 后台被回收**: APP 切到其他应用 + 待一会, OS 主动
   evict GPU texture (canvas DOM / 维度都完好, dist self-heal 不触发,
   因为它只 check canvas.{width,height} 是否 = cols × metric × DPR)。
   切回来时 visibility handler 必须 `scheduleFullPaint()` 强制把当前
   wasmTerm 全画一遍, 否则非 dirty rows 显示 GPU 上的随机像素 → 用户
   看到 "文字重叠"。
2. **Snapshot 重锚**: agent push 的 snapshot 是完整的可视区域内容,
   即使其中部分 row 跟 wasmTerm 当前状态相同 (静态边框 / 状态栏),
   也必须全画 — 因为 GPU backing 可能 stale。
3. **install / DPR 切换**: `renderer.resize` 调用 `canvas.width = X`
   会 reset ctx state + fillRect 背景, 把之前 forceAll=true 的 render
   输出抹掉; 后续 schedulePaint(force=false) 看到 wasmTerm 几乎都
   non-dirty (snapshot 还没来), 不画 → 用户看到纯背景色。 install
   末尾 + applyRendererDpr 末尾必须 `scheduleFullPaint()`。

**调用约定**:

- `schedulePaint()` (force=false 默认): 日常 write / scroll / hover
  事件用, dirty-only 优化, 廉价
- `scheduleFullPaint()` (force=true): 上述三个特殊点。开销 = 整屏
  fillRect + 全部 row 重画, cap DPR 1.5 时整屏成本可接受

**dedupe 行为**: `schedulePaint(true)` 跟 `(false)` 共享同一个
`scheduledPaintFrame` rAF; force flag 是 upgradeable - true 永远覆盖
false。同一帧多次混合调用最终走 force=true 路径。`cancelScheduledPaint`
同时清 flag。

### `forcePaintUntil` 滑动窗口(reconnect/resume 防文字重叠)

只在三个点 force 不够。**实测**:APP 切到其他应用待 1-5 分钟回前台后,
visibility resync 把 socket close(4000) → reconnect → server 重新发
`hello → replay_backlog (~256 frames) → screen snapshot` 序列;snapshot
末尾 `scheduleFullPaint` 抹一次 GPU,但**之间**的 backlog binary frame
每条都走 `terminal.write` wrap → `schedulePaint(false)` 只画 dirty row,
dist v0.4.0 内部 dirty tracking 在快速 burst write 下偶尔会漏标已被新
内容覆盖的 row → canvas 上残留前一帧像素 → 用户看到"文字重叠"
(spinner 跟旧 buffer 的字符叠在同一行)。

**修复**: module-level `forcePaintUntil` 时间戳,`startForcePaintWindow(reason)`
设 `Date.now() + FORCE_PAINT_WINDOW_MS` (默认 **2500 ms**)。`schedulePaint`
顶部 `if (force || Date.now() < forcePaintUntil) scheduledPaintForce = true`,
所以窗口内任意 `schedulePaint()` 都自动升级成 forceAll。窗口启动点:

- `socket.addEventListener("open", ...)` —— 覆盖 reconnect 后 backlog 序列
- `document.addEventListener("visibilitychange", ...)` 的 `visible` 入口 ——
  belt-and-braces:reconnect 路径有 100-200 ms 延迟,这之间的写仍走
  forceAll

**为什么 2500 ms**:实测一次 hello → 256 frame backlog → snapshot 在
3G/4G/弱 WiFi 下大概 800-1800 ms 完成,2500 ms 留 700-1700 ms 头部裕量。
再长就开始把日常使用拖进 forceAll,DPR cap 的省电收益打折。

**为什么不每帧都 force**:`renderer.render(wasm, true, ...)` 整屏 fillRect
+ 全 row 重画,DPR=1.5 时一帧 ~3 ms,DPR=2.0+ 起步 6-8 ms。日常
write throttle 50/80 ms 时还能压在 20 Hz,但若密集 burst (`ls /usr` 这种
快速吐字符) 每帧都 forceAll 就把电省回去了。

### hello / appearance / resize / screen 控制帧路径都加 scheduleFullPaint

belt-and-braces,即使 force window 没启动也兜得住:

- `case "hello"` 末尾 —— resize → self-heal 之间一帧的 half-render
- `case "resize"` 末尾
- `case "appearance"` 即 `applyAppearance` 末尾 —— `renderer.setTheme` 不
  invalidate dist dirty tracking,不 force 的话 clean row 仍用旧主题色
- `case "screen"` 即 `applyScreenSnapshot` 末尾(原本就有)

### forceAll 帧再加 `renderer.clear()` + `scrollToBottom`

`schedulePaint` rAF 内,如果 forceAll=true,先 `renderer.clear()`
做整屏 fillRect,再调 dist `renderer.render`。同时若 `viewportY !== 0`
顺手 `scrollToBottom()` reanchor 到底。

**Why**:

1. **HarmonyOS / ICL-AL20 WebView GPU compositor 缓存**:dist 的
   `renderLine` 是 per-row fillRect 清的(`ctx.fillRect(0, rowY, cols*w,
   h)`),这些 rect 写进 2D context backing buffer 没问题,但 HarmonyOS
   WebView 的 compositor 缓存 canvas layer texture 时,**per-row 的小
   fillRect 不触发完整 layer invalidation** —— 用户看到 "两个 terminal
   叠在一起"(pre-suspend 的内容 + reconnect 后的 snapshot 同时可见),
   连 forceAll 都救不回。一次整屏 fillRect (`renderer.clear()` 就是
   `fillRect(0, 0, canvas.width, canvas.height)`) 能强制 compositor
   把整个 layer 标 dirty,per-row 写入才会落地。
2. **viewportY > 0 时 dist render 混画 scrollback + active**:dist
   render line 1431-1438 在 `g > 0`(viewportY)时,visible rows 上
   半截读 `scrollbackProvider.getScrollbackLine(...)`,下半截读
   `wasmTerm.getLine(t - viewportY)`。如果 visibility resync 期间
   smoothScrollTo 还在跑/有残留 target,forceAll 也会画出"上面是历史
   scrollback 下面是新 snapshot 的 active"这种重叠效果。tick 内强
   reanchor 是最直接的兜底。

**成本**:整屏 fillRect 在 cap DPR 1.5 时 ~1-2 ms,只在 forceAll 帧
触发(force window 期或显式 `scheduleFullPaint`),日常 dirty-only
write 路径不受影响。

**反模式**:

- ❌ 在所有 `schedulePaint` 帧都 `renderer.clear()`。日常 dirty-only
  paint 本来是 ~50 µs / 帧的开销,前面加个 1-2 ms 整屏 fillRect 直接
  把电量优势打折。只在 forceAll 帧加。
- ❌ 把 reanchor 改成 `terminal.scrollToBottom()` 无条件调用(去掉
  `viewportY !== 0` guard)。dist scrollToBottom 内部已有同款 guard
  (line 2594),但同时还会 `showScrollbar`,触发 fade-in rAF 链,空跑
  浪费。

### scheduleFullPaint 反模式

- ❌ 把所有 `schedulePaint()` 改成 `scheduleFullPaint()`。日常 write
  路径每帧 forceAll 会让 cap DPR 的功耗优势打折; 只在上述三个点
  force 即可
- ❌ 在 `terminal.write` wrap 内 force。dist's dirty tracking 在
  write 路径下**通常**是准确的 (wasmTerm dirty 标记跟 write 的内容
  一致),GPU backing 是 fresh (上一帧的 render 输出),强 force 是浪费。
  reconnect/resume race 用 `forcePaintUntil` 窗口处理,不要污染 write
  wrap 本身
- ❌ 把 `FORCE_PAINT_WINDOW_MS` 拉到 5s+ "保险一些"。窗口期内 cap DPR
  失效,长 burst 用户会感到一阵子轻微发热

## Desktop-width pan momentum

src/main.js 在 touchend 后启动短期 rAF 链 (`panMomentumStep`),按
iOS 风 friction=0.95/frame 衰减,~800ms-1s 自然停。**只覆盖 desktop-width
pan 的 X+Y**,不动 terminal scrollback (scrollback 走 dist smoothScroll
自带的 ease-out,不要重复)。

**关键决策与边界**:

- **边界行为 = 立即停**:`applyDesktopPan` 内部 clamp 到 [0,max],
  step 内检测到 `desktopPanX === prev && delta !== 0` 立刻 cancel。
  不做 rubber-band 也不把 momentum 转移到 scrollback (用户实测中
  "弹回"和"穿过边界继续滚"都会引起失控感)。
- **任何新 touchstart 必先 cancelPanMomentum**:同一根手指再次落屏时,
  momentum 必须停在落点,否则 touchmove 的 dxStep 算在过期 baseline
  上 → 视觉跳变。
- **syncDesktopWidthMode 内主动 cancel**:toggle desktop-width 时
  momentum 仍在飞 → 一帧后 self-heal (撞 max=0 停),但显式 cancel
  避开 `desktopPanX=0 → applyDesktopWidthSize rAF 内 panToBottom`
  这条 race。
- **disposeTerminal 内 cancel**:terminalMount.innerHTML 已 wipe,
  momentum step 操作的 style.transform 落在 stale node 上无意义。
- **velocity 上限 `PAN_MOMENTUM_MAX_INITIAL_VELOCITY = 4 px/ms`**:
  防止 pointer-coalescing 把两个相邻事件合并成"1ms 内移动 30px"的
  虚假高速,seed 一个能 fling 半个屏幕的 momentum。
- **dt 上下限 `[1, 50]ms`**:背景 tab / GC pause 之后第一帧 dt 可能
  几百 ms,不 cap 的话 momentum 一帧飞过整个 pan 范围。
- **momentum rAF 只动 `terminalMount.style.transform`**,**不调
  schedulePaint** —— translate3d 走 compositor 不需要 canvas 重绘,
  跟 on-demand render 完全互不影响。

**反模式**:

- ❌ 看 `panMomentumStep` 里的 friction 觉得是上次坏代码留下的常驻
  rAF 而删掉。它是 touchend 后才启动、衰减后自停的短期 rAF,跟
  startRenderLoop 完全不同。
- ❌ 给 terminal scrollback 也加 momentum。scrollback 不归我们管,
  动它要侵入 dist。
- ❌ 调 friction 接近 1.0 ("更顺滑"):会让 momentum 跑十几秒,用户
  按不停。0.95 是 iOS 实测值,别动。

## 上传排队 + 401 自动重连重发

`src/main.js` 的 `enqueueUploads` 不再直接 fail-closed。drop / paste /
launcher 触发的文件统一进 `queueUpload`,根据 socket 状态决定:

- `isUploadReady()` (`activeSession + socket OPEN`):立即调 `uploadManager.start`
- 没就绪:推 `pendingUploads`,弹一个 **pending** kind 的 toast "等待
  重新连接...",启动 1 s sweep。socket onopen 调 `flushPendingUploads`
  draining 出去,同一 `toastId` 复用 → 用户看到 toast 文案从"等待重连"
  morph 成"上传中"。
- 单个文件 deadline = 入队时刻 + `UPLOAD_PENDING_TIMEOUT_MS = 15_000`。
  超时 sweep 把它变 error toast "连接未恢复,已放弃上传"。

`startSingleUpload` 捕获 `upload.js` start() 抛的 `{ code: "unauthorized" }`
(init 收 401 → relay 端 session.expires_at 已过):
- 关 socket(`close(4000, "upload_auth_resync")`)→ 触发 `scheduleReconnect`
  → 重连后 server 重新发 hello,session 在 relay 那边重新 active
- 把 file 重新入 `pendingUploads`(同 toastId,文案 morph 成"会话失效,
  正在重连..."),attempt+1
- `UPLOAD_AUTH_RETRY_LIMIT = 1` —— 401 自动重试**一次**,再 401 就
  fail 成 "会话已过期,请重新选择会话"。防 token 真的死掉时无限循环。

队列清空入口:
- `leaveTerminalView`(用户主动退到 sessions 列表)→ "已退出会话,上传取消"
- `connectToSession` 切到**不同** session.id → "已切换会话,上传取消"
- 同 session reconnect(`scheduleReconnect → connectToSession`,同 id)
  **不**清,这样 401 重连后 flush 还能把 file 接上

**Why**:之前 enqueueUploads 在 socket 没 OPEN 时直接弹"未连接,请先
连接到会话再上传",体感是文件凭空消失;切回 APP 后台后 visibility
resync 主动 `socket.close(4000, "visibility_resync")` 会留一个秒级
window,paste / drag 经常踩到。401 同理 —— relay session 过期但
WS 还没收到 4408,upload init 就 401,toast "未授权"用户没头绪。

**反模式**:
- ❌ `enqueueUploads` 退回成 fail-closed。"socket 没 OPEN 就拒"的体感
  比"等几秒"更差,尤其在弱网。
- ❌ 把 `UPLOAD_PENDING_TIMEOUT_MS` 调到分钟级。用户已经在等,15s 是
  "短到能让人放弃重试的容忍",再长就会怀疑 APP 卡死。
- ❌ `UPLOAD_AUTH_RETRY_LIMIT > 1`。401 真不是 transient(token 死了就
  死了),多重试无意义,只让"会话失效"toast 闪烁更多次。
- ❌ 在 `upload.js` start() 内对 401 直接 toast "未授权"。它必须 throw,
  让 main 这层把 401 跟 socket 状态联动起来 —— upload.js 不知道 socket
  在哪。
- ❌ 把 PUT/PATCH 401 也加进自动重试。PUT/PATCH 401 极少见(session 在
  init 之后才过期),即使发生,中途文件已传一半,重传整个文件不值得。
  现状是 PUT/PATCH 收 401 走 readablePutError → "上传失败 (401)",
  用户手动重试即可。

## `backendBase` 拼接必须用 URL.pathname 覆盖,不能字符串拼接

`src/upload.js` 的 `buildUploadURL` 用 `new URL(base, location.origin)`
+ `url.pathname = "/api/upload/..."` 覆盖,跟 `src/main.js` 的 `apiURL`
行为一致。**禁止**回退成 `` `${backendBase}/api/upload/init` `` 字符串
拼接。

**Why**:用户在 settings 里填的 `Backend URL Base` 末尾经常带一个 `/`
(`https://example.com:28443/`),字符串拼接会出 `https://example.com:28443//api/upload/init`。
nginx HTTP/2 在 ICL-AL20 / 鸿蒙等 HarmonyOS WebView 路径下**不**
`merge_slashes` 就把 `//api/upload/init` 原样转发给 upstream,relay 的
`handle_connection` 路由匹配走 `path == "/api/upload/init"`,**双斜杠
不匹配** → fallthrough 到 `serve_static` → 返 9 字节 plain text
`b"not found"`(`server.py:2291`),前端 `JSON.parse("not found")` 失败 →
`readableInitError` 兜底成 "服务器拒绝 (404)",用户看了一头雾水。

诊断步骤:线上 relay nginx `/var/log/nginx/access.log` 一行就能确认
请求 path 形状:

```
POST //api/upload/init HTTP/2.0  404 9
                    ^^ 双斜杠
                                       ^^^ 9 字节 = "not found" plain text
```

**反模式**:

- ❌ "末尾斜杠让前端 trim 掉就行"。trim 是治标,buildUploadURL 治本,
  以后再加新 endpoint 也不会复现这个坑。
- ❌ "让 nginx `merge_slashes on` 解决"。它在 HTTP/2 + 部分 WebView UA
  下不生效,且不是所有部署都能改 nginx 配置(比如自建反代),客户端
  归一化更可靠。
- ❌ 关闭 `buildUploadURL` 的 `url.search = ""` / `url.hash = ""` 清空。
  虽然 backendBase 一般不带 query,但 `apiURL` 也清,保持一致避免
  reviewer 困惑。

## 远端是 Linux 的小坑

- 校验文件 sha 用 `sha256sum`,不是 macOS 的 `shasum`。
- relay 服务器在 Linux,本地脚本里要给远端运行的命令一律按 Linux 习惯写,
  不要假设 BSD coreutils。
