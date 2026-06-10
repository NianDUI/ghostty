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

## Web OTA (`/api/web/bundle` + Capacitor `setServerBasePath`)

APK 出去之后还能把 `dist/` 单独热更,不用让用户重装 APK。两块:zip 在
服务器,Capacitor `WebView` plugin 在 APP 端做路由切换。

- 服务器布局:**`dist.zip` 也是 `dist/` 的 sibling**,跟 `apk/` 平级。
  - `deploy.sh` 自动在 `web-bundle/dist.zip` 生成并 rsync 到
    `<DEPLOY_PATH>.parent/web-bundle/`。**zip 内容 sha256** 写进
    `dist/manifest.json`(同一次 deploy 里 zip 字节就是 manifest 里
    的 `sha256`,APP 端校验靠这个)。
- relay 端 endpoint:
  - `GET /api/web/manifest.json`(公开):返 `{webVersion, sha256,
    sizeBytes, bundleUrl, builtAt, available}`,APP 用它决定要不要更新。
  - `GET /api/web/bundle`(**Bearer-only**,不走 grant flow):APP 内
    `HttpURLConnection` 直接附 token header 下载,不需要 mobile-browser
    nav 那套 short-token,所以只留一条鉴权路径。源码 `resolve_web_bundle_path`,
    可被 `GHOSTTY_RELAY_WEB_BUNDLE_PATH` 覆盖。
- APP 端用 Capacitor 8 **内置** `WebView` plugin:
  - 自写 `GhosttyWebUpdate` 只做"下载 + sha256 + 解压到
    `filesDir/web/<version>/`"。
  - 路由切换 = JS 调 Capacitor 内置 `WebView.setServerBasePath({path})` +
    `persistServerBasePath()`,**不要**自己重写 `WebViewAssetLoader`。
  - 持久化由 Capacitor 写 `SharedPreferences("CapWebViewSettings")` 的
    `serverBasePath` 完成,APP 启动时 `Bridge.attachWebView` 自动读取
    并应用(`Bridge.java:295` 一带)。
- APK 升级会**自动重置** web basePath:`Bridge.isNewBinary()` 检测
  到 versionCode/Name 变化,直接 `editor.putString(CAP_SERVER_PATH, "")`。
  所以发新 APK = web 退回 APK 内置版本,然后用户可以再下载更新版的 web。
- 同 origin (`https://localhost`):APK 内置 vs OTA 版本走的都是这个 origin,
  **localStorage 不会丢**(token / 设置项跨升级保留)。

**反模式**:

- ❌ 自己写 `WebViewAssetLoader` + `BridgeWebViewClient.shouldInterceptRequest`。
  Capacitor 8 已经原生支持,重复造轮子还破坏官方 reset 行为。
- ❌ 用 file:// origin 装载 OTA 资源。**必须**走 Capacitor 路由保持
  `https://localhost`,否则 localStorage scope 不一致,token / 设置全丢。
- ❌ 把 OTA 的"当前版本"存 localStorage。APK 升级后 Capacitor 自动 reset
  basePath 但 localStorage 还在 → 版本号跟实际运行不一致。**必须**让
  plugin 读 basePath 里的 `.version` marker(`getLocalWebVersion`)。
- ❌ 后台 auto-download。运营商流量贵,**只有**用户手动点"下载并安装
  Web 更新"才下载。
- ❌ sha256 用 dist 文件树哈希(原方案)。zip 直接哈希 zip 字节,APP
  下完就能直接校验。

### 强制升级 APK 的两条触发路径

老 APK + 新 web bundle 是危险状态(plugin 方法可能没有 / NSC 改了 /
新 manifest 字段读不到)。两个独立 floor,谁高谁说了算:

1. **`GHOSTTY_RELAY_MIN_APK_VERSION_CODE`(env var, ops 用)**
   - 路径: SSH 到 relay 改 `/etc/ghostty-relay.env` + `systemctl restart ghostty-relay`
   - 用途: **运营层紧急下架** —— 比如发现已发布 APK 有严重漏洞 / 跟新 relay
     协议不兼容,要立刻挡住所有低版本用户,不等下次 web deploy
   - 不要日常用,改完容易忘记跟 repo 同步

2. **`ghostty-web-client/MIN_APK_VERSION_CODE`(repo 文件,开发用)**
   - 路径: 改文件 + commit + `./deploy.sh`,值会写进 `dist/manifest.json` 的
     `requiredApkVersionCode`
   - 用途: **跟 native 改动同 commit 提**。改 `android/` 下 Java/Manifest/build.gradle
     且新 web bundle 依赖该改动时,bump 到当前 commit 的
     `git rev-list --count HEAD + 1`(下一次 build APK 的 versionCode)
   - 走 repo 评审,不依赖人记忆

