# Session Sharing Web Client with `ghostty-web`

这个目录是并行于现有 `contrib/session-sharing/web` 的第二代网页客户端原型。

目标：

- 保留会话共享自己的登录、会话列表和 relay 协议
- 用 `ghostty-web` 替换手写的浏览器终端 renderer
- 恢复颜色、光标、样式和更完整的终端输入行为

## 开发

安装依赖：

```bash
cd contrib/session-sharing/ghostty-web-client
npm install
```

本地开发：

```bash
npm run dev
```

构建静态产物：

```bash
npm run build
```

构建完成后可以让 relay 直接服务产物目录：

```bash
python3 contrib/session-sharing/relay/server.py --static-root contrib/session-sharing/ghostty-web-client/dist
```

## Android 打包

这个目录已经接入 `Capacitor`，并生成了 Android 壳工程：

- 配置文件：[capacitor.config.json](/Users/lyd/WorkSpace/MyProjects/ghostty/contrib/session-sharing/ghostty-web-client/capacitor.config.json)
- Android 工程目录：[android](/Users/lyd/WorkSpace/MyProjects/ghostty/contrib/session-sharing/ghostty-web-client/android)

首次准备：

```bash
cd contrib/session-sharing/ghostty-web-client
npm install
```

同步前端产物到 Android：

```bash
npm run android:build
```

打开 Android Studio：

```bash
npm run cap:open
```

如果只想手动同步原生工程：

```bash
npm run cap:sync
```

说明：

- `Backend URL Base` 默认使用当前页面自身；如果 APK 里的静态页和 relay 不在同一个地址，需要在主页面里手动改成你的 relay 地址。
- Android 打包仍然依赖本机安装 `Android Studio`、`Android SDK` 和可用的 `JDK`。
- 这套壳当前是 `WebView + Capacitor` 路线，不是原生终端控件。

## 当前边界

这个版本当前只完成最小接线：

- token 保存
- `/api/sessions` 会话列表
- `/ws/client` WebSocket 连接
- `ghostty-web` `term.write(...)`
- `term.onData(...)`

后续还需要继续补：

- resize 上报
- 断线重连
- 更细的移动端输入体验
- 和 relay 的初始屏幕同步策略配合
