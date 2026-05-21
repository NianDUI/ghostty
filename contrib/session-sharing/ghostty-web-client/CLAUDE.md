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

## 远端是 Linux 的小坑

- 校验文件 sha 用 `sha256sum`,不是 macOS 的 `shasum`。
- relay 服务器在 Linux,本地脚本里要给远端运行的命令一律按 Linux 习惯写,
  不要假设 BSD coreutils。