**前端逻辑**(`main.js`):
```
effectiveMin = max(apkVersionInfo.minVersionCode, webVersionInfo.requiredApkVersionCode)
local < effectiveMin → apkForceModal 全屏挡 UI
```

**bump 决策表**:

| 改动 | bump `MIN_APK_VERSION_CODE`? |
|------|------------------------------|
| 纯 `src/*.js` / `index.html` / CSS | ❌ 不 bump |
| 升 ghostty-web 等纯 JS 依赖 | ❌ 不 bump |
| 改 Java/Kotlin plugin 但 web 不调用新方法 | ❌ 不 bump(老 APK 仍能跑当前 web) |
| 改 plugin 且 web 调用新方法 | ✅ bump |
| 改 NSC / AndroidManifest / build.gradle | ✅ bump |
| 换 keystore / applicationId | ✅ bump(其实必须先卸载,bump 是兜底通知) |

**反模式**:

- ❌ 不该 bump 时 bump(纯 web 改动)。老 APK 用户被无谓挡住,要花流量重装。
- ❌ 该 bump 不 bump。OTA 下来新 web 调老 APK 没有的方法 → 卡死,用户只能
  清数据 / 重装,Web 端能修但需要先卸载 APK,UX 很糟。
- ❌ 同时改 env var 和 repo 文件。一个就够,语义重叠反而 reviewer 困惑;
  非紧急场景固定用 repo 文件那条路径。

## APK 文件名:两处必须一致

- 服务器磁盘上 `<APK_REMOTE_DIR>/app-release.apk`(gradle 默认名,
  `build-and-deploy-apk.sh` 决定)
- `relay/server.py` 的 `APK_DOWNLOAD_FILENAME = "ghostty-sharing.apk"`
  (Content-Disposition 决定浏览器呈现的下载文件名)

main.js 改 grant flow 后**不再**自己 set 下载文件名(走
`window.location.href = downloadURL.toString()`,浏览器跟随服务器
Content-Disposition),所以前端没有第三处。

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

2. 混合内容:APP 是 https,relay 必须 https。明文 http / 没被 NSC
   trust 的自签证书都会被 WebView 拒,wss 同样连不上。**当前**用自签
   证书 + NSC pin 解决,见下面 TLS 段。
3. 移动端 IME 路径(`src/main.js` 接近 2240 行的 `mobileInput` 段:
   `compositionstart/end` + Enter/Tab/Backspace 单独 handler + sticky
   Ctrl/Alt modifier)已完整,Capacitor WebView 复用浏览器移动端代码,
   **除非真机测出问题,别动这段**。

(APK 内"下载安装包"按钮走 grant flow,详见 "APK 分发架构" 段。)

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

## GPU layer texture: APP 必须 reload,桌面 dispose 即可

**Bug 本质**: HarmonyOS / ICL-AL20 WebView 的 GPU compositor 缓存
canvas layer texture, **只对整页 navigation 释放**。任何 DOM 内
`disposeTerminal + ensureTerminal` 重建都会让新 wrapper 复用旧
layer slot → 用户看到两份甚至更多 session 的内容叠在一起。
Visibility transition 期间 paint 还会被合并进缓存层,每次切走切回
累积一层 stale frame —— "旧那层是更早 visibility 往返时的画面"
就是累积效应。

### 实测在 ICL-AL20 上无效的修复尝试(都不要再试)

1. `schedulePaint(force=true)` / `renderer.clear()` 整屏 fillRect ——
   2D context backing 干净,但 compositor 把它合在缓存层之下/之上
2. Layer-isolation wrapper `.terminal-canvas-host`(`will-change` +
   `translateZ(0)`)—— 给 canvas 独立 layer 期望 removeChild 释放,但
   鸿蒙 WebView 不立刻 release
3. `disposeTerminal` 在 visibility handler 同步入口立即销毁 wrapper —
   logEvt 验证执行了,ensureTerminal 创建了全新 canvasHost,但截图
   仍能看到两层 snapshot 同时可见

### APP 内走 reload / navigation 的入口

1. `document.visibilitychange` visible(APP 切回前台)→ `location.reload()`
2. `<button class="session">` click(launcher 列表点 session)→
   `switchToSession()` 调 `location.assign("?session=<id>")`
