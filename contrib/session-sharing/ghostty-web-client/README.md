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
