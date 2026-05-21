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

## TLS:IP 直连用自签证书 + NSC pin

部分 ISP / 路由器屏蔽小众 TLD(`.top` 等)→ 用户手机解析不到主域名 →
APP fetch `https://<domain>` 直接 "Failed to fetch"。用 IP 访问的话
letsencrypt 证书没有 IP SAN → TLS hostname mismatch → 同样失败,Android
WebView 不允许跳过(`onReceivedSslError` 会被 Play 拒)。

解法是**自签证书 + NSC 信任**:

- 服务器 `/etc/nginx/ghostty-selfsigned.{crt,key}` 包含 SAN
  `DNS:<domain>, IP:<ip>`(用 openssl config 文件方式生成,旧版 openssl
  不支持 `-addext`)。
- `ghostty-relay.conf` **双 server 块,同端口** `28443`:
  - `server_name <domain>`:letsencrypt(浏览器走这条,SNI 路由命中)
  - `listen ... default_server`:自签(SNI miss / IP 访问命中)
  浏览器版体验不降级,APP IP 直连也通。
- APP 端 `res/raw/ghostty_ca.pem` 内置该证书,`res/xml/network_security_config.xml`
  对 `<domain>` 和 `<ip>` 两个 host 同时声明 trust anchor(`system` +
  `@raw/ghostty_ca`),AndroidManifest 引用。
- 续期:letsencrypt 自动续(certbot 默认),自签证书 3650 天(10 年)
  不需要管。如果 IP 变了,要重新生成自签 + 重打 APK。

**反模式**:写自定义 `WebViewClient.onReceivedSslError()` 来"忽略证书"
。Google Play 会拒,任何 WiFi 上的 MITM 都能伪装服务器,**远比当前方案不安全**。
trust anchor pin 比 letsencrypt 公共 CA 更安全(锁了 issuer)。
2. **APP 内"下载 Android 安装包"按钮目前未真机验证**:Android WebView
   默认无 `DownloadListener`,`<a download>` + blob URL 在 Capacitor 内
   可能无反应。浏览器版工作正常。若 APP 内不工作,在 MainActivity 注册
   `setDownloadListener` 拦截。
3. 混合内容:APP 是 https,relay 必须有效 TLS。自签证书 / 明文 http
   会被 WebView 拒,wss 也连不上。
4. 移动端 IME 路径(`src/main.js` 接近 2240 行的 `mobileInput` 段:
   `compositionstart/end` + Enter/Tab/Backspace 单独 handler + sticky
   Ctrl/Alt modifier)已完整,Capacitor WebView 复用浏览器移动端代码,
   **除非真机测出问题,别动这段**。

## 远端是 Linux 的小坑

- 校验文件 sha 用 `sha256sum`,不是 macOS 的 `shasum`。
- relay 服务器在 Linux,本地脚本里要给远端运行的命令一律按 Linux 习惯写,
  不要假设 BSD coreutils。