3. `performAppReload()`(设置页"保存并刷新"按钮 / launcher 两指下拉
   手势)→ `location.reload()`,跟 layer bug 无关,是用户主动 UX 兜底

**包装层只在 click / visibility / 用户 reload 入口加**,不要把它
移到 `connectToSession` 里 —— 后者还被 popstate 路由 / scheduleReconnect /
deep-link boot 调用,这些路径已经在新文档内运行,reload 是浪费。

**switchToSession 必须用 `location.assign` 不能用 `location.replace`**:
replace 覆盖当前 history entry,Capacitor backButton handler 看到
`canGoBack=false` 直接退出 APP(用户在 terminal 页按返回 = 退 APP,
无法回到 launcher)。assign push 新 entry,back → popstate →
routeFromLocation → leaveTerminalView 正常回 launcher。

### 绝不能走 reload 的入口

- `scheduleReconnect`(socket close → 退避重试):同 session 重连,
  layer 是稳定的,reload 就 1-2 秒空白
- `popstate`(系统返回):已经在正确文档,routeFromLocation 内部走
  connectToSession 或 leaveTerminalView 即可
- 首次 deep-link 进 session(URL 自带 `?session=<id>`):SPA 刚启动,
  layer 还没 dirty,直接 connectToSession 即可

### 桌面浏览器路径(不复现 layer bug)

- `visibilitychange` visible: `disposeTerminal()` + `startForcePaintWindow()` +
  `dropPendingWrites()` + `socket.close(4000)` + `focusTerminal()`
- session 切换: 走原 `connectToSession` in-place 路径
- 桌面 reload 是纯倒退(launcher 闪 / vite chunks 重 eval)

### `.terminal-canvas-host` wrapper 自身仍有价值

虽然 wrapper 隔离在 ICL-AL20 上不够(还是要 reload),wrapper 自身
在桌面 dispose 路径仍然必要:桌面 compositor 对 removeChild 响应及时,
wrapper 销毁就 release layer。也让 canvas 跟 terminalMount 的
desktop-pan layer 隔开。

**实现要点**:

- terminalMount 自身**不要**重建 —— 大量 listener
  (`touchstart/move/end/cancel/click/pointerup`)和 ResizeObserver 都
  attach 在它身上;重建得搬到 `installMountListeners(mount)` 再挂回去,
  改动面太大
- canvasHost 必须继承 terminalMount 的 width/height(`100%`),否则
  desktop-width 容器 / 移动 viewport 适配会跟 canvas 不一致
- 别给 canvasHost 加 `position:absolute` —— dist 的 helper textarea 是
  `position:absolute`,要找 positioned ancestor,目前找 `.terminal-host`
  (index.html `position:relative`)
- canvas 自身**不要**额外 `will-change`/`transform` promote layer:
  canvasHost 已 promote,叠加只增 GPU 内存

### 反模式合集

- ❌ 回退到只 dispose 不 reload。截图实测在 ICL-AL20 上 dispose **不**够
- ❌ reload 前加"温柔过渡"(scheduleFullPaint / 中间状态 paint)。任何
  过渡 paint 完全无意义,纯增复杂度。直接 reload
- ❌ 把 reload 改成 `history.go(0)` / `location.assign(location.href)`:
  跟 reload 等价但语义模糊,reviewer 困惑
- ❌ APP reload 时尝试保存 scroll / pendingCtrl modifier / inflight uploads
  到 sessionStorage:都是临时态,用户切回前台本来期望"全新视图"
- ❌ 给桌面也走 reload。桌面 compositor 不出 bug,纯倒退
- ❌ `switchToSession` 用 `location.replace` 替代 `assign`(见上文)
- ❌ `terminal.open(canvasHost)` 换回 `terminal.open(terminalMount)`:
  会让 canvas 直接挂 terminalMount(desktop-pan layer),破坏桌面 dispose
  路径的 layer 隔离
- ❌ disposeTerminal 加 `canvasHost = null` / 专门变量管理:
  ensureTerminal 局部变量 + `terminal.element` 引用,GC 自然处理,
  module-level 反而阻 GC
- ❌ 给 canvasHost 加更多 promotion hint(`backface-visibility:hidden`
  等)"保险一些":promotion 是 boolean,叠加只增 GPU 内存

### 文件选择器 grace window (`filePickerOpenAt` + `FILE_PICKER_VISIBLE_GRACE_MS = 60_000`)

系统文件选择器把 WebView 推到 hidden,用户回 APP 时 visibility=visible
**默认**会触发 reload,导致 `<input type="file">` 的 change 回调被新 SPA
启动接不住 → 上传**完全无反应**。

修复:`openUploadFilePicker()` 在 click 前 set 时间戳,visibility handler
窗口内 short-circuit 不 reload。窗口内 reload skip 是安全的:picker 期间
WebView 不 render,compositor 不累积 stale layer。cancel 路径没有 change
事件,靠 60s 超时兜底。

**反模式**:

- ❌ 删/缩短 grace window。窗口短复现"上传无反应",窗口长让"切走 APP
  几分钟"不 reload
- ❌ `uploadFileInput.change` 同步清零 `filePickerOpenAt`。实测在
  ICL-AL20 上 change 事件比 visibilitychange=visible 早约 50ms,同步
  清零让 grace handler 误判 → reload → 中断 in-flight upload init →
  上传失败。正确做法:`setTimeout(() => filePickerOpenAt = 0, 2000)`
  延迟 2s 清(覆盖 visibility transition + upload init RTT)

## Stale canvas backing: forceAll 路径

dist 内部 dirty-row 优化默认只画 `wasmTerm.isRowDirty(y)` 为 true 的行,
其他行保留 canvas 现有像素。「上一帧 = GPU backing」时正确,但下面两种
情况下 GPU backing 是 stale,必须用 `scheduleFullPaint()` 强制全画:

1. **Snapshot 重锚**(`applyScreenSnapshot` 末尾):snapshot 是完整可视
   区域,即使部分 row 跟 wasmTerm 现状一样,GPU backing 可能 stale
   (reconnect 后第一波 backlog 落在崭新 canvas)
2. **install / DPR 切换**(`installOnDemandRender` 末尾 + `applyRendererDpr`
   末尾):`renderer.resize` 内部 `canvas.width = X` reset ctx state +
   fillRect 背景,把之前的 render 输出抹掉;后续 dirty-only paint 看到
   non-dirty rows 不画 → 用户看到纯背景色

visibility=visible 不在此列表 —— APP 走 reload,桌面走 dispose,见上面
"GPU layer texture" 段。

**调用约定**:`schedulePaint()` 日常用 dirty-only;`scheduleFullPaint()`
只在上述两点 + hello/appearance/resize 控制帧末尾(belt-and-braces 兜
"resize → self-heal 之间 half-render" / "setTheme 后 clean row 仍用旧色"
等盲区)。`scheduledPaintFrame` rAF dedup;force flag upgradeable
(true 永远覆盖 false,同帧混合调用最终走 force=true)。

### `forcePaintUntil` 滑动窗口

只在固定点 force 不够。reconnect 路径下,server 发完 `hello → backlog
(~256 frames) → screen snapshot` 序列,snapshot 末尾 forceAll 抹一次,
但之间的 backlog binary frame 每条走 `terminal.write` → 只画 dirty row,
dist v0.4.0 dirty tracking 在快速 burst 下偶尔漏标已覆盖的 row → 残留
前一帧像素 → "文字重叠"(spinner 跟旧 buffer 同行)。

**修复**: module-level `forcePaintUntil` 时间戳,`startForcePaintWindow`
设 `Date.now() + FORCE_PAINT_WINDOW_MS`(**2500 ms**)。`schedulePaint`
顶部 `if (force || Date.now() < forcePaintUntil) ...force = true`,
窗口内任意 paint 自动升级 forceAll。启动点:

- `socket.addEventListener("open", ...)` —— 任何 reconnect 后 backlog 序列
- `visibilitychange` 的桌面分支 visible 入口 —— 跟桌面 dispose 配套。
  这里**不**调 `scheduleFullPaint` 自身(那一帧会被部分 compositor
  缓存进 stale layer texture),只设窗口戳。APP 分支走 reload,根本
  不进这条窗口

**为什么 2500 ms**:实测 hello → 256 frame backlog → snapshot 在 3G/4G/
弱 WiFi 下约 800-1800 ms,2500 ms 留 700-1700 ms 头部裕量。再长就把日常
拖进 forceAll,DPR cap 的省电收益打折。

**为什么不每帧 force**:`renderer.render(wasm, true, ...)` 整屏 fillRect
+ 全 row 重画,DPR=1.5 时 ~3 ms/帧,DPR=2.0+ 起步 6-8 ms。密集 burst
(`ls /usr`)每帧 forceAll 把电省回去。

### forceAll 帧再加 `renderer.clear()` + `scrollToBottom`

forceAll 帧内,先 `renderer.clear()` 做整屏 fillRect 再调 dist render;
若 `userFollowBottom && viewportY !== 0` 顺手 `scrollToBottom()` reanchor。
follow gate 是后加的:用户滚进历史时 `viewportY > 0` 是有意状态,混画
scrollback+active 正是 scrolled-up 视图的正确画面,无条件 reanchor 会让
每次 snapshot/hello/appearance 触发的 forceAll 把读历史的用户拽回底部。

**Why**:

1. dist `renderLine` 是 per-row fillRect,部分桌面 compositor 在 per-row
   小 fillRect 下不触发完整 layer invalidation,残留 stale 像素。整屏
   `fillRect(0,0,w,h)` 强制 compositor 标整 layer dirty,per-row 写入
   才落地。APP 路径走 reload 不依赖,但桌面 dispose 路径需要
2. `viewportY > 0` 时 dist render 混画 scrollback(上半)+ active(下半)
   (`renderLine` line 1431-1438),smoothScrollTo 残留 target 时 forceAll
   也会画出"上面 scrollback / 下面 active" 重叠。tick 内强 reanchor 是
   最直接的兜底

**成本**:cap DPR 1.5 时 ~1-2 ms,只在 forceAll 帧触发(force window
或显式 `scheduleFullPaint`),日常 dirty-only 不受影响。

### forceAll / forcePaintUntil 反模式

- ❌ 所有 `schedulePaint` 帧都 `renderer.clear()`:日常 paint 本是
  ~50 µs/帧,前加 1-2 ms 整屏 fillRect 把电量优势打折
- ❌ reanchor 改成无条件 `scrollToBottom()`(去掉 `viewportY !== 0`
  guard):会触发 `showScrollbar` fade-in rAF 链,空跑浪费
- ❌ `terminal.write` wrap 内 force:write 路径下 dist dirty tracking
  通常准确,GPU backing fresh,强 force 是浪费。reconnect/resume race
  用 `forcePaintUntil` 窗口处理,不要污染 write wrap
- ❌ `FORCE_PAINT_WINDOW_MS` 拉到 5s+ "保险一些":窗口期 cap DPR 失效,
  长 burst 用户感到轻微发热

## Follow-mode（`userFollowBottom`)与 dist buffer stub 坑

「向上滚看历史后,新内容不把用户拽回底部」靠模块级 `userFollowBottom`
状态机:touch 滚动 / scrollbar lane 拖动后 `userFollowBottom = isAtBottom()`;
write wrap 在 `!userFollowBottom` 时补偿 dist 内部的无条件
`viewportY !== 0 && scrollToBottom()`(dist 行 2390)并按 baseY 增量
restore viewportY。恢复 follow 的入口只有用户意图:sendInput(打字)、
工具栏按键、mobileInput focus、connectToSession(新会话)。

**dist stub 坑(本节存在的原因)**:ghostty-web v0.4.0 的
`terminal.buffer.active` 是 stub —— `viewportY` 和 `baseY` getter 都
写死 `return 0`。任何用 `buf.viewportY === buf.baseY` 判断"在底部"的
代码恒得 true。曾让 `isAtBottom()` 在「host 网格比 viewport 矮(pan 轴
无行程)」时恒判在底部 → follow 永远不解除 → 每个 binary frame 把读
历史的用户拽回底部。**判断 wasm 轴滚动位置一律用
`terminal.getViewportY()`(0 = live,>0 = 滚进历史,平滑滚动中可为小数),
不要读 buffer.active**。升包时确认 stub 是否仍是 stub。

**snapshot 不再无条件 re-anchor**:agent 在重连(nginx idle timeout 在
host 安静时掐 WS,agent 下次发送才察觉 —— 即「恰好有新输出时」)和任意
client join 时都会重发 screen snapshot 并被 relay 广播给所有客户端。
`applyScreenSnapshot` 只在 `userFollowBottom` 时滚底(经由
`scrollTerminalToBottom` 内部 guard),读历史的用户位置由 write wrap 保住。

**反模式**:

- ❌ snapshot 路径恢复 `userFollowBottom = true`(旧行为)。重连伪装成
  "新内容到达",用户体感是"一有变更就被拽回",scrollback 不可用。
- ❌ 在 `terminal.onScroll` 订阅里重算 follow。dist 内部 write →
  scrollToBottom 也 fire scrollEmitter,程序性滚动会把 follow 误置回
  true,恰好抵消 write wrap 的 restore。
- ❌ 新加滚动入口(手势/按钮/快捷键)后忘记 `userFollowBottom =
  isAtBottom()`。scrollbar lane 曾漏过这个,症状同 stub 坑。

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
